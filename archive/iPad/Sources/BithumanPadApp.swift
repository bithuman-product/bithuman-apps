// BithumanPadApp.swift — iPadOS entry point for the bithuman-kit avatar.
//
// Mirrors `Apps/BithumanMac` in spirit: this target depends on
// `bitHumanKit` and reuses `AvatarCoordinator` + the cross-platform
// SwiftUI surface verbatim. Only the windowing/lifecycle differs.
// Everything UIKit-specific (renderer, sheet presentation, idle
// timer, audio session) lives here so the library stays platform-
// agnostic.
//
// The whole file is gated `#if canImport(UIKit)` so that running
// `swift test` on macOS (where UIKit is unavailable) doesn't try to
// compile this iOS-only entry point. The iOS-triple smoke build
// (`swift build --product bithuman-pad --triple arm64-apple-ios26.0`)
// is the supported way to validate this target.

#if canImport(UIKit)
import Combine
import SwiftUI
import UIKit
import AVFAudio
import bitHumanKit

@main
struct BithumanPadApp: App {
    // App-delegate adaptor is needed for two things SwiftUI's `App`
    // protocol can't express on iOS:
    //   1. AVAudioSession category configuration (mic + playback +
    //      voice-processing IO equivalent), which has to happen
    //      before the audio engine wakes up.
    //   2. Locking the bundle to iPad-only orientations at the
    //      UIApplication level — `.supportedOrientations` Info.plist
    //      keys are honored, but the delegate hook is the only place
    //      we can refuse iPhone window scenes if the bundle ever gets
    //      side-loaded onto one.
    @UIApplicationDelegateAdaptor(BithumanPadAppDelegate.self) private var appDelegate

    // Engine + orchestrator live for the lifetime of the App. We
    // hand them off to `iPadAvatarRoot` via the environment so any
    // sheet / split-view child can reach the coordinator without
    // prop drilling.
    @StateObject private var lifecycle = BithumanPadLifecycle()

    init() {
        // int4 DiT (~2.6 GB → ~750 MB) and int4 Wav2Vec2 transformer
        // Linears (~190 MB → ~50 MB). Must be set before Bithuman.create
        // reads them in WeightLoader. Overwrite=0 so a launch-env
        // override wins for diagnostics.
        setenv("FH_QUANTIZE_DIT", "int4", 0)
        setenv("FH_QUANTIZE_W2V2", "int4", 0)
        // Per-second FPS / RTF stats — set BITHUMAN_STATS=0 in the
        // launch env to silence. Default-on for sideloaded builds so
        // the dev iPad surfaces FPS without rebuilding.
        setenv("BITHUMAN_STATS", "1", 0)
        setenv("BITHUMAN_VERBOSE", "1", 0)

        // Print phys_footprint + available memory every 2s. Used during
        // the entitlement-drop validation; harmless to leave on for
        // sideloaded test builds. NSLog goes to Console.app on the
        // device under the bundle identifier filter.
        #if DEBUG
        MemoryProbe.startLogging(label: "BithumanPad")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // Hardware gate FIRST. Below the M4 iPad Pro the avatar
            // engine peaks above what the device can sustain (DiT
            // ~7.5 GB at fp16, jetsam'd on 8 GB SKUs, thermal-
            // throttled on M2/M3). Catching this here means we never
            // even download the ~3.7 GB engine weights.
            switch HardwareCheck.evaluate() {
            case .supported:
                iPadAvatarRoot(lifecycle: lifecycle)
                    // Prevent the iPad from sleeping while a chat
                    // session is live. We toggle this on/off based on
                    // chat state — leaving idle-timer disabled forever
                    // drains the battery and heats the device.
                    .onChange(of: lifecycle.shouldKeepScreenAwake) { _, awake in
                        UIApplication.shared.isIdleTimerDisabled = awake
                    }
                    .task {
                        await lifecycle.start()
                    }
            case .unsupported(let reason):
                UnsupportedDeviceView(reason: reason)
            @unknown default:
                UnsupportedDeviceView(reason: "Unrecognised device capability returned by bitHumanKit. Update the app to a newer release.")
            }
        }
    }
}

