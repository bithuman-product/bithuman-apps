// `bithuman-cli avatar` — voice + lip-synced face.
//
// This file owns the avatar mode's full surface. It dispatches
// across four runtime combinations:
//
//   { Expression .imx | Essence .imx } x { local LLM/TTS | OpenAI cloud }
//
// `bootstrapVideo` is the entry point; `runVideoSession` peeks
// the `.imx` manifest's `model_type` and routes to the matching
// `runExpression…` or `runEssence…` runner.
//
// Window sizing utilities (`centeredOrigin`) and the hardware
// readiness hint (`videoHardwareHint`) live here too because
// they're avatar-specific.

import AppKit
import AVFoundation
import Foundation
import bitHumanKit
import BithumanRealtimeOpenAI
import Speech

func runVideoSession(args: CLIArgs) async throws {
    if let hint = videoHardwareHint(args: args) {
        FileHandle.standardError.write(Data("\n\(hint)\n\n".utf8))
    }
    if let modelArg = args.modelArg {
        let url = URL(fileURLWithPath: (modelArg as NSString).expandingTildeInPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            fatalUsage("--model: file not found at '\(url.path)'.")
        }
        // Peek the manifest's model_type before paying for any
        // engine warm-up. `peekModelType` only reads the IMX header
        // + manifest.json (~few ms of disk I/O) so misuse surfaces
        // immediately — not five seconds into a wasted DiT load.
        let modelType: String?
        do {
            modelType = try Bithuman.peekModelType(modelPath: url)
        } catch let err as BithumanCreateError {
            switch err {
            case .invalidModelFile(let msg):
                fatalUsage("--model: '\(url.lastPathComponent)' isn't a valid .imx (\(msg)).")
            default:
                fatalUsage("--model: \(err)")
            }
        } catch {
            fatalUsage("--model: \(error)")
        }
        switch modelType {
        case "expression":
            if args.openAI {
                try await runExpressionVideoSessionOpenAIWebRTC(args: args, modelPath: url)
            } else {
                try await runExpressionVideoSession(args: args, modelPath: url)
            }
            return
        case "essence":
            if args.openAI {
                try await runEssenceVideoSessionOpenAIWebRTC(args: args, modelPath: url)
            } else {
                try await runEssenceVideoSession(args: args, modelPath: url)
            }
            return
        case let other:
            let label = other ?? "<missing model_type>"
            fatalUsage("""
                --model: '\(url.lastPathComponent)' has model_type=\(label).
                  bithuman-cli accepts model_type=\"expression\" or \"essence\".
                """)
        }
    }
    // No `--model` / `--identity` was supplied. Two cases:
    //
    //   1. `--image <portrait>` was supplied — user explicitly wants
    //      a custom-portrait Expression avatar. Stay on Expression
    //      with the supplied JPG/PNG.
    //
    //   2. Neither was supplied — there's no Essence auto-default
    //      right now (the supabase `model_path` field stores raw
    //      asset tarballs, not runtime-ready packed `.imx` files —
    //      see DefaultEssenceAgent.swift for the history). Print a
    //      friendly hint pointing the user at `--identity` instead
    //      of fetching a known-bad URL.
    if args.imageArg != nil {
        // Case 1 — Expression with custom portrait.
        if args.openAI {
            try await runExpressionVideoSessionOpenAIWebRTC(args: args, modelPath: nil)
        } else {
            try await runExpressionVideoSession(args: args, modelPath: nil)
        }
        return
    }

    // Case 2 — no auto-default; print a hint. Surface the known-
    // good local Essence asset if it's already cached so the user
    // has a one-line copy-paste path to a working session.
    let cachedSample = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/bithuman/models/sample-avatar.imx")
    let sampleHint = FileManager.default.fileExists(atPath: cachedSample.path)
        ? "  Try:  bithuman-cli avatar --identity \(cachedSample.path)\n"
        : ""
    let msg = """

    error: avatar mode needs an `.imx` file — pass `--identity <path>`.

      bithuman-cli avatar --identity ~/path/to/agent.imx     # Expression or Essence
      bithuman-cli avatar --image    ~/me.jpg                # Expression w/ your portrait
    \(sampleHint)
    Get an `.imx` from your bitHuman dashboard at https://www.bithuman.ai

    """
    FileHandle.standardError.write(Data(msg.utf8))
    exit(2)
}

/// Essence-mode video session. Boots a `VoiceChat` WITHOUT
/// `config.avatar` (so it skips the Expression engine + heartbeat
/// branch entirely), then layers an Essence-shaped audio + frame
/// fan-out on top:
///
///   1. ``EssenceRuntime/create`` — opens the .imx, validates
///      `model_type`, builds the per-frame generator. Throws on
///      unsupported hardware / malformed file with the same typed
///      error surface the Expression path uses.
///   2. ``AvatarWindow`` with `clipMode=.fill` at the manifest's
///      `output_resolution` — borderless rectangular floating window.
///   3. PCM observer on the TTS player (Qwen3-TTS in voice mode by
///      default; the only TTS active here since `config.avatar` is
///      nil): each chunk is resampled to 16 kHz Int16 and pushed
///      into ``EssenceRuntime/pushAudio(_:)``.
///   4. Consumer task drains ``EssenceRuntime/frames()`` and
///      forwards each `CGImage` to the window's renderer.
///
/// `--voice` and `--image` are no-ops on this path — Essence's
/// voice and identity are baked into the .imx at pack time. We print
/// a friendly note rather than silently ignoring the flag so the
/// user knows their argument didn't take.
/// Replace the running CLI process with a fresh `bithuman-cli video
/// --model <newPath>` invocation. Used by the Essence right-click
/// menu's "Choose model…" action — hot-swapping the .imx in place
/// would mean tearing down `EssenceRuntime`, the frame consumer, the
/// PCM bridge, and possibly resizing the window if the new
/// manifest's `output_resolution` differs. Process replacement is a
/// 5-line equivalent that's trivially correct; hot-swap is queued
/// for v2.
///
/// `execv` semantics: the current process image is replaced by the
/// new one (same PID, same parent). If the user launched from a
/// terminal, the terminal session continues uninterrupted; if from
/// `open`, the avatar window blanks for a beat then reappears with
/// the new model. Splash + boot progress run as usual.
@MainActor
private func relaunchEssenceProcess(modelPath: URL) {
    let exec = CommandLine.arguments.first ?? "/usr/bin/env"
    let argv = [
        exec,
        "video",
        "--model", modelPath.path
    ]
    // execv requires C strings + a NULL terminator. `withCString`
    // gives us valid pointers for the duration of the call; execv
    // never returns on success.
    let cstrings = argv.map { strdup($0) }
    defer { cstrings.forEach { free($0) } }
    var argvPtr: [UnsafeMutablePointer<CChar>?] = cstrings.map { $0 }
    argvPtr.append(nil)
    print("🔁 swapping to \(modelPath.lastPathComponent)…")
    fflush(stdout)
    _ = argvPtr.withUnsafeMutableBufferPointer { buf in
        execv(exec, buf.baseAddress!)
    }
    // execv only returns if it failed — print and exit so we don't
    // continue with a torn-down session.
    let err = String(cString: strerror(errno))
    FileHandle.standardError.write(Data(
        "error: failed to relaunch (\(err)). Quit and rerun manually with --model.\n".utf8
    ))
    exit(1)
}

