import CoreGraphics
import Dispatch
import Foundation
import QuartzCore

#if canImport(AppKit)
import AppKit

/// Lean NSView whose CALayer holds the avatar layer. For the
/// circular Expression layout the outer view is transparent so the
/// window's drop shadow appears around the inscribed circle, not
/// around a square frame. For the rectangular Essence layout the
/// layer simply tracks `bounds` with no corner rounding — the full
/// video IS the UI.
@MainActor
public final class AvatarRendererView: NSView {
    /// How the avatar layer is shaped + sized. `.circle` (default)
    /// inscribes a circle inside the host view's short side — the
    /// macOS floating-circle Expression use case. `.fill` stretches
    /// the avatar to the full host bounds and rounds the corners by
    /// `Self.fillCornerRadius` — the Essence full-frame use case
    /// where the rectangular video IS the entire UI but a square-
    /// edged window looks dated next to native macOS sheets. Mirrors
    /// the UIKit `AvatarRendererView`'s enum so cross-platform call
    /// sites stay symmetric.
    public enum ClipMode: Sendable {
        case circle
        case fill
    }

    /// Corner radius for `.fill` mode. 16pt matches the rounded-rect
    /// shape of macOS Sonoma+ alert sheets and the iOS app icon
    /// continuity, so the floating Essence window reads as a native
    /// floating panel rather than a raw video texture.
    public static let fillCornerRadius: CGFloat = 16

    private let imageLayer = CALayer()
    private var clipMode: ClipMode

    public init(frame frameRect: CGRect, idleFrame: CGImage?, clipMode: ClipMode = .circle) {
        self.clipMode = clipMode
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.contents = idleFrame
        imageLayer.masksToBounds = true
        imageLayer.backgroundColor = NSColor.black.cgColor
        imageLayer.magnificationFilter = .trilinear
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
        layoutImageLayer()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Switch shapes after construction. Mirrors the UIKit twin so
    /// host code can flip modes without a platform branch.
    public func setClipMode(_ mode: ClipMode) {
        self.clipMode = mode
        layoutImageLayer()
    }

    public override func layout() {
        super.layout()
        layoutImageLayer()
    }

    /// Lay out the avatar layer per the active clip mode. `.circle`
    /// inscribes a centred square (Expression's 195pt circular
    /// floating window — SwiftUI sizes us to `avatarSide × avatarSide`
    /// in `AvatarRootView`, so the inset math is a no-op there but
    /// stays correct for non-square host frames). `.fill` tracks
    /// `bounds` directly with no rounding (Essence full-frame).
    private func layoutImageLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch clipMode {
        case .circle:
            let side = min(bounds.width, bounds.height)
            let xInset = (bounds.width - side) / 2
            let yInset = (bounds.height - side) / 2
            imageLayer.frame = NSRect(x: xInset, y: yInset, width: side, height: side)
            imageLayer.cornerRadius = side / 2
        case .fill:
            imageLayer.frame = bounds
            imageLayer.cornerRadius = Self.fillCornerRadius
        }
        CATransaction.commit()
    }

    public func show(_ frame: CGImage) {
        // Disable implicit fade animations — at 25 FPS, the default
        // CATransaction animation makes the avatar look smeary.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = frame
        CATransaction.commit()
    }
}

#elseif canImport(UIKit)
import UIKit

/// UIKit twin of the AppKit `AvatarRendererView`. Same CALayer
/// approach: a single child layer fills the bounds with the current
/// CGImage, masked to a circle. Public surface mirrors the macOS
/// renderer exactly — `init(frame:idleFrame:)` + `show(_:)` — so the
/// FramePump can drive either without a platform branch.
///
/// On iOS / iPadOS the renderer view IS the FramePump's sink (no
/// separate `AvatarWindow` concept on UIKit). The iPad app hosts this
/// view via `UIViewRepresentable` and hands the same instance to the
/// `FramePump` constructor, which calls `render(_:)` on it 25× / s.
@MainActor
public final class AvatarRendererView: UIView {
    private let imageLayer = CALayer()

    /// How the avatar layer is shaped + sized. `.circle` (default)
    /// inscribes a circle inside the host view's short side — the
    /// macOS floating window + iPhone PiP-style use case. `.fill`
    /// stretches the avatar to the full host bounds and rounds the
    /// corners by `Self.fillCornerRadius` — the iPad/iPhone
    /// floating-widget use case where the rectangular video IS the
    /// UI but a square edge looks dated against rounded iOS chrome.
    public enum ClipMode: Sendable {
        case circle
        case fill
    }