/// App-delegate. iOS-only concerns that don't fit in the SwiftUI
/// scene tree.
final class BithumanPadAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        configureAudioSession()
        #if DEBUG
        // Dev builds: keep the screen on the moment the app launches so
        // tethered USB-C testing isn't interrupted by auto-lock during
        // weights download or on the unsupported-device view. Release
        // builds rely on the lifecycle-driven toggle below.
        application.isIdleTimerDisabled = true
        #endif
        return true
    }

    /// Route the scene to BithumanPadSceneDelegate, which pins the
    /// window to a fixed widget-sized 512×512 (Stage Manager / floating
    /// chrome). Mirrors what Halo's iPad app did — keeps the avatar's
    /// designed proportions intact and stops the OS from upscaling the
    /// 384 px engine output to fullscreen blur.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(
            name: "BithumanPad",
            sessionRole: connectingSceneSession.role
        )
        config.delegateClass = BithumanPadSceneDelegate.self
        return config
    }

    /// Configure for full-duplex voice chat: mic + speaker, ducking
    /// other audio, supporting both bluetooth + built-in routes.
    /// `.voiceChat` mode is the iOS analog of macOS's voice-processing
    /// IO unit — engages the system AEC + AGC so the mic doesn't pick
    /// up the avatar's own TTS through the iPad speakers.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true)
        } catch {
            // Don't fatal — mic permission may not have been granted
            // yet. The pipeline will report a clean error to the user
            // when they first try to speak.
            NSLog("BithumanPad: audio session config failed: \(error)")
        }
    }

    /// Lock the app to iPad orientations only. The Info.plist keys
    /// (UISupportedInterfaceOrientations / iPad family code = 2)
    /// already enforce this, but this hook is the belt to that
    /// suspenders.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .all  // portrait + portraitUpsideDown + landscapeLeft + landscapeRight
    }
}

/// Wraps `VoiceChat` + `AvatarCoordinator` + `FramePump` + the long-
/// lived UIKit `AvatarRendererView` so SwiftUI can lifecycle them
/// cleanly. Equivalent to the chunk of `main.swift` that exists in
/// the macOS CLI today, plus the FramePump construction that
/// AvatarWindow handles on macOS.
@MainActor
final class BithumanPadLifecycle: ObservableObject {
    @Published var coordinator: AvatarCoordinator?
    @Published var bootError: String?
    /// True while the avatar engine is loaded & a chat session is
    /// live. Drives the idle-timer disable in the App scene.
    @Published var shouldKeepScreenAwake: Bool = false
    /// The long-lived UIKit renderer view. SwiftUI binds to this via
    /// a `UIViewRepresentable` — the view is constructed exactly
    /// once per session so the FramePump can drive it through its
    /// `AvatarFrameSink` conformance without SwiftUI tearing it down
    /// on view-tree updates.
    @Published private(set) var rendererView: AvatarRendererView?
    /// PiP controller — owns an AVSampleBufferDisplayLayer + an
    /// AVPictureInPictureController. The on-screen renderer AND this
    /// controller are both driven by the FramePump via a
    /// MultiAvatarFrameSink fan-out. Tap the menu's "Float" entry to
    /// pop into a draggable PiP window over other iPad apps.
    @Published private(set) var pipController: AvatarPiPController?
    /// Mirror of `pipController.isActive` — the lifecycle is the
    /// ObservedObject the iPad root view watches; mirroring this
    /// here lets the SwiftUI tree react to PiP start/stop without
    /// each view having to subscribe to the controller separately.
    @Published private(set) var pipIsActive: Bool = false
    /// First-run download/verify state. Drives the loading UI: ring
    /// with %/speed/ETA when `.downloading`, particle field otherwise.
    @Published private(set) var downloadPhase: DownloadPhase = .verifying
    /// Estimated warming progress [0,1] — driven by a wall-clock
    /// timer once weights are ready and the engine starts loading.
    /// We don't have a real progress hook through the engine boot
    /// path, so this is time-based against a typical warm-up duration.
    /// Resets to 0 if a new boot starts.
    @Published private(set) var warmingProgress: Double = 0
    /// Bundled JPG of the agent we're booting — shown inside the
    /// loading ring so the user can see who they're about to talk to
    /// before the avatar engine has produced its first frame.
    @Published private(set) var bootPortraitURL: URL?

    /// Time-constant for the asymptotic warming curve. Engine load
    /// on first run is dominated by Gemma + Kokoro hub fetches and
    /// can take 90–120 s; warm restarts are 8–15 s. Rather than a
    /// linear ramp that pegs at 99 % well before the engine is
    /// actually ready (the v0.6.x bug — bar visibly stuck at 99 for
    /// ~100 s on first run), the curve uses
    /// `1 - exp(-elapsed / tau)` so the bar always crawls forward.
    /// At τ = 25 s: 5 s → 18 %, 25 s → 63 %, 60 s → 91 %, 120 s →
    /// 99 % — never visibly stuck, the bar's velocity matches the
    /// user's diminishing expectation of imminent completion.
    private let warmingTimeConstantSeconds: Double = 25.0