@MainActor
private func runEssenceVideoSession(args: CLIArgs, modelPath: URL) async throws {
    if args.imageArg != nil {
        print("note: --image is a no-op for Essence avatars — the .imx bakes its identity in at pack time. The flag has been dropped for this session.")
    }
    // --voice IS honoured for Essence: the avatar's identity is
    // baked into the .imx, but the voice driving the lip-sync comes
    // from the TTS player (Qwen3-TTS in voice mode). The right-click
    // menu lets the user hot-swap the voice at runtime; the flag
    // here is for parity with `bithuman-cli voice --voice …` so the
    // user can boot directly into a chosen voice.

    // Unified boot UI for the Essence path. Engine load + VoiceChat
    // pipeline (LLM, TTS, audio graph) all flow through the same
    // ``BootProgress`` so the user sees one self-overwriting
    // status line in their terminal AND a graphical splash window
    // covering the same stages — no blank-screen gap before the
    // avatar window opens.
    // Terminal-only progress: the build-log style block from
    // TerminalProgressRenderer is rich enough to keep the user
    // engaged without a graphical splash. Avatar window opens once
    // boot completes — see below.
    let boot = BootProgress()
    let renderer = TerminalProgressRenderer(progress: boot)
    renderer.attach()

    boot.update(.loadingExpressionEngine)
    // Push the synchronous engine load off the main actor — same
    // rationale as the Expression branch: avoids freezing any
    // SwiftUI redraws during the multi-second weight unpack.
    // Async create authenticates with the bitHuman billing service
    // before returning the runtime. Throws BithumanCreateError.missingAPIKey
    // when no key is resolvable; throws .authenticationFailed for
    // expired / suspended / over-balance accounts. We catch + reframe
    // as a fatalUsage with a one-line setup pointer so users see a
    // clean error rather than a stack trace.
    let runtime: EssenceRuntime
    do {
        runtime = try await EssenceRuntime.create(modelPath: modelPath, apiSecret: BithumanKey.load())
    } catch BithumanCreateError.missingAPIKey {
        fatalBitHumanKeyMissing()
    } catch BithumanCreateError.authenticationFailed(let underlying) {
        fatalBitHumanAuthFailed(underlying)
    }
    let resolution = runtime.resolution
    let size = CGSize(width: resolution.width, height: resolution.height)

    // Audio-only VoiceChat — no AvatarConfig, no Expression engine,
    // no heartbeat. The Essence runtime is wired up below as a
    // PCM-observer side-channel rather than through the
    // Expression-shaped `AvatarConfig` plumbing in `VoiceChat.start()`.
    var config = makeConfig(args)
    // Honour --voice (preset name or path-to-audio for cloning) the
    // same way `bithuman-cli voice` does. Defaults to .default when
    // the flag isn't supplied.
    config.voice = await resolveVoice(args)
    config.bootProgress = boot
    let chat = VoiceChat(config: config)
    try await chat.start()
    boot.update(.ready)
    renderer.detach()

    let window = AvatarWindow(targetSize: size, clipMode: .fill)
    window.setFrameOrigin(centeredOrigin(forSize: window.frame.size))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    // Right-click menu: Choose model… / Change voice ▶ / Change
    // prompt… / Quit. Hooks into the same coordinator the Expression
    // path uses so PromptEditorWindow can reuse `setSystemPrompt`,
    // and into VoiceChat for hot-swapping the Qwen3 reference voice.
    let coordinator = AvatarCoordinator(chat: chat)
    coordinator.bindToOrchestrator()
    coordinator.currentSystemPrompt = config.systemPrompt ?? ""
    let menuHandler = EssenceMenuHandler(
        chat: chat,
        coordinator: coordinator,
        currentModelPath: modelPath,
        relaunchWithModel: { newURL in
            relaunchEssenceProcess(modelPath: newURL)
        }
    )
    let essenceMenu = menuHandler.buildMenu()
    window.contentView?.menu = essenceMenu
    // Renderer subview also takes the menu so right-click on the
    // avatar pixels (not just the empty corners) surfaces it.
    for sub in window.contentView?.subviews ?? [] {
        sub.menu = essenceMenu
    }

    // EssenceVoiceChatSession (promoted from CLI-internal in v0.18 so
    // the apps can share it). Owns the frame consumer task and the
    // PCM bridge.
    let session = EssenceVoiceChatSession(runtime: runtime, sink: window)
    session.startConsuming()

    // PCM bridge: each TTS chunk → 16 kHz Int16 → runtime.pushAudio.
    await chat.setPCMObserver { [bridge = session.pcmBridge] pcm in
        bridge.handle(pcm)
    }
    // Essence has no FramePump to replay TTS audio; we want the
    // speaker to keep playing the bot directly. (Expression's
    // default is to suppress, which is what `VoiceChat.start()`
    // installs for the avatar branch — but we never took that
    // branch since `config.avatar == nil`. The TTS player still
    // defaults to "suppress when observed" though, so we have to
    // explicitly opt out of that here.)
    await chat.setSuppressDirectPlaybackWhenObserved(false)

    // Park the chat + session on the AppDelegate so they outlive
    // this function — without explicit retains they'd be released
    // and the avatar would freeze. The delegate's existing
    // `retainSession` API takes a `FramePump`, which Essence
    // doesn't use, so we only stash the chat. The session itself
    // is captured by the strong reference in the chat's PCM
    // observer closure, keeping the runtime + window alive for
    // the lifetime of the chat.
    if let delegate = NSApp.delegate as? BithumanAppDelegate {
        delegate.avatarWindow = window
        delegate.retainEssenceSession(chat: chat, session: session)
        // Pin the menu handler too — NSMenu's target/action holds a
        // weak ref through the menu item, so without an external
        // strong ref the handler would deallocate at scope exit and
        // every selection would be a no-op.
        delegate.retainEssenceMenuHandler(menuHandler)
    }

    // Stdin reader — same shape as the Expression path's, lets the
    // user type messages through the same orchestrator turn flow.
    Task.detached(priority: .background) { [chat] in
        while !Task.isCancelled, let line = readLine() {
            await chat.inject(userText: line)
        }
    }

    print("🎥 essence avatar window ready. Talk or type any time. Ctrl-C or ⌘Q to quit.")
}