    /// Corner radius for `.fill` mode — see the AppKit twin's
    /// docstring for the rationale.
    public static let fillCornerRadius: CGFloat = 16

    private var clipMode: ClipMode

    public init(frame frameRect: CGRect, idleFrame: CGImage?, clipMode: ClipMode = .circle) {
        self.clipMode = clipMode
        super.init(frame: frameRect)
        backgroundColor = .clear

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.contents = idleFrame
        imageLayer.masksToBounds = true
        imageLayer.backgroundColor = UIColor.black.cgColor
        imageLayer.magnificationFilter = .trilinear
        imageLayer.minificationFilter = .trilinear
        layer.addSublayer(imageLayer)
        layoutImageLayer()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Switch shapes after construction. Call from the host app when
    /// the floating-widget mode toggles, etc.
    public func setClipMode(_ mode: ClipMode) {
        self.clipMode = mode
        layoutImageLayer()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutImageLayer()
    }

    private func layoutImageLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch clipMode {
        case .circle:
            let side = min(bounds.width, bounds.height)
            let xInset = (bounds.width - side) / 2
            let yInset = (bounds.height - side) / 2
            imageLayer.frame = CGRect(x: xInset, y: yInset, width: side, height: side)
            imageLayer.cornerRadius = side / 2
        case .fill:
            imageLayer.frame = bounds
            imageLayer.cornerRadius = Self.fillCornerRadius
        }
        CATransaction.commit()
    }

    public func show(_ frame: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = frame
        CATransaction.commit()
    }
}

/// On iOS the renderer is also the FramePump's frame sink — there's
/// no separate window concept. `show(_:)` already does the right
/// thing; we just adapt the protocol's `render(_:)` to it.
extension AvatarRendererView: AvatarFrameSink {
    public func render(_ frame: CGImage) {
        show(frame)
    }
}
#endif

/// Drives the avatar window at 25 FPS. Two cooperating tasks:
///
/// - **Producer** (background QoS) keeps the engine busy: dequeues
///   speech chunks the moment they're ready, falls back to
///   `generateIdleChunk()` when nothing's speaking, appends frames
///   to a shared ring buffer. Generation latency is hidden behind
///   the buffer.
///
/// - **Consumer** (DispatchSourceTimer at 40 ms) pops one frame per
///   tick and hands it to the window on the main queue. When the
///   buffer is empty the consumer repeats the last rendered frame —
///   smooth at 25 FPS regardless of engine pace.
///
/// Halo's exact pattern. Without it the producer's per-chunk
/// generation latency (~600 ms for an idle chunk on M5) collapses
/// the display to ~15 FPS.
public final class FramePump: @unchecked Sendable {
    private let bithuman: Bithuman
    /// Closure invoked with each speech chunk's 24 kHz audio so it
    /// can be played back through the local pipeline. In on-device
    /// (`VoiceChat`) mode this routes to `chat.playAvatarAudio`. In
    /// cloud mode (libwebrtc owns playback) this is `nil` — the
    /// inbound audio track plays on its own and the FramePump only
    /// touches the visual side.
    private let playSpeechAudio: (@Sendable ([Float]) async -> Void)?
    /// Closure invoked when the portrait identity changes — used by
    /// `resetIdleCache` to flush whatever audio is currently in
    /// flight on the local player so the OLD voice doesn't keep
    /// talking for a second or two after a swap. Nil in cloud mode
    /// (no portrait-swap menu, and libwebrtc owns the audio anyway).
    private let onIdentityResetFlushAudio: (@Sendable () -> Void)?
    /// Activity flags the producer respects to avoid racing MLX work
    /// on the same global compiler cache. In on-device mode these
    /// come from `VoiceChat`; in cloud mode they're inert (nothing
    /// else uses MLX besides the avatar engine itself).
    private let llmActivity: ActivityFlag
    private let swapActivity: ActivityFlag
    private let sink: AvatarFrameSink
    public let buffer = FrameBuffer()
    /// Palindrome cache of idle frames. After ~10 s of continuous
    /// idle DiT generation, the cache fills and the producer stops
    /// calling the engine entirely — it just loops these frames
    /// forward / reverse / forward. Drops GPU from ~90 % (idle DiT
    /// running flat-out) to near-zero during idle.
    let idleCache = IdleFrameCache()
    /// Weak reference back to the coordinator so the producer loop
    /// can publish idle-prewarm progress. Strong elsewhere — the
    /// coordinator and pump live for the same scope; we use weak
    /// only to avoid a retain cycle through the producer's
    /// captured closure.
    private weak var coordinator: AvatarCoordinator?
    private var producerTask: Task<Void, Never>?
    private var consumerTimer: DispatchSourceTimer?
    /// Signaled when the producer Task exits its loop. AppDelegate
    /// waits on this from `applicationWillTerminate` so we don't
    /// run `drainGPU()` while the producer's in-flight
    /// `generateIdleChunk` is still submitting MLX work — that
    /// race was the v0.5.3 quit-time SIGTRAP at `mlx_eval`.
    private let producerStopped = DispatchSemaphore(value: 0)