    private var chat: VoiceChat?
    private var framePump: FramePump?
    private var pipActiveSubscription: AnyCancellable?
    private var warmingTimer: Timer?
    /// Held while an Essence demo session is alive — keeps the
    /// frame-drain task rooted past `start()`'s return. Cleared on
    /// `start()` retry / lifecycle teardown.
    private var essenceFrameTask: Task<Void, Never>?

    func start() async {
        guard chat == nil else { return }
        do {
            // Surface the default agent's portrait to the boot splash
            // immediately so the user sees who they're about to talk
            // to during BOTH the download phase and the warming
            // phase. The thumbnail is a sync bundle lookup; cheap.
            self.bootPortraitURL = AgentCatalog.thumbnailURL(for: AgentCatalog.defaultAgent)

            // Mirror the macOS bootstrap: download/verify the avatar
            // engine weights, then construct VoiceChat with an avatar
            // config + the default agent's voice/prompt. The avatar
            // engine is what makes this an "iPad video chat", not just
            // a chatbot — we always boot in video mode.
            let weightsURL = try await ExpressionWeights.ensureAvailable { phase in
                Task { @MainActor [weak self] in
                    self?.downloadPhase = phase
                    if case .ready = phase {
                        // Weights cached/verified — start the wall-
                        // clock-driven warming progress so the splash
                        // shows a climbing percentage during the
                        // ~5–10 s engine-load phase.
                        self?.startWarmingProgress()
                    }
                }
            }

            // Phase 1 Essence dispatch — auto-detect on the `.imx`.
            // Same UX whether the loaded file is Expression or
            // Essence (the "one factory, both runtimes" SDK story).
            // When the SDK in use predates the Essence work
            // (BITHUMAN_KIT_ESSENCE flag off) this is a no-op:
            // returns `.expression`, falls through to the existing
            // VoiceChat bootstrap below.
            //
            // The pattern (mirrored in the Mac app):
            //
            //   ```swift
            //   let runtime = try Bithuman.createRuntime(modelPath: weightsURL)
            //   switch runtime {
            //   case .expression(let bithuman):
            //       // existing VoiceChat-driven path
            //   case .essence(let essenceRuntime):
            //       // new pushAudio + frames() AsyncStream path
            //   }
            //   ```
            if try iPadDetectRuntime(modelPath: weightsURL, lifecycle: self) == .essence {
                self.shouldKeepScreenAwake = true
                stopWarmingProgress(complete: true)
                return
            }

            let defaultAgent = AgentCatalog.defaultAgent
            let portraitURL = AgentCatalog.thumbnailURL(for: defaultAgent)

            var config = VoiceChatConfig()
            config.localeIdentifier = "en-US"
            config.systemPrompt = defaultAgent.systemPrompt
            config.avatar = AvatarConfig(modelPath: weightsURL, portraitPath: portraitURL)

            let chat = VoiceChat(config: config)
            self.chat = chat
            try await chat.start()

            guard let bh = chat.bithuman else {
                self.bootError = "Avatar engine failed to initialise."
                return
            }

            // Pin the Kokoro voice to the default agent's preset
            // (matches the macOS app's behaviour).
            await chat.setVoicePreset(defaultAgent.voicePreset)

            let coord = AvatarCoordinator(chat: chat)
            coord.bindToOrchestrator()
            coord.currentSystemPrompt = defaultAgent.systemPrompt
            coord.currentVoicePreset = defaultAgent.voicePreset
            coord.currentAgentCode = defaultAgent.code
            coord.prewarmPortraitURL = portraitURL

            // Build the render stack: a UIKit AvatarRendererView (which
            // conforms to AvatarFrameSink), plus an AvatarPiPController
            // that fans the same frames into an
            // AVSampleBufferDisplayLayer for Picture-in-Picture. Both
            // sinks are driven by a single FramePump via a
            // MultiAvatarFrameSink so the on-screen avatar and the
            // PiP overlay stay in lockstep.
            // iPad uses `.circle` so the avatar renders inside a
            // small circular crop sized close to the engine's native
            // 384×384 output. With Stage Manager off the iPad gives
            // us the full screen, and stretching 384 px to that area
            // looks visibly soft; the circular form keeps the face
            // at near-native pixel density.
            let renderer = AvatarRendererView(
                frame: .zero,
                idleFrame: chat.initialIdleFrame,
                clipMode: .circle
            )
            // PiP controller stays wired so the user can trigger PiP
            // manually from the ⋯ menu, but neither auto-start nor
            // sticky is engaged — the default experience is the
            // 400×400 floating panel design.
            let pip = AvatarPiPController()
            let multiSink = MultiAvatarFrameSink([renderer, pip])
            let pump = FramePump(bithuman: bh, chat: chat, window: multiSink, coordinator: coord)
            coord.framePump = pump
            chat.onBargeIn = { [weak pump] in pump?.buffer.flushSpeech() }
            chat.onCheckSpeechBuffer = { [weak pump] in pump?.buffer.hasSpeech == false }

            self.framePump = pump
            self.rendererView = renderer
            self.pipController = pip
            self.pipActiveSubscription = pip.$isActive
                .receive(on: DispatchQueue.main)
                .sink { [weak self] active in self?.pipIsActive = active }
            self.coordinator = coord
            self.shouldKeepScreenAwake = true
            // Engine is up — stop the warming-progress timer if it's
            // still running (the avatar takes over the screen anyway,
            // but cleanly tearing the timer down avoids retained work).
            stopWarmingProgress(complete: true)
        } catch {
            // NSLog the verbose representation alongside the user-
            // facing message — `localizedDescription` is what the
            // SwiftUI bootErrorView shows; the verbose `error` form
            // is what the developer needs to debug from Console.app.
            NSLog("[BithumanPad] bootstrap error: \(error)")
            self.bootError = "\(error.localizedDescription)"
            stopWarmingProgress(complete: false)
        }
    }