/// Essence video session driven by OpenAI Realtime over WebRTC.
/// Same transport as `voice --openai`, plus an `RTCAudioRenderer`
/// hooked to the inbound bot audio track so we get every PCM buffer
/// libwebrtc plays — perfect for `EssenceRuntime.pushAudio` lipsync.
/// libwebrtc handles speaker output AND mic capture (with built-in
/// AEC + NS + AGC), so we don't need our own `AudioGraph` here at
/// all — the host system speaker plays the bot's voice and the
/// renderer just observes the same PCM stream on its way out.
@MainActor
private func runEssenceVideoSessionOpenAIWebRTC(args: CLIArgs, modelPath: URL) async throws {
    guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
          !apiKey.isEmpty
    else {
        fatalKey()
    }

    let voice: String
    if let raw = args.voiceArg, !raw.contains("/"), !raw.contains(".") {
        voice = raw
    } else {
        voice = "ash"
    }
    var instructions: String? = nil
    if let raw = args.promptArg {
        guard let resolved = readInlineOrFile(raw) else {
            fatalUsage("--prompt: couldn't read '\(raw)'. Pass inline text or @path/to/file.txt.")
        }
        instructions = resolved
    }
    let verbose = ProcessInfo.processInfo.environment["VOICECHAT_VERBOSE"] == "1"

    // Boot block. No audio graph needed — libwebrtc owns mic +
    // speaker. The Essence runtime is the only heavy load step.
    let boot = BootProgress()
    let renderer = TerminalProgressRenderer(progress: boot)
    renderer.attach()

    boot.update(.loadingEssenceRuntime)
    // Async create authenticates with the bitHuman billing service
    // before returning the runtime. Throws BithumanCreateError.missingAPIKey
    // when no key is resolvable; throws .authenticationFailed for
    // expired / suspended / over-balance accounts. We catch + reframe
    // as a fatalUsage with a one-line setup pointer so users see a
    // clean error rather than a stack trace.
    let runtime: EssenceRuntime
    do {
        runtime = try await EssenceRuntime.create(modelPath: modelPath, apiSecret: BithumanKey.load())
    } catch BithumanCreateError.missingAPIKey {
        fatalBitHumanKeyMissing()
    } catch BithumanCreateError.authenticationFailed(let underlying) {
        fatalBitHumanAuthFailed(underlying)
    }
    let resolution = runtime.resolution
    let size = CGSize(width: resolution.width, height: resolution.height)

    // bitHuman billing heartbeat — Essence runtime is metered at
    // 1 credit/min. Same fallback to unmetered when no key.
    let bithumanHeartbeat = makeBithumanHeartbeat(
        billingType: BithumanAuthConfig.selfHostedEssenceModel,
        tags: "bithuman-cli/avatar/essence"
    )
    if let hb = bithumanHeartbeat {
        do { try await hb.authenticate(); await hb.resume() }
        catch {
            FileHandle.standardError.write(Data(
                "‼ bitHuman billing heartbeat failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    boot.update(.connectingRealtime)

    // Open the avatar window before WebRTC connects so the user sees
    // something while the SDP exchange runs.
    let window = AvatarWindow(targetSize: size, clipMode: .fill)
    window.setFrameOrigin(centeredOrigin(forSize: window.frame.size))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    let session = EssenceVoiceChatSession(runtime: runtime, sink: window)
    session.startConsuming()

    // Reuse the voice-mode UI for live mic + bot bars + transcripts.
    let ui = TerminalUI()
    await ui.start()
    // Per-minute spend reporter: prints elapsed time + accrued
    // bitHuman credits + estimated OpenAI $ to the scrolling area.
    let spendTracker = SpendTracker(
        runtime: .essence,
        ui: ui,
        openAIModel: args.openAIModel
    )
    await spendTracker.start()
    let voiceKnown = ["alloy", "ash", "ballad", "coral", "echo",
                      "sage", "shimmer", "verse", "marin", "cedar"]
        .contains(voice.lowercased())

    // Bot-PCM tap: every buffer libwebrtc would play through the
    // speaker is also delivered here. Convert from whatever format
    // libwebrtc is rendering at (typically 48 kHz Float32) to 16 kHz
    // Int16 mono and push into Essence for lipsync. Reset converter
    // when format changes (rare; libwebrtc renegotiates).
    let lipsyncFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    let converterBox = ConverterBox()
    let onBotPCM: @Sendable (AVAudioPCMBuffer) -> Void = { [ui, runtime] buffer in
        guard let conv = converterBox.converter(for: buffer.format, target: lipsyncFormat) else { return }
        let inFrames = Int(buffer.frameLength)
        let outCap = AVAudioFrameCount(Double(inFrames) * 16_000.0 / buffer.format.sampleRate + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: lipsyncFormat, frameCapacity: outCap) else { return }
        var delivered = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, statusOut in
            if delivered { statusOut.pointee = .noDataNow; return nil }
            delivered = true
            statusOut.pointee = .haveData
            return buffer
        }
        guard status != .error, let i16 = out.int16ChannelData?[0] else { return }
        let n = Int(out.frameLength)
        let samples = Array(UnsafeBufferPointer(start: i16, count: n))

        // RMS for the UI bot bar — quick subsample.
        var sum: Double = 0
        var c = 0
        var i = 0
        while i < n { let s = Double(samples[i]) / 32768.0; sum += s * s; c += 1; i += 8 }
        let rms: Float = c > 0 ? Float((sum / Double(c)).squareRoot()) : 0

        Task {
            await runtime.pushAudio(samples)
            await ui.setBotLevel(rms)
        }
    }

    // Connect the WebRTC client with the lipsync tap installed.
    let client = RealtimeWebRTCClient(
        apiKey: apiKey,
        model: args.openAIModel,
        voice: voice,
        instructions: instructions,
        ui: ui,
        verbose: verbose,
        onBotPCM: onBotPCM
    )
    try await client.connect()

    boot.update(.ready)
    renderer.detach()
    await ui.printOpeningBanner(
        model: args.openAIModel,
        voice: voice,
        verbose: verbose,
        keyValidated: true,
        voiceKnown: voiceKnown
    )

    // The receive loop is the same one voice mode uses — it drives
    // every state transition in the UI from the data-channel events.
    Task { try? await client.runReceiveLoop() }

    let forever = AsyncStream<Void> { _ in }
    for await _ in forever { break }
    _ = (client, runtime, session, window, ui, converterBox, bithumanHeartbeat, spendTracker)
}

/// Box for an AVAudioConverter so a `@Sendable` closure can capture
/// it across calls without crossing actor boundaries. The closure
/// only ever runs on libwebrtc's audio render thread, so there's no
/// real concurrent use — the box just satisfies the type checker.
final class ConverterBox: @unchecked Sendable {
    private var conv: AVAudioConverter?
    private var srcFormat: AVAudioFormat?
    func converter(for src: AVAudioFormat, target: AVAudioFormat) -> AVAudioConverter? {
        if conv == nil || srcFormat?.sampleRate != src.sampleRate
            || srcFormat?.channelCount != src.channelCount {
            conv = AVAudioConverter(from: src, to: target)
            srcFormat = src
        }
        return conv
    }
}


/// Expression video session driven by OpenAI Realtime over WebRTC.
/// Mirrors `runEssenceVideoSessionOpenAIWebRTC` but for the
/// Expression engine — auto-downloads weights when no `.imx` is
/// supplied, resolves a portrait identity (custom image or the
/// bundled default agent), constructs `Bithuman` directly without
/// `VoiceChat` (no local LLM/TTS/ASR needed in cloud mode), and
/// drives lipsync from the inbound bot audio track via
/// `Bithuman.pushAudio(audio24k:audio16k:)`. libwebrtc owns the
/// speaker (with built-in AEC + NS + AGC), so the FramePump runs
/// in cloud mode where its speech-audio playback hook is `nil`.
@MainActor
private func runExpressionVideoSessionOpenAIWebRTC(
    args: CLIArgs,
    modelPath: URL?
) async throws {
    guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
          !apiKey.isEmpty
    else {
        fatalKey()
    }

    let voice: String
    if let raw = args.voiceArg, !raw.contains("/"), !raw.contains(".") {
        voice = raw
    } else {
        voice = "ash"
    }
    var instructions: String? = nil
    if let raw = args.promptArg {
        guard let resolved = readInlineOrFile(raw) else {
            fatalUsage("--prompt: couldn't read '\(raw)'. Pass inline text or @path/to/file.txt.")
        }
        instructions = resolved
    }
    let verbose = ProcessInfo.processInfo.environment["VOICECHAT_VERBOSE"] == "1"

    let boot = BootProgress()
    let renderer = TerminalProgressRenderer(progress: boot)
    renderer.attach()

    // Auto-download Expression weights when no `.imx` was supplied.
    // Same `ExpressionWeights.ensureAvailable` flow the local Expression
    // runner uses, so cache hits are byte-identical and reusable across
    // local / cloud sessions.
    let weightsURL: URL
    if let modelPath {
        weightsURL = modelPath
    } else {
        weightsURL = try await ExpressionWeights.ensureAvailable(
            progress: { phase in
                switch phase {
                case .verifying:
                    boot.update(.verifyingEngine)
                case .downloading(_, let received, let total, let bps, let eta):
                    boot.update(.downloadingEngine(
                        received: received, total: total,
                        bytesPerSecond: bps, etaSeconds: eta
                    ))
                case .verifyingDownloaded:
                    boot.update(.verifyingEngine)
                case .ready:
                    break
                }
            },
            silenceStderr: true
        )
    }

    // Resolve the portrait identity. With `--identity <image>` /
    // `--image <path>` we use that face; otherwise the bundled
    // Diego portrait — but persona text + voice come from the
    // unified default persona (Einstein) so all modes
    // (text/voice/avatar) read with one consistent voice.
    let defaultAgent = AgentCatalog.defaultAgent
    if instructions == nil {
        instructions = DefaultEssenceAgent.systemPrompt
    }
    let portraitURL = resolvePortrait(args.imageArg)
        ?? AgentCatalog.thumbnailURL(for: defaultAgent)
    let identity: Bithuman.Identity = portraitURL.map { .image($0) } ?? .default

    // Construct the engine. ~5–10 s on Apple Silicon for the ANE shader
    // compile + weight quantize on a warm cache (longer first run).
    boot.update(.loadingExpressionEngine)
    let createResult = try await Task.detached(priority: .userInitiated) {
        try Bithuman.create(modelPath: weightsURL, identity: identity)
    }.value
    let bithuman = createResult.bithuman

    // bitHuman billing heartbeat — tags this session against the
    // user's ImagineX account at 2 credits/min for Expression.
    // Without `BITHUMAN_API_KEY` we run unmetered (development);
    // print a one-time hint so the user knows about the dashboard.
    let bithumanHeartbeat = makeBithumanHeartbeat(
        billingType: BithumanAuthConfig.selfHostedExpressionModel,
        tags: "bithuman-cli/avatar/expression"
    )
    if let hb = bithumanHeartbeat {
        do { try await hb.authenticate(); await hb.resume() }
        catch {
            FileHandle.standardError.write(Data(
                "‼ bitHuman billing heartbeat failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    // Construct the FramePump + window NOW, but keep the window
    // hidden until idle-prewarm completes. In cloud mode, the WebRTC
    // bot-audio tap pushes a continuous stream of `pendingAudio` into
    // the engine, which keeps `bithuman.snapshot.pendingAudio16Count`
    // non-zero and starves the producer's idle-generation path.
    // Result: the visual splash sits stuck at whatever fill % the
    // cache had when the first audio chunk arrived (the user saw
    // "warming up — 13%" forever). The fix is to fill the cache
    // BEFORE WebRTC connects so no audio is competing for engine
    // dispatches.
    let coordinator = AvatarCoordinator()
    let window = AvatarWindow(idleFrame: createResult.staticIdleImage, coordinator: coordinator)

    // UI created up front so the speaker callback below can capture
    // it. Actual `await ui.start()` is deferred until after the
    // boot block clears (so the sticky-area renders don't fight the
    // multi-step progress block); calls before `start()` are
    // harmless no-ops since the render task hasn't been spun up.
    let ui = TerminalUI()

    // Apple-stack chunk-paired playback (the version that had A/V
    // sync). LiveKit's AudioEngine ADM creates an internal
    // AVAudioEngine; AudioEngineADMSpeaker hooks `didCreateEngine`
    // to attach an AVAudioPlayerNode + gainMixer to that engine,
    // enables Apple VP-IO on input/output for AEC, and rewires
    // the engine output so libwebrtc's auto-route is silenced
    // (outputVolume=0) while our player feeds the speaker. AEC
    // operates on the same engine our player drives — VP-IO
    // subtracts our chunk audio from the mic capture.
    let speaker = AudioEngineADMSpeaker(verbose: verbose, onPlay: { @Sendable [ui] rms in
        Task { await ui.setBotLevel(rms) }
    })
    let pump = FramePump(
        bithuman: bithuman,
        window: window,
        coordinator: coordinator,
        playSpeechAudio: { @Sendable [speaker] samples in
            speaker.play(samples24k: samples)
        }
    )
    coordinator.framePump = pump
    if let delegate = NSApp.delegate as? BithumanAppDelegate {
        delegate.avatarWindow = window
        delegate.retainSession(chat: bithuman, pump: pump)
    }

    // Try to load a previously-persisted idle palindrome from disk
    // before generating fresh frames. Same identity = same baseline
    // motion, so the cached frames are byte-for-byte equivalent to
    // what we'd regenerate. ~5–10 s saved on every cold start
    // after the first.
    let identityKey = IdleFrameDiskCache.identityKey(
        weightsURL: weightsURL,
        portraitURL: portraitURL
    )
    var seededFromDisk = false
    if let cached = IdleFrameDiskCache.load(identityKey: identityKey) {
        pump.seedIdleCache(frames: cached)
        seededFromDisk = true
        if verbose {
            FileHandle.standardError.write(Data(
                "↦ idle frames seeded from disk (\(cached.count) frames, key=\(identityKey))\n".utf8
            ))
        }
    }

    // Pre-warm the idle palindrome cache. With no audio flowing,
    // the producer hits the `generateIdleChunk` path on every loop
    // and the cache fills in ~5–10 s on M-series. Cap the wait at
    // 60 s so a misbehaving engine can't deadlock the boot.
    // Skips entirely when the disk cache hit above, since
    // `idlePrewarmReady` is already true.
    boot.update(.prewarmingIdle(progress: 0))
    let prewarmStart = Date()
    while !coordinator.idlePrewarmReady,
          Date().timeIntervalSince(prewarmStart) < 60 {
        boot.update(.prewarmingIdle(progress: coordinator.idlePrewarmProgress))
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // Persist freshly-generated frames so subsequent launches with
    // this identity skip prewarm. Background-priority — don't block
    // the WebRTC connect on disk I/O.
    if !seededFromDisk, coordinator.idlePrewarmReady {
        let snapshot = pump.snapshotIdleCache()
        Task.detached(priority: .background) {
            IdleFrameDiskCache.save(snapshot, identityKey: identityKey)
        }
    }

    // Cache is full (or we hit the safety cap) — now show the window.
    // The renderer's CALayer is already up-to-date because the
    // FramePump's consumer timer has been ticking the latest idle
    // frame into it the whole time, so the user sees a fully
    // animated avatar the moment the window pops up.
    window.setFrameOrigin(centeredOrigin(forSize: window.frame.size))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    // `ui` was constructed earlier (so the speaker callback could
    // capture it); start the render task now that the boot block
    // has cleared.
    await ui.start()
    // Per-minute spend reporter — Expression is metered at 2
    // credits/min; the tracker's 60 s tick prints accrued cost
    // for both bitHuman and OpenAI to the scrolling area.
    let spendTracker = SpendTracker(
        runtime: .expression,
        ui: ui,
        openAIModel: args.openAIModel
    )
    await spendTracker.start()
    let voiceKnown = ["alloy", "ash", "ballad", "coral", "echo",
                      "sage", "shimmer", "verse", "marin", "cedar"]
        .contains(voice.lowercased())

    // Bot-PCM tap: every buffer libwebrtc plays through the speaker
    // is also delivered here. Resample 48 kHz Float → 24 kHz Float
    // and 16 kHz Float (Bithuman wants both for lipsync). Pushed
    // into the engine asynchronously; FramePump's producer dequeues
    // the resulting `TimedChunk`s and renders them.
    let conv24Box = ConverterBox()
    let conv16Box = ConverterBox()
    let fmt24 = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!
    let fmt16 = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    // Flag set true when the bot is actively responding (between
    // `response.created` and `response.done`/`cancelled`). When
    // false, `onBotPCM` skips the `bithuman.pushAudio` call —
    // OpenAI's WebRTC track sends silence padding during user
    // listening/hearing/thinking, and feeding that into the
    // engine causes it to dispatch DiT chunks for silence,
    // burning GPU on lipsync frames the user never sees.
    let botActiveBox = AtomicBool(initial: false)

    let pcmDiagBox = AtomicCounter()
    let onBotPCM: @Sendable (AVAudioPCMBuffer) -> Void = { [bithuman, ui, pcmDiagBox, verbose] buffer in
        let inFrames = Int(buffer.frameLength)
        guard inFrames > 0 else { return }
        pcmDiagBox.bump(inFrames)
        if verbose, pcmDiagBox.shouldReport() {
            FileHandle.standardError.write(Data(
                "→ onBotPCM fired \(pcmDiagBox.calls) times, \(pcmDiagBox.totalFrames) frames @ \(buffer.format.sampleRate)Hz · src=Bithuman feed\n".utf8
            ))
        }

        func resample(_ src: AVAudioPCMBuffer, to target: AVAudioFormat, conv: AVAudioConverter) -> [Float]? {
            let outCap = AVAudioFrameCount(Double(src.frameLength) * target.sampleRate / src.format.sampleRate + 16)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return nil }
            var delivered = false
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, statusOut in
                if delivered { statusOut.pointee = .noDataNow; return nil }
                delivered = true
                statusOut.pointee = .haveData
                return src
            }
            guard status != .error, let p = out.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        }

        guard let conv24 = conv24Box.converter(for: buffer.format, target: fmt24),
              let conv16 = conv16Box.converter(for: buffer.format, target: fmt16),
              let s24 = resample(buffer, to: fmt24, conv: conv24),
              let s16 = resample(buffer, to: fmt16, conv: conv16)
        else { return }

        // Hz sanity check: expected ratios are exactly src→24k and
        // src→16k. If output is off by more than 1 sample per
        // chunk, the resampler is dropping/adding samples and
        // would cause cumulative A/V drift. Gated behind
        // `BITHUMAN_DEBUG_AUDIO=1` so default verbose runs stay
        // readable.
        let audioDebug = ProcessInfo.processInfo.environment["BITHUMAN_DEBUG_AUDIO"] == "1"
        if audioDebug, pcmDiagBox.shouldReport() {
            let srcRate = buffer.format.sampleRate
            let exp24 = Int(Double(inFrames) * 24_000.0 / srcRate)
            let exp16 = Int(Double(inFrames) * 16_000.0 / srcRate)
            FileHandle.standardError.write(Data(
                "→ resample: \(inFrames)@\(Int(srcRate)) → 24k: got \(s24.count) (exp \(exp24), Δ\(s24.count - exp24)) · 16k: got \(s16.count) (exp \(exp16), Δ\(s16.count - exp16))\n".utf8
            ))
        }

        // RMS for the bot meter. Now that libwebrtc plays the
        // bot's audio at realtime (its native auto-playback), the
        // arrival timing IS the playback timing — bar moves when
        // user hears audio.
        var sum: Double = 0
        var c = 0
        var i = 0
        while i < s16.count { let v = Double(s16[i]); sum += v * v; c += 1; i += 8 }
        let rms: Float = c > 0 ? Float((sum / Double(c)).squareRoot()) : 0
        Task {
            try? await bithuman.pushAudio(audio24k: s24, audio16k: s16)
            await ui.setBotLevel(rms)
        }
    }

    // Barge-in: when the user starts talking, immediately flush
    // every local pipeline so the bot's in-flight reply stops
    // dead instead of finishing over the user's voice.
    //
    //   1. Speaker queue — drop any scheduled audio buffers
    //      (`stopPlayback` then re-`play()` to re-arm).
    //   2. Frame buffer — drop queued speech frames so the avatar
    //      stops mouthing the cancelled reply within one display
    //      tick (~40 ms).
    //   3. Bithuman engine — `flush()` clears pendingAudio16/24
    //      and resets the streaming-pipeline counters so the next
    //      bot reply starts a fresh chunk window.
    let onUserSpeechStarted: @Sendable () async -> Void = { @Sendable [pump, bithuman, speaker] in
        // Barge-in: cut speaker, drop frames, snap to idle, flush
        // engine. Server cancel happens in the receive loop right
        // after this callback returns.
        speaker.stopPlayback()
        pump.buffer.flushSpeech()
        pump.snapToIdleNow()
        await bithuman.flush()
    }

    boot.update(.connectingRealtime)
    let client = RealtimeWebRTCClient(
        apiKey: apiKey,
        model: args.openAIModel,
        voice: voice,
        instructions: instructions,
        ui: ui,
        verbose: verbose,
        onBotPCM: onBotPCM,
        admSpeaker: speaker,
        onUserSpeechStarted: onUserSpeechStarted,
        onBotResponseActiveChange: { @Sendable [botActiveBox] active in
            botActiveBox.value = active
        }
    )
    try await client.connect()

    boot.update(.ready)
    renderer.detach()
    await ui.printOpeningBanner(
        model: args.openAIModel,
        voice: voice,
        verbose: verbose,
        keyValidated: true,
        voiceKnown: voiceKnown
    )

    Task { try? await client.runReceiveLoop() }

    let forever = AsyncStream<Void> { _ in }
    for await _ in forever { break }
    _ = (client, bithuman, pump, window, ui, speaker, bithumanHeartbeat, spendTracker)
}

/// Tiny atomic counter for reporting renderer / speaker activity
/// every ~1 s in verbose mode without spamming stderr per-buffer.
/// Tiny lock-protected boolean shared between the WebRTC receive
/// loop (writer, on the actor) and the renderer audio callback
/// (reader, on libwebrtc's audio render thread). Used to gate
/// `bithuman.pushAudio` on whether the bot is actively speaking,
/// so silence-padding RTP frames during user listening/hearing
/// don't burn GPU on DiT dispatches.
final class AtomicBool: @unchecked Sendable {
    private let q = DispatchQueue(label: "ai.bithuman.cli.atomicbool")
    private var _value: Bool
    init(initial: Bool) { self._value = initial }
    var value: Bool {
        get { q.sync { _value } }
        set { q.sync { _value = newValue } }
    }
}

final class AtomicCounter: @unchecked Sendable {
    private let q = DispatchQueue(label: "ai.bithuman.cli.diag")
    private(set) var calls: Int = 0
    private(set) var totalFrames: Int = 0
    private var lastReport: Date = Date(timeIntervalSince1970: 0)
    func bump(_ frames: Int) {
        q.sync { calls += 1; totalFrames += frames }
    }
    func shouldReport() -> Bool {
        q.sync {
            let now = Date()
            if now.timeIntervalSince(lastReport) > 1.0 {
                lastReport = now
                return true
            }
            return false
        }
    }
}

/// Avatar (lipsync) stays local in `EssenceRuntime`; LLM/ASR/TTS
/// all happen server-side. Audio I/O is handled by `AudioGraph`
/// (Apple VP-IO for AEC) so laptop speakers + mic work without echo.
///
/// Pipeline:
///   mic → AudioGraph (VP-IO AEC) → 16/24 kHz PCM → WebSocket
///   ↑ server transcribes + responds
///   ↓ response.audio.delta (24 kHz PCM16)
///   → AudioGraph speaker (with VP-IO reference)
///   → resample to 16 kHz Int16 → EssenceRuntime.pushAudio
///   → EssenceRuntime emits frames → AvatarWindow
///
/// Skips the entire `VoiceChat` orchestrator since we don't need
/// local LLM/ASR/TTS; saves ~5 GB of model downloads on first run.
@MainActor
private func runEssenceVideoSessionOpenAI(args: CLIArgs, modelPath: URL) async throws {
    guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
          !apiKey.isEmpty
    else {
        fatalKey()
    }

    let voice: String
    if let raw = args.voiceArg, !raw.contains("/"), !raw.contains(".") {
        voice = raw
    } else {
        voice = "ash"
    }
    var instructions: String? = nil
    if let raw = args.promptArg {
        guard let resolved = readInlineOrFile(raw) else {
            fatalUsage("--prompt: couldn't read '\(raw)'. Pass inline text or @path/to/file.txt.")
        }
        instructions = resolved
    }

    // Reuse the same TerminalUI as `voice --openai` so users see a
    // live mic bar + bot bar + status pill + per-utterance histograms.
    // We still drive the multi-step boot block before the UI takes
    // over the sticky area, so the cold-start window stays informative.
    let verbose = ProcessInfo.processInfo.environment["VOICECHAT_VERBOSE"] == "1"
    let boot = BootProgress()
    let renderer = TerminalProgressRenderer(progress: boot)
    renderer.attach()

    boot.update(.loadingEssenceRuntime)
    // Async create authenticates with the bitHuman billing service
    // before returning the runtime. Throws BithumanCreateError.missingAPIKey
    // when no key is resolvable; throws .authenticationFailed for
    // expired / suspended / over-balance accounts. We catch + reframe
    // as a fatalUsage with a one-line setup pointer so users see a
    // clean error rather than a stack trace.
    let runtime: EssenceRuntime
    do {
        runtime = try await EssenceRuntime.create(modelPath: modelPath, apiSecret: BithumanKey.load())
    } catch BithumanCreateError.missingAPIKey {
        fatalBitHumanKeyMissing()
    } catch BithumanCreateError.authenticationFailed(let underlying) {
        fatalBitHumanAuthFailed(underlying)
    }
    let resolution = runtime.resolution
    let size = CGSize(width: resolution.width, height: resolution.height)

    boot.update(.openingAudioGraph)
    let graph = AudioGraph()
    try await graph.start()

    boot.update(.connectingRealtime)
    let client = RealtimeWebSocketClient(
        apiKey: apiKey,
        model: args.openAIModel,
        voice: voice,
        instructions: instructions,
        verbose: verbose
    )
    try await client.connect()

    boot.update(.ready)
    renderer.detach()

    // Hand the terminal off to the live UI.
    let ui = TerminalUI()
    await ui.start()
    let voiceKnown = ["alloy", "ash", "ballad", "coral", "echo",
                      "sage", "shimmer", "verse", "marin", "cedar"]
        .contains(voice.lowercased())
    await ui.printOpeningBanner(
        model: args.openAIModel,
        voice: voice,
        verbose: verbose,
        keyValidated: true,  // boot already exchanged session.update successfully
        voiceKnown: voiceKnown
    )
    await ui.setState(.listening)

    // Mic pump: tap the AudioGraph's micBuffers stream, downsample
    // each chunk to 24 kHz PCM16, and forward to the WS. AudioGraph's
    // tap is at the input node's hardware format (typically 48 kHz
    // mono Float32) with VP-IO already applied — clean signal for
    // the server's whisper.
    let realtimeFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!
    Task.detached(priority: .userInitiated) { [graph, client, realtimeFormat] in
        var converter: AVAudioConverter?
        var srcRate: Double = 0
        for await buffer in graph.micBuffers {
            if converter == nil || srcRate != buffer.format.sampleRate {
                converter = AVAudioConverter(from: buffer.format, to: realtimeFormat)
                srcRate = buffer.format.sampleRate
            }
            guard let conv = converter else { continue }
            let ratio = realtimeFormat.sampleRate / buffer.format.sampleRate
            let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
            guard let out = AVAudioPCMBuffer(pcmFormat: realtimeFormat, frameCapacity: outCap) else { continue }
            var delivered = false
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, statusOut in
                if delivered { statusOut.pointee = .noDataNow; return nil }
                delivered = true
                statusOut.pointee = .haveData
                return buffer
            }
            if status == .error || out.frameLength == 0 { continue }
            guard let int16Ptr = out.int16ChannelData?[0] else { continue }
            let data = Data(bytes: int16Ptr, count: Int(out.frameLength) * 2)
            await client.appendAudio(data)
        }
    }

    // Pump AudioGraph's mic-energy stream into the UI's mic level
    // bar AND drive a simple client-side VAD that triggers
    // `commit + response.create` when the user stops talking. We
    // don't trust server-side VAD here — empirically the WS
    // transport sees our PCM but never fires `speech_started`, so
    // the only way to get a reply is to commit manually.
    Task.detached(priority: .userInitiated) { [graph, ui, client] in
        let speakThreshold: Float = 0.025      // RMS above this counts as voice
        let silenceMs: Int = 600                // ms of quiet that ends a turn
        let minSpeechMs: Int = 200              // ignore very short blips
        var inSpeech = false
        var speechStart = Date()
        var lastVoice = Date()
        for await rms in graph.micEnergy {
            await ui.setMicLevel(rms)
            let now = Date()
            if rms > speakThreshold {
                if !inSpeech {
                    inSpeech = true
                    speechStart = now
                    await ui.setState(.hearing)
                    await ui.userSpeechStarted()
                }
                lastVoice = now
            } else if inSpeech {
                let quietFor = Int(now.timeIntervalSince(lastVoice) * 1000)
                let speechDur = Int(lastVoice.timeIntervalSince(speechStart) * 1000)
                if quietFor >= silenceMs, speechDur >= minSpeechMs {
                    inSpeech = false
                    await ui.setState(.thinking)
                    await client.commitAndRespond()
                } else if quietFor >= silenceMs {
                    inSpeech = false  // too short, abandon turn
                    await ui.setState(.listening)
                }
            }
        }
    }

    // Open avatar window centred on screen.
    let window = AvatarWindow(targetSize: size, clipMode: .fill)
    window.setFrameOrigin(centeredOrigin(forSize: window.frame.size))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    let session = EssenceVoiceChatSession(runtime: runtime, sink: window)
    session.startConsuming()

    // Bot-event router: drives the live UI (mic / bot bars, status
    // pill, transcript timeline) AND fans bot audio out to the
    // speaker (AEC reference) + EssenceRuntime (lipsync).
    Task { [graph, runtime, ui] in
        let serverFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
        let lipsyncFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let lipsyncConverter = AVAudioConverter(from: serverFormat, to: lipsyncFormat)

        for await event in await client.events {
            switch event {
            case .sessionReady:
                await ui.setState(.listening)
            case .userSpeechStarted:
                await ui.setState(.hearing)
                await ui.userSpeechStarted()
            case .userSpeechStopped:
                await ui.setState(.thinking)
            case .userTranscript(let text):
                await ui.commitUserTranscript(text)
            case .botResponseStarted:
                await ui.setState(.responding)
                await ui.botResponseStarted()
            case .botTranscriptDelta(let delta):
                await ui.appendBotChunk(delta)
            case .botResponseEnded:
                await ui.endBotResponse()
                await ui.setState(.listening)
            case .botResponseCancelled:
                await ui.cancelledBotResponse()
                await ui.setState(.listening)
            case .error(let msg):
                await ui.errorLine("error: \(msg)")
            case .botAudio(let bytes):
                let frameCount = AVAudioFrameCount(bytes.count / 2)
                guard frameCount > 0,
                      let inBuf = AVAudioPCMBuffer(pcmFormat: serverFormat, frameCapacity: frameCount)
                else { continue }
                inBuf.frameLength = frameCount
                var rms: Float = 0
                if let dst = inBuf.int16ChannelData?[0] {
                    bytes.withUnsafeBytes { src in
                        guard let base = src.baseAddress else { return }
                        dst.update(from: base.assumingMemoryBound(to: Int16.self), count: Int(frameCount))
                    }
                    // Cheap RMS for the bot bar — sample every 8th
                    // value so a 1 s 24 kHz chunk costs ~3000 muls.
                    let n = Int(frameCount)
                    var sumSq: Double = 0
                    var count = 0
                    var i = 0
                    while i < n {
                        let s = Double(dst[i]) / 32768.0
                        sumSq += s * s
                        count += 1
                        i += 8
                    }
                    rms = count > 0 ? Float((sumSq / Double(count)).squareRoot()) : 0
                }
                await ui.setBotLevel(rms)

                // 1. Speaker — VP-IO sees this as the reference signal.
                await graph.schedulePlayback(inBuf)

                // 2. Lipsync — push 16 kHz Int16 into Essence.
                if let conv = lipsyncConverter {
                    let outCap = AVAudioFrameCount(Double(frameCount) * 16_000.0 / 24_000.0 + 16)
                    if let outBuf = AVAudioPCMBuffer(pcmFormat: lipsyncFormat, frameCapacity: outCap) {
                        var delivered = false
                        var err: NSError?
                        let status = conv.convert(to: outBuf, error: &err) { _, statusOut in
                            if delivered { statusOut.pointee = .noDataNow; return nil }
                            delivered = true
                            statusOut.pointee = .haveData
                            return inBuf
                        }
                        if (status == .haveData || status == .endOfStream),
                           let i16Ptr = outBuf.int16ChannelData?[0] {
                            let n = Int(outBuf.frameLength)
                            let samples = Array(UnsafeBufferPointer(start: i16Ptr, count: n))
                            await runtime.pushAudio(samples)
                        }
                    }
                }
            }
        }
    }

    // Park forever — Ctrl-C or ⌘Q tears the process down.
    let forever = AsyncStream<Void> { _ in }
    for await _ in forever { break }
    _ = (graph, client, runtime, session, window)
}

/// Original Expression-only video code path, preserved verbatim from
/// commit 12 except for the `modelPath` parameter (nil = use bundled
/// weights, non-nil = use the user-supplied `.imx`). Behaviour for
/// `bithuman-cli video` with no `--model` flag is byte-for-byte
/// identical to the previous release.
@MainActor
private func runExpressionVideoSession(args: CLIArgs, modelPath: URL? = nil) async throws {
    // Unified boot UI: a graphical splash window so the user sees a
    // progress bar from the very first second, plus a terminal
    // renderer so anyone who launched from a shell still gets the
    // status in their console. Both subscribe to the same
    // ``BootProgress`` instance.
    let boot = BootProgress()
    let renderer = TerminalProgressRenderer(progress: boot)
    renderer.attach()

    // Terminal-only progress for the Expression video path too — the
    // graphical splash has been retired in favour of the multi-line
    // TerminalProgressRenderer block. Avatar window appears at the
    // end (see below) without a teleport since we centre it.

    let weightsURL: URL
    if let modelPath {
        weightsURL = modelPath
    } else {
        // Forward DownloadPhase events into BootProgress so the same
        // renderer used by voice mode shows engine bytes / rate / ETA.
        // `silenceStderr: true` suppresses the legacy `📥 N%` lines
        // since the renderer already paints its own bar.
        weightsURL = try await ExpressionWeights.ensureAvailable(
            progress: { phase in
                switch phase {
                case .verifying:
                    boot.update(.verifyingEngine)
                case .downloading(_, let received, let total, let bps, let eta):
                    boot.update(.downloadingEngine(
                        received: received, total: total,
                        bytesPerSecond: bps, etaSeconds: eta
                    ))
                case .verifyingDownloaded:
                    boot.update(.verifyingEngine)
                case .ready:
                    break  // next phase is set by VoiceChat.start()
                }
            },
            silenceStderr: true
        )
    }
    // Fresh-user default: default persona (Einstein) (prompt + Kokoro voice)
    // applied over Diego's bundled portrait when no `--image` is
    // supplied. The same persona is shared across text / voice /
    // avatar modes so the CLI's no-flag UX feels coherent. CLI flags
    // override pieces individually (--prompt, --voice, --image).
    let defaultAgent = AgentCatalog.defaultAgent
    let portraitURL = resolvePortrait(args.imageArg)
        ?? AgentCatalog.thumbnailURL(for: defaultAgent)
    let initialPrompt = args.promptArg ?? DefaultEssenceAgent.systemPrompt

    // Resolve the Kokoro preset for video mode. parseArgs has already
    // validated args.voiceArg against the Kokoro list (rejecting paths
    // and Qwen3 names); here we just canonicalise case and fall back
    // to the default-persona Kokoro voice if --voice wasn't
    // supplied. We intentionally do NOT call resolveVoice() — that's
    // Qwen3-shaped and config.voice is ignored when avatar is configured.
    let voicePreset: String = args.voiceArg
        .flatMap { raw in
            VoiceChat.availableAvatarVoices.first { $0.lowercased() == raw.lowercased() }
        }
        ?? DefaultEssenceAgent.kokoroVoice

    var config = makeConfig(args)
    config.avatar = AvatarConfig(modelPath: weightsURL, portraitPath: portraitURL)
    config.systemPrompt = initialPrompt
    config.bootProgress = boot

    let chat = VoiceChat(config: config)
    try await chat.start()
    boot.update(.ready)
    renderer.detach()

    guard let bh = chat.bithuman else {
        fatalUsage("avatar engine failed to initialise — see preceding errors.")
    }
    _ = bh.frameSize  // unused for now; window size is fixed

    // Pin the Kokoro voice (the player boots with `af_heart`; the
    // chosen preset is either --voice or the default agent's voice).
    await chat.setVoicePreset(voicePreset)

    let coordinator = AvatarCoordinator(chat: chat)
    coordinator.bindToOrchestrator()
    coordinator.currentSystemPrompt = initialPrompt
    coordinator.currentVoicePreset = voicePreset
    // Highlight the default agent's card on first open of the picker.
    // If the user supplied any per-flag override, they've drifted off
    // the template, so we leave the highlight clear.
    if args.imageArg == nil && args.promptArg == nil && args.voiceArg == nil {
        coordinator.currentAgentCode = defaultAgent.code
    }
    coordinator.prewarmPortraitURL = portraitURL
    let window = AvatarWindow(idleFrame: chat.initialIdleFrame, coordinator: coordinator)
    // Open centred on the active screen — the splash window used to
    // pre-anchor the position; with no splash we just compute it.
    window.setFrameOrigin(centeredOrigin(forSize: window.frame.size))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    let pump = FramePump(bithuman: bh, chat: chat, window: window, coordinator: coordinator)
    coordinator.framePump = pump
    // Flush the FramePump's frame buffer on barge-in so the avatar
    // doesn't keep mouthing the cancelled reply for a few seconds.
    chat.onBargeIn = { [weak pump] in
        pump?.buffer.flushSpeech()
    }
    // Expose buffer state to VoiceChat's drain poller — the
    // pipeline isn't quiet until our consumer-side speech queue is
    // empty too.
    chat.onCheckSpeechBuffer = { [weak pump] in
        pump?.buffer.hasSpeech == false
    }

    // Park the chat + pump on the AppDelegate so they outlive this
    // function — without an explicit retain they'd be released and
    // the avatar would freeze.
    if let delegate = NSApp.delegate as? BithumanAppDelegate {
        delegate.avatarWindow = window
        delegate.retainSession(chat: chat, pump: pump)
    }

    // Background stdin reader — lets the user TYPE a message in
    // the launching terminal in addition to (or instead of) speaking.
    // Each non-empty line is fed into the orchestrator's same turn
    // flow as an ASR final, so the bot replies the same way it
    // would for a spoken utterance.
    Task.detached(priority: .background) { [chat] in
        while !Task.isCancelled, let line = readLine() {
            await chat.inject(userText: line)
        }
    }

    print("🎥 floating avatar window ready. Talk or type any time. Ctrl-C or ⌘Q to quit.")
}

/// Synchronous video-mode entry. Calls `NSApp.run()` directly from a
/// non-async stack frame — the only context where AppKit's runloop
/// will actually drive the main dispatch queue our render loop
/// depends on.
/// `bithuman-cli text --openai` entry point. Mirrors the voice
/// auto-pick: when `OPENAI_API_KEY` is available (env or key file)
/// and the user didn't pass `--local`, run text chat through
/// OpenAI's Chat Completions API instead of the on-device Gemma —
/// no model downloads, snappier first reply.

private func centeredOrigin(forSize size: CGSize) -> NSPoint {
    let screen = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    return NSPoint(
        x: screen.midX - size.width / 2,
        y: screen.midY - size.height / 2
    )
}

// MARK: - Utility modes (cleanup, doctor)

/// `bithuman-cli cleanup` — wipe model caches so the next run
/// exercises the cold-start path. Lists what's there + total size,
/// asks for confirmation, then deletes. Idempotent.
///
/// Caches we own:
///   - `~/.cache/huggingface/hub`   — every MLX/HF weight (LLM, TTS,
///                                    speech, Qwen3, Kokoro, etc.)
///   - `~/.cache/bithuman`          — Expression engine weights,
///                                    Apple SpeechAnalyzer model
///                                    cache, Essence working dirs.
///
/// Things we deliberately DON'T touch:
///   - `~/.bithuman/embedded-key`   — maintainer's bundled API key
///                                    (release pipeline uses this).
///   - The macOS Keychain entry     — removable separately with
///                                    `security delete-generic-password
///                                    -s ai.bithuman.cli`.

func videoHardwareHint(args: CLIArgs) -> String? {
    // Only hint when running the default Expression path. If the
    // user supplied their own --model, they've already chosen.
    guard args.modelArg == nil else { return nil }
    guard let gen = appleSiliconGeneration() else { return nil }
    if gen >= 4 { return nil }  // M4+ runs Expression smoothly
    return """
        💡 \u{1B}[2mhardware hint:\u{1B}[0m Apple M\(gen) detected. The default Expression
           avatar pipeline is best on M4+. For smoother playback on this
           hardware, point at an Essence .imx via `--model <path>` —
           Essence is lighter and runs comfortably back to M1.
        """
}

@MainActor
func bootstrapVideo(_ args: CLIArgs) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = BithumanAppDelegate(onLaunch: {
        try await runVideoSession(args: args)
    })
    app.delegate = delegate
    installMainMenu()

    // Bridge Ctrl-C in the terminal to a clean app terminate so the
    // audio engine + Bithuman shutdown actually run.
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { NSApp.terminate(nil) }
    signal(SIGINT, SIG_IGN)
    sigint.resume()

    app.run()  // never returns
    exit(0)
}

// MARK: - Entrypoint
//
// Sync top-level. Async work for text / voice runs inside a Task,
// with `dispatchMain()` parking the main thread so that Task can be
// scheduled on the main dispatch queue. Video bypasses this
// entirely — it calls `NSApp.run()` synchronously, which provides
// its own main-queue service.