    /// Construct a FramePump that drives `sink` at 25 FPS. The sink
    /// is typically `AvatarWindow` on macOS or the UIKit
    /// `AvatarRendererView` on iOS / iPadOS — both conform to
    /// `AvatarFrameSink`.
    public init(bithuman: Bithuman, chat: VoiceChat, window: AvatarFrameSink, coordinator: AvatarCoordinator) {
        self.bithuman = bithuman
        self.playSpeechAudio = { @Sendable samples in await chat.playAvatarAudio(samples24k: samples) }
        self.onIdentityResetFlushAudio = { @Sendable [weak chat] in
            guard let chat else { return }
            Task { @MainActor in chat.onBargeIn?() }
        }
        self.llmActivity = chat.llmActivity
        self.swapActivity = chat.swapActivity
        self.sink = window
        self.coordinator = coordinator

        let buffer = self.buffer
        let idleCache = self.idleCache
        let producerStopped = self.producerStopped
        let playSpeechAudio = self.playSpeechAudio
        let llmActivity = self.llmActivity
        let swapActivity = self.swapActivity
        self.producerTask = Task.detached(priority: .userInitiated) { [bithuman, buffer, idleCache, producerStopped, weak coordinator] in
            await Self.producerLoop(
                bithuman: bithuman,
                playSpeechAudio: playSpeechAudio,
                llmActivity: llmActivity,
                swapActivity: swapActivity,
                buffer: buffer,
                idleCache: idleCache,
                coordinator: coordinator
            )
            // Once the loop returns (Task cancelled and the
            // in-flight engine call has settled), let the
            // shutdown path proceed to drainGPU.
            producerStopped.signal()
        }

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "ai.bithuman.cli.framepump.display", qos: .userInteractive)
        )
        timer.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .microseconds(500))
        // Track first-frame so we can flip coordinator.isReady once
        // the avatar has actually started rendering — this gates
        // the LoadingParticleField fade-out.
        var firstFrameSeen = false
        let sink = self.sink
        timer.setEventHandler { [buffer, sink, weak coordinator] in
            guard let frame = buffer.popOrRepeat() else { return }
            DispatchQueue.main.async {
                sink.render(frame)
                buffer.tickStats(frameRendered: true)
                if !firstFrameSeen {
                    firstFrameSeen = true
                    coordinator?.markEngineReady()
                }
            }
        }
        timer.resume()
        self.consumerTimer = timer
    }

    /// Cloud-mode constructor — no `VoiceChat`, no LLM/swap activity
    /// gates (cloud mode doesn't use local MLX for inference). The
    /// optional `playSpeechAudio` closure is the speaker hook: when
    /// provided, the producer plays each speech chunk's `audio24k`
    /// in lockstep with its frames (the chunk-paired A/V-sync
    /// pattern). Pass `nil` to let libwebrtc auto-play the bot
    /// audio (causes ~1–2 s drift since Bithuman's frames land
    /// after the DiT chunk window). Used by
    /// `bithuman-cli avatar --openai` for both Essence and Expression
    /// .imx bundles.
    public init(
        bithuman: Bithuman,
        window: AvatarFrameSink,
        coordinator: AvatarCoordinator? = nil,
        playSpeechAudio: (@Sendable ([Float]) async -> Void)? = nil
    ) {
        self.bithuman = bithuman
        self.playSpeechAudio = playSpeechAudio
        self.onIdentityResetFlushAudio = nil
        self.llmActivity = ActivityFlag()
        self.swapActivity = ActivityFlag()
        self.sink = window
        self.coordinator = coordinator

        let buffer = self.buffer
        let idleCache = self.idleCache
        let producerStopped = self.producerStopped
        let playSpeechAudio = self.playSpeechAudio
        let llmActivity = self.llmActivity
        let swapActivity = self.swapActivity
        self.producerTask = Task.detached(priority: .userInitiated) { [bithuman, buffer, idleCache, producerStopped, weak coordinator] in
            await Self.producerLoop(
                bithuman: bithuman,
                playSpeechAudio: playSpeechAudio,
                llmActivity: llmActivity,
                swapActivity: swapActivity,
                buffer: buffer,
                idleCache: idleCache,
                coordinator: coordinator
            )
            producerStopped.signal()
        }

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "ai.bithuman.cli.framepump.display.cloud", qos: .userInteractive)
        )
        timer.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .microseconds(500))
        var firstFrameSeen = false
        let sink = self.sink
        timer.setEventHandler { [buffer, sink, weak coordinator] in
            guard let frame = buffer.popOrRepeat() else { return }
            DispatchQueue.main.async {
                sink.render(frame)
                buffer.tickStats(frameRendered: true)
                if !firstFrameSeen {
                    firstFrameSeen = true
                    coordinator?.markEngineReady()
                }
            }
        }
        timer.resume()
        self.consumerTimer = timer
    }

    /// Inject a pre-rendered set of idle frames (typically loaded
    /// from disk on boot) into the palindrome cache. Once seeded,
    /// `idleCache.isReady` becomes true and the producer skips
    /// `generateIdleChunk` entirely — saves ~10 s of cold-start
    /// GPU time on every launch after the first for a given identity.
    public func seedIdleCache(frames: [CGImage]) {
        guard !frames.isEmpty else { return }
        idleCache.absorb(frames, epoch: idleCache.currentEpoch)
        if let coordinator {
            let count = idleCache.frameCount
            let total = IdleFrameCache.targetCount
            Task { @MainActor in
                coordinator.updateIdlePrewarm(count: count, total: total)
            }
        }
    }

    /// Snapshot the current idle palindrome cache so the runner can
    /// persist it to disk after prewarm completes.
    public func snapshotIdleCache() -> [CGImage] {
        idleCache.snapshot()
    }

    /// `true` once the idle palindrome cache is fully populated.
    public var idleCacheReady: Bool { idleCache.isReady }

    /// Pump several idle palindrome frames into the buffer right
    /// now so the avatar visibly transitions to idle motion within
    /// one display tick instead of freezing on the last speech
    /// frame. Used by barge-in to bridge the gap between
    /// `flushSpeech()` (clears the queue) and the producer's next
    /// idle-cache appends (~40 ms later — long enough to flicker).
    public func snapToIdleNow(frameCount: Int = 6) {
        guard idleCache.isReady else { return }
        for _ in 0..<frameCount {
            if let f = idleCache.next() {
                buffer.appendIdleFrame(f)
            }
        }
    }

    public func cancel() {
        producerTask?.cancel()
        consumerTimer?.cancel()
    }

    /// Block the calling thread until the producer Task has exited
    /// its loop (typically right after the in-flight
    /// `generateIdleChunk` returns) or `timeoutMs` elapses. Call
    /// from `applicationWillTerminate` AFTER `cancel()` and BEFORE
    /// `VoiceChat.drainGPU()` so we don't race the engine's last
    /// MLX dispatch.
    public func waitForProducerStop(timeoutMs: Int) {
        _ = producerStopped.wait(timeout: .now() + .milliseconds(timeoutMs))
    }

    /// Drop every cached idle frame and resume DiT generation. Call
    /// this whenever the avatar's portrait changes — the new face
    /// has different breathing motion, so the old cache would feel
    /// off. ~10 s after a portrait swap, the cache will be full again.
    func resetIdleCache() {
        idleCache.reset()
        // Roll the splash gate back so the user sees the warm-up
        // overlay again while the new identity's idle frames fill
        // — symmetric with the initial-boot behaviour.
        if let coordinator {
            Task { @MainActor in coordinator.resetIdlePrewarm() }
        }
        // Stop the previous identity mid-sentence: drop any speech
        // frames the producer has queued, and tell the host to
        // flush whatever audio is in flight on the player side.
        // Without this, the user hears the OLD voice keep talking
        // for a second or two after picking a new agent.
        buffer.flushSpeech()
        // Tell the host to flush in-flight player audio (on-device
        // mode) — cloud mode skips this since libwebrtc owns the
        // speaker and there's no local audio to flush.
        onIdentityResetFlushAudio?()
    }

    /// Lock-protected frame queue shared between the producer Task
    /// and the consumer DispatchSourceTimer. Tracks per-second FPS
    /// and engine realtime-factor stats too — both sides write to it
    /// so it's the natural home.
    public final class FrameBuffer: @unchecked Sendable {
        public enum Source { case speech, idle }
        struct Entry { let frame: CGImage; let source: Source }

        private let lock = NSLock()
        private var queue: [Entry] = []
        private var lastFrame: CGImage?

        // Stats
        private var statsWindowStart = Date()
        private var framesRenderedThisWindow = 0
        private var speechFramesThisWindow = 0
        private var idleFramesThisWindow = 0
        private var repeatedFramesThisWindow = 0
        private var lastSpeechChunkAt: Date?
        private var speechAudioSecondsThisWindow: Double = 0
        private var speechWallSecondsThisWindow: Double = 0
        private let statsEnabled: Bool

        init() {
            statsEnabled = ProcessInfo.processInfo.environment["BITHUMAN_STATS"] != nil
                || ProcessInfo.processInfo.environment["BITHUMAN_DEBUG_PUMP"] != nil
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return queue.count
        }

        /// True if the queue has at least one speech entry. Used by
        /// `VoiceChat.onCheckSpeechBuffer` so the orchestrator can
        /// wait for our consumer-side queue to drain before flipping
        /// back to .listening.
        public var hasSpeech: Bool {
            lock.lock(); defer { lock.unlock() }
            return queue.contains { $0.source == .speech }
        }

        /// Drop every queued speech entry. Called from barge-in
        /// cleanup so the avatar transitions to idle motion right
        /// away instead of finishing the audio-cancelled reply for
        /// another second-or-two while the buffered frames drain.
        public func flushSpeech() {
            lock.lock()
            queue.removeAll { $0.source == .speech }
            lock.unlock()
        }

        /// Append a single cached idle frame (no audio). Used by the
        /// palindrome cache fast path — the producer no longer
        /// generates an idle CHUNK when the cache is hot, just
        /// trickles frames one at a time into the consumer queue.
        func appendIdleFrame(_ frame: CGImage) {
            lock.lock()
            queue.append(Entry(frame: frame, source: .idle))
            lock.unlock()
        }

        func appendChunk(_ chunk: TimedChunk, source: Source) {
            lock.lock()
            // When a speech chunk arrives, drop any queued idle
            // frames so the consumer doesn't render seconds of stale
            // breathing motion while the new speech audio is already
            // playing through the speaker. Speech audio is scheduled
            // at the same moment its frames are appended; A/V stays
            // in lockstep only if the consumer pops the frames in
            // the same window the audio plays.
            if source == .speech, queue.contains(where: { $0.source == .idle }) {
                queue.removeAll { $0.source == .idle }
            }
            for f in chunk.frames {
                queue.append(Entry(frame: f, source: source))
            }
            // Engine RTF: how many seconds of audio per second of
            // wallclock the engine produced *this* chunk in.
            if source == .speech {
                let audioSec = Double(chunk.frames.count) / 25.0
                if let last = lastSpeechChunkAt {
                    speechWallSecondsThisWindow += Date().timeIntervalSince(last)
                }
                speechAudioSecondsThisWindow += audioSec
                lastSpeechChunkAt = Date()
            }
            lock.unlock()
        }

        /// Pop the next frame to display, or repeat the last one if
        /// the queue is empty. Called from the 25 FPS consumer.
        func popOrRepeat() -> CGImage? {
            lock.lock(); defer { lock.unlock() }
            if let entry = queue.first {
                queue.removeFirst()
                lastFrame = entry.frame
                if entry.source == .speech { speechFramesThisWindow += 1 }
                else                       { idleFramesThisWindow   += 1 }
                return entry.frame
            }
            if let last = lastFrame {
                repeatedFramesThisWindow += 1
                return last
            }
            return nil
        }

        /// Called after each successful main-thread render. Rolls up
        /// per-second FPS + engine RTF when the window crosses 1 s.
        func tickStats(frameRendered: Bool) {
            guard statsEnabled, frameRendered else { return }
            lock.lock()
            framesRenderedThisWindow += 1
            let elapsed = Date().timeIntervalSince(statsWindowStart)
            if elapsed >= 1.0 {
                let fps = Double(framesRenderedThisWindow) / elapsed
                let rtf: Double = speechWallSecondsThisWindow > 0
                    ? speechAudioSecondsThisWindow / speechWallSecondsThisWindow
                    : 0
                let line = String(format:
                    "[stats] fps=%.1f (speech=%d, idle=%d, repeat=%d) buffer=%d  engine_rtf=%.2f (%.2fs audio / %.2fs wall)\n",
                    fps,
                    speechFramesThisWindow, idleFramesThisWindow, repeatedFramesThisWindow,
                    queue.count, rtf,
                    speechAudioSecondsThisWindow, speechWallSecondsThisWindow
                )
                FileHandle.standardError.write(Data(line.utf8))
                statsWindowStart = Date()
                framesRenderedThisWindow = 0
                speechFramesThisWindow = 0
                idleFramesThisWindow = 0
                repeatedFramesThisWindow = 0
                speechAudioSecondsThisWindow = 0
                speechWallSecondsThisWindow = 0
            }
            lock.unlock()
        }
    }

    private static func producerLoop(
        bithuman: Bithuman,
        playSpeechAudio: (@Sendable ([Float]) async -> Void)?,
        llmActivity: ActivityFlag,
        swapActivity: ActivityFlag,
        buffer: FrameBuffer,
        idleCache: IdleFrameCache,
        coordinator: AvatarCoordinator?
    ) async {
        let debug = ProcessInfo.processInfo.environment["BITHUMAN_DEBUG_PUMP"] != nil
        if debug {
            FileHandle.standardError.write(Data("[pump] producerLoop entered\n".utf8))
        }
        // Aggressive snapshot logging when BITHUMAN_DEBUG_PUMP is
        // set — emits Bithuman's pendingAudio / inFlight / chunkQueue
        // counts every ~1 s so we can tell whether the engine is
        // accumulating audio without dispatching, dispatching but
        // stalled, or producing chunks the consumer isn't dequeuing.
        var snapshotReportAt = Date()
        var totalChunksDequeued: Int = 0

        // Stuck-detection. `flushTailIfNeeded` is one-shot per
        // response; once it fires, residual pendingAudio stays
        // pinned (no further dispatch will reduce it). We have to
        // hard-`flush()` to break out of that state so idle can
        // resume. This timer gives any in-flight chunk ~1.5 s to
        // land before we yank the queue.
        var stuckSince: Date?

        while !Task.isCancelled {
            if debug, Date().timeIntervalSince(snapshotReportAt) > 1.0 {
                let snap = bithuman.snapshot
                FileHandle.standardError.write(Data(
                    "[pump] pendingA16=\(snap.pendingAudio16Count) inFlight=\(snap.inFlight) chunksDequeued=\(totalChunksDequeued) bufferCount=\(buffer.count)\n".utf8
                ))
                snapshotReportAt = Date()
            }
            // Speech back-pressure: when the consumer-side buffer is
            // already holding ~3 s of frames (engine RTF runs ~1.6×
            // realtime on Apple Silicon, so the producer can outpace
            // the 25 FPS consumer during long bot replies), skip the
            // dequeue and let the buffer drain. NOT calling
            // `tryDequeueChunk` is what propagates the back-pressure
            // upstream — the engine's chunk queue tops out at the
            // depth it can hold before the next dispatch blocks.
            // Without this cap a 6-sentence reply queues 200+ frames
            // (~120 MB of CGImages) before the consumer catches up.
            if buffer.count > 75 {
                try? await Task.sleep(nanoseconds: 40_000_000)
                continue
            }

            if let speech = bithuman.tryDequeueChunk() {
                stuckSince = nil
                totalChunksDequeued += 1
                // After an agent/portrait swap, drop any speech
                // chunks that land while the new identity's cache
                // refills — those chunks were generated for the
                // PREVIOUS identity (face + voice mismatch) and
                // would also stall idle generation, deadlocking
                // the prewarm fill. Initial boot leaves the gate
                // off so a user who talks immediately still hears
                // the bot through the splash.
                //
                // Atomicity matters: gate read + buffer append
                // happen on the same MainActor hop so a swap that
                // fires `resetIdlePrewarm` between two separate
                // hops can't slip a stale-identity chunk into the
                // (just-flushed) buffer. The audio scheduling is
                // delegated to chat (also @MainActor) so it
                // serialises with the same gate.
                let shouldPlay = await MainActor.run { () -> Bool in
                    if coordinator?.muteAgentDuringPrewarm ?? false {
                        return false
                    }
                    buffer.appendChunk(speech, source: .speech)
                    return true
                }
                if !shouldPlay { continue }
                if let audio24k = speech.audio24k, let playSpeechAudio {
                    // Chunk-paired audio: audio for *this* chunk's
                    // frames, scheduled the moment we add those
                    // frames to the display buffer. Audio queues
                    // back-to-back on the player; video plays at
                    // 25 FPS from the buffer. They were generated
                    // 1:1 from the same audio window, so they stay
                    // synchronised structurally — no anchor math.
                    //
                    // Cloud mode (`playSpeechAudio == nil`) skips
                    // this — libwebrtc plays the bot's audio via
                    // its own speaker pipeline; the FramePump only
                    // renders the visual side.
                    await playSpeechAudio(audio24k)
                }
                continue
            }

            let snap = bithuman.snapshot
            let hasResidual = snap.inFlight || snap.pendingAudio16Count > 0
            if hasResidual {
                if stuckSince == nil { stuckSince = Date() }
                if Date().timeIntervalSince(stuckSince!) > 1.5 {
                    // Engine's been holding residual state without
                    // producing chunks for 1.5 s. Force-flush so we
                    // can transition back to idle.
                    await bithuman.flush()
                    stuckSince = nil
                    continue
                }
            } else {
                stuckSince = nil
            }

            if snap.inFlight {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            if snap.pendingAudio16Count > 0 {
                await bithuman.flushTailIfNeeded()
                // Brief backoff so the dispatched chunk has time to
                // land before we re-poll.
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }

            // Don't outrun the consumer with idle frames. Keep only
            // ~1 chunk worth (~25 frames = 1 s) buffered for idle.
            // A larger queue makes A/V sync worse: when speech
            // arrives, the consumer is still draining stale idle
            // frames while the speech audio is already playing.
            if buffer.count > 25 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            // MLX safety: skip idle DiT dispatches while ANY other
            // MLX-bound work is in flight — chat LLM (Gemma) or
            // VAE face encode (drag-drop / agent pick). All three
            // share MLX's global compiler cache; concurrent
            // dispatches race the cache and segfault the producer
            // mid-`generateIdleChunk` (v0.4.1 crash report). Sleep
            // long enough to amortise the wake but short enough
            // that post-MLX idle resumes promptly.
            if llmActivity.isActive || swapActivity.isActive {
                try? await Task.sleep(nanoseconds: 80_000_000)
                continue
            }

            // Fast path: once we've stockpiled ~10 s of idle frames,
            // stop calling the engine and just loop them palindrome-
            // style. GPU drops from ~90 % (idle DiT running flat-out)
            // to near-zero. The cache is invalidated when the user
            // swaps the portrait — see `FramePump.resetIdleCache`.
            if idleCache.isReady {
                if let frame = idleCache.next() {
                    buffer.appendIdleFrame(frame)
                }
                try? await Task.sleep(nanoseconds: 40_000_000)
                continue
            }

            // Snapshot the cache epoch BEFORE the ~600 ms generate
            // call. If a portrait swap fires `resetIdleCache()`
            // mid-call, the epoch rolls and the absorb below
            // becomes a no-op — keeping the new cache from being
            // poisoned by stale-identity frames.
            let epochBefore = idleCache.currentEpoch
            if let idle = await bithuman.generateIdleChunk() {
                // The buffer always gets the freshly-generated
                // frames so the consumer has something to render
                // (or in the swap case, briefly drains stale
                // frames before the new identity's chunks arrive).
                buffer.appendChunk(idle, source: .idle)
                // Cache absorption is the part that needs the
                // epoch guard — these frames define the palindrome
                // loop's identity for the rest of the session.
                idleCache.absorb(idle.frames, epoch: epochBefore)
                // Push the new fill ratio to the splash so the
                // pre-chat progress bar tracks reality.
                let count = idleCache.frameCount
                let total = IdleFrameCache.targetCount
                if let coordinator {
                    await MainActor.run {
                        coordinator.updateIdlePrewarm(count: count, total: total)
                    }
                }
            } else {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

}