    // MARK: - Essence demo bindings

    /// Wire an Essence-configured `AvatarRendererView` into the
    /// lifecycle so the existing iPad SwiftUI tree (`AvatarPanelView`)
    /// can render frames from `EssenceRuntime.frames()` exactly the
    /// same way it renders Expression frames. The only visible
    /// difference is the renderer's `clipMode` — `.fill` for the
    /// rectangular Essence frame instead of `.circle`.
    ///
    /// Called from `runEssenceDemo` in `iPadRuntimeDispatch.swift`.
    @MainActor
    func bindEssenceRenderer(_ renderer: AvatarRendererView) {
        self.rendererView = renderer
    }

    /// Root the Essence frame-drain Task on the lifecycle so it
    /// survives the dispatch function's return. Cancels and replaces
    /// any prior task — Essence is single-consumer per actor.
    @MainActor
    func bindEssenceFrameTask(_ task: Task<Void, Never>) {
        essenceFrameTask?.cancel()
        essenceFrameTask = task
    }

    /// Drive `warmingProgress` along an asymptotic curve so the
    /// splash percentage always advances — never visibly stuck —
    /// regardless of how long the real load takes. The timer
    /// updates every 100 ms; `stopWarmingProgress(complete: true)`
    /// snaps to 1.0 when the engine actually comes up.
    private func startWarmingProgress() {
        guard warmingTimer == nil else { return }
        let start = Date()
        warmingProgress = 0
        let tau = warmingTimeConstantSeconds
        warmingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(start)
            // 1 - exp(-t/τ): asymptotic, monotonic, never reaches 1.
            // Cap at 0.999 so 100 % only ever reflects real completion.
            let raw = 1.0 - exp(-elapsed / tau)
            self.warmingProgress = min(0.999, raw)
        }
    }

    private func stopWarmingProgress(complete: Bool) {
        warmingTimer?.invalidate()
        warmingTimer = nil
        if complete {
            warmingProgress = 1.0
        }
    }
}

/// Pins the iPad scene to a fixed 512×512 window. iPadOS renders
/// it as a widget-sized rounded square that floats on the Home
/// Screen / Stage Manager rather than filling the display, which
/// keeps the avatar's 384 px engine output near 1:1 native pixels
/// (~1.33× upscale at 2× retina) — fullscreen would push that to
/// 5–6× and look visibly soft.
///
/// Min == Max disables resizing entirely; `allowsFullScreen = false`
/// hides the dead "expand to full screen" affordance from Stage
/// Manager's three-dot menu. Same pattern Halo iPad used.
final class BithumanPadSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    /// Floating-window dimensions. 320×320 — close to Stage Manager's
    /// minimum, just enough room for a 250 pt avatar circle + the
    /// menu/state/drag overlays around it.
    private static let visualSide: CGFloat = 320

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Defer one tick so SwiftUI's WindowGroup has created its
        // UIWindow + root UIHostingController; then strip every
        // opaque layer so the iPad desktop shows through behind
        // the floating panel (i.e. the panel reads as a translucent
        // window over the desktop, not a black slab).
        DispatchQueue.main.async {
            for window in windowScene.windows {
                window.backgroundColor = .clear
                window.isOpaque = false
                window.rootViewController?.view.backgroundColor = .clear
                window.rootViewController?.view.isOpaque = false
            }
        }

        if let restrictions = windowScene.sizeRestrictions {
            let s = CGSize(width: Self.visualSide, height: Self.visualSide)
            restrictions.minimumSize = s
            restrictions.maximumSize = s
            restrictions.allowsFullScreen = false
        }
    }
}

#endif // canImport(UIKit)
