#if canImport(AppKit)
import AppKit
import Dispatch
import Foundation

/// Wires the Dock click → bring window back, last-window-closed →
/// quit, and (critically) hosts the async setup that has to run
/// **after** NSApp.run() starts.
///
/// Why the async work goes here instead of pre-NSApp.run(): the Swift
/// main-actor executor and AppKit's `_DPSNextEvent` runloop don't
/// cooperate when NSApp.run() is invoked from inside an existing
/// async/await chain — the main dispatch queue stays unserviced and
/// every `DispatchQueue.main.async` (or `MainActor.run`) hangs forever.
/// Doing all setup from `applicationDidFinishLaunching` (a synchronous
/// callback NSApp fires _after_ the runloop is alive) sidesteps that
/// entirely; the runloop is in the canonical state when our Task runs.
@MainActor
open class BithumanAppDelegate: NSObject, NSApplicationDelegate {
    public var avatarWindow: AvatarWindow?
    private let onLaunch: @MainActor @Sendable () async throws -> Void
    private var sessionChat: AnyObject?
    private var sessionPump: FramePump?
    /// Held for Essence sessions only. Untyped `AnyObject` so this
    /// file doesn't have to import the CLI-side `EssenceSession`
    /// helper (which lives in the BithumanCLI executable target,
    /// not in `bitHumanKit`). The retain is the entire purpose:
    /// without it the runtime + window get released the instant
    /// `runEssenceVideoSession` returns.
    private var sessionEssence: AnyObject?
    /// Strong ref to the right-click menu's target object (Essence
    /// path only). NSMenuItem holds the target weakly so we have to
    /// pin it externally; the delegate's lifetime equals the app's.
    private var essenceMenuHandler: AnyObject?
    /// Retained dispatch-source for SIGINT so Ctrl-C from the
    /// invoking terminal flows through our clean shutdown path
    /// instead of killing the process mid-MLX-dispatch.
    private var sigintSource: DispatchSourceSignal?

    public init(onLaunch: @escaping @MainActor @Sendable () async throws -> Void) {
        self.onLaunch = onLaunch
        super.init()
    }

    /// Retain the session's chat + pump for the lifetime of the
    /// delegate (which equals the lifetime of NSApp). Without this
    /// the chat object goes out of scope when `runVideoSession`
    /// returns and the avatar freezes.
    public func retainSession(chat: AnyObject, pump: FramePump) {
        self.sessionChat = chat
        self.sessionPump = pump
    }

    /// Essence variant of ``retainSession(chat:pump:)``. The
    /// Essence runtime owns its own internal frame-pump task —
    /// there's no Expression-style `FramePump` to retain — so this
    /// API stashes an opaque session handle (typically the CLI-side
    /// `EssenceSession` wrapper) alongside the chat. Same lifetime
    /// contract: held for the life of the delegate.
    public func retainEssenceSession(chat: AnyObject, session: AnyObject) {
        self.sessionChat = chat
        self.sessionEssence = session
    }

    /// Pin the Essence right-click menu handler. NSMenuItem stores a
    /// weak reference to its target, so the handler must outlive the
    /// menu — pinning it here matches the lifetime of the avatar
    /// window without leaking on session swap (the next assignment
    /// drops the prior handler).
    public func retainEssenceMenuHandler(_ handler: AnyObject) {
        self.essenceMenuHandler = handler
    }

    public func applicationDidFinishLaunching(_ note: Notification) {
        // Replace the terminal stand-in icon AppKit gives a
        // CLI-launched NSApp with the bitHuman mark. Affects the
        // Dock, app-switcher, and About box. No-op if the bundle
        // lookup fails (we just keep the default icon).
        if let icon = BrandAssets.appIconImage() {
            NSApp.applicationIconImage = icon
        }

        // Route Ctrl-C through `NSApp.terminate` so it triggers
        // applicationWillTerminate (waitForProducerStop + drainGPU).
        // The default SIGINT handler kills the process immediately,
        // and an in-flight MLX dispatch then crashes
        // `pthread_mutex_lock: Invalid argument` on its way out
        // (a recurring `~/Library/Logs/DiagnosticReports/` entry).
        // The libc-level `SIG_IGN` is required for the Dispatch
        // signal source to actually receive the signal — without
        // it the default handler runs first.
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            NSApp.terminate(nil)
        }
        sigintSource.resume()
        self.sigintSource = sigintSource

        let work = onLaunch
        Task { @MainActor in
            do {
                try await work()
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    /// Fired when the user clicks the bitHuman icon in the Dock while
    /// the window is hidden (`orderOut` from the miniaturize override).
    /// Re-show the window. Returning `true` tells AppKit we handled
    /// the reopen — without this, AppKit silently does nothing.
    public func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows, let win = avatarWindow {
            win.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// Closing the avatar window → quit. We're a CLI tool with one
    /// window; no tray menu, no document state to babysit.
    public func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    /// Last-chance shutdown. AppKit gives us up to ~5 s here before
    /// SIGKILL. We need that headroom because the avatar's DiT,
    /// Kokoro TTS, and the chat LLM all submit Metal command
    /// buffers through MLX — if we exit while any of those buffers
    /// are still in flight on the GPU, their completion handler
    /// fires after MLX's scheduler has been torn down and the
    /// process aborts.
    ///
    /// Two distinct shutdown crashes were observed during
    /// development:
    ///   - SIGABRT in `Scheduler::notify_task_completion` —
    ///     completion handler fires after MLX scheduler is gone.
    ///     Fixed by `drainGPU()` waiting on `Stream.gpu`.
    ///   - SIGTRAP in `mlx_eval` from the avatar producer's
    ///     `generateIdleChunk`. Even after `cancel()`, the engine
    ///     call ignores Task cancellation and keeps running for
    ///     ~600 ms; if `drainGPU()` runs concurrently with that
    ///     in-flight call, mlx_eval asserts. Fixed by waiting on
    ///     the producer's stop semaphore BEFORE drainGPU.
    ///
    /// Order matters:
    ///   1. Cancel the producer + consumer timer so no NEW MLX
    ///      work gets queued past the current iteration.
    ///   2. Wait for the producer Task to actually finish so the
    ///      in-flight `generateIdleChunk` settles.
    ///   3. Drain MLX's GPU stream — blocks until every Metal
    ///      command buffer has completed.
    ///   4. Yield briefly so the consumer DispatchSourceTimer can
    ///      finish its last hop.
    public func applicationWillTerminate(_ note: Notification) {
        sessionPump?.cancel()
        // 1.5 s covers ~2× a worst-case idle DiT chunk on M5 (~600 ms).
        // Way under AppKit's ~5 s pre-SIGKILL grace.
        sessionPump?.waitForProducerStop(timeoutMs: 1500)
        VoiceChat.drainGPU()
        Thread.sleep(forTimeInterval: 0.1)
    }
}
#endif
