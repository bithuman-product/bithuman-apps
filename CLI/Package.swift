// swift-tools-version: 6.0
import PackageDescription

// bitHumanKit — on-device voice + video chat SDK for Apple Silicon, by bitHuman.
// https://www.bithuman.ai
//
// Two products:
//   - `bitHumanKit`    Swift library; embed in your own app (macOS / iPadOS / iOS).
//   - `bithuman-cli`   standalone macOS CLI built on top of the library.
//
// Module name is `bitHumanKit` (lowercase 'b' to match the bitHuman brand).
// CLI internal target is `BithumanCLI` (CamelCase, since Swift target names
// can't contain hyphens); the executable PRODUCT is `bithuman-cli`, which is
// what users type and what Homebrew installs.
//
// Stack:
//   ASR    Apple SpeechAnalyzer + SpeechTranscriber (built into macOS 26)
//   LLM    Gemma 4 E2B 4-bit via mlx-swift-lm
//   TTS    Qwen3-TTS 0.6B 4-bit (voice mode, cloning) +
//          Kokoro 82M 4-bit (video mode, preset)
//   AEC    hardware via AVAudioEngine voice-processing IO unit (macOS only)
//   AVATAR bitHuman expression engine (Wav2Vec2 → DiT → VAE → ANE)

let package = Package(
    name: "bithuman-kit",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        // Library (kept so other tooling in `bithuman-apps` can
        // import the embedded SDK source if needed) and the CLI
        // exec, which is what `brew install bithuman-cli` ships.
        .library(name: "bitHumanKit", targets: ["bitHumanKit"]),
        .executable(name: "bithuman-cli", targets: ["BithumanCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        // MLXAudio* targets below are vendored from
        // Blaizzy/mlx-audio-swift @ 020b7529 (post-v0.1.2 — Kokoro +
        // Qwen3-TTS reference conditioning landed). MIT, see
        // THIRD_PARTY_LICENSES/MLXAudio-LICENSE. Vendored to remove
        // the SPM stable-tag/transitive-revision conflict that
        // previously required maintaining a tag-mirror fork.
        // libwebrtc binary xcframework — used only by the
        // `BithumanRealtimeOpenAI` target which powers
        // `bithuman-cli voice --openai` AND the new
        // `bithuman-cli video --openai` lipsync path. We use
        // **LiveKit's WebRTC fork** rather than stasel/WebRTC: it
        // ships proper macOS headers AND adds an `RTCAudioRenderer`
        // protocol on top of upstream Google libwebrtc, which lets us
        // tap the bot audio track for `EssenceRuntime.pushAudio` to
        // drive lipsync. Stasel's stripped Google build doesn't
        // expose this, so video mode would otherwise have to fall
        // back to the WebSocket transport — which empirically the
        // server won't VAD over PCM-base64 (voice mode works because
        // it uses an Opus RTP track, never WS audio).
        .package(url: "https://github.com/livekit/webrtc-xcframework", exact: "144.7559.04"),
    ],
    targets: [
        // C target: hand-NEON int8 GEMM + per-channel requantize for
        // the Essence audio encoder. Apple Silicon arm64; falls back
        // to scalar on non-arm64 CI hosts. Consumed by the Swift
        // `Int8Forward` kernel via the `BitHumanInt8Conv` module.
        .target(
            name: "BitHumanInt8Conv",
            path: "Sources/BitHumanInt8Conv",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-O3", "-fvectorize", "-fslp-vectorize"],
                             .when(configuration: .release)),
            ]
        ),
        .target(
            name: "bitHumanKit",
            dependencies: [
                // LLM stack
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                // TTS stack — vendored, see MLXAudio* targets below.
                "MLXAudioCore",
                "MLXAudioTTS",
                // Avatar engine — direct mlx-swift products. These also flow in
                // transitively via the LLM/TTS deps; declaring explicitly so
                // SPM's resolution is pinned and the engine's `import MLX` etc.
                // compile cleanly.
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                // Hand-NEON int8 GEMM kernel (this repo's C target).
                "BitHumanInt8Conv",
            ],
            path: "Sources/bitHumanKit",
            // ref.wav + ref.txt: the cloned voice's reference audio
            // and matching transcript. Loaded at runtime via
            // Bundle.module, fed to Qwen3-TTS as refAudio/refText so
            // the speaker embedding is locked across runs.
            resources: [.process("Resources")],
            // Swift 5 mode because AVAudioPCMBuffer isn't Sendable yet
            // and Apple's audio frameworks predate strict concurrency.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // OpenAI realtime backend — `bithuman-cli voice --openai`
        // routes here. WebRTC peer connection to OpenAI's realtime
        // endpoint, libwebrtc-managed audio I/O (so AEC + NS + AGC
        // are handled by the same library Chrome uses for
        // `getUserMedia`). Stays a separate target from `bitHumanKit`
        // so the 100 MB libwebrtc binary doesn't bloat the SDK
        // library that's exposed via `import bitHumanKit`.
        .target(
            name: "BithumanRealtimeOpenAI",
            dependencies: [
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
            ],
            path: "Sources/BithumanRealtimeOpenAI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BithumanCLI",
            dependencies: [
                "bitHumanKit",
                "BithumanRealtimeOpenAI",
            ],
            path: "Sources/BithumanCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // (Apps + Examples + Tests + MLXMetallibBuilder targets
        // were stripped during the move from `bithuman-kit` to
        // `bithuman-apps/CLI/`. The reference Mac / iPad / iPhone
        // apps live at the bithuman-apps top-level; bench harnesses
        // and tests stay in the SDK monorepo. CLI/ keeps only the
        // targets the binary release pipeline needs.)

        // MARK: - Vendored MLXAudio targets
        //
        // Mirror of Blaizzy/mlx-audio-swift @ 020b7529 (post-v0.1.2).
        // Target definitions track upstream's Package.swift; only
        // MLXAudioCore + MLXAudioCodecs + MLXAudioG2P + MLXAudioTTS
        // are vendored, since the rest (STT/VAD/LID/STS/UI) are
        // unused by bitHumanKit. To resync from upstream: re-copy
        // Sources/MLXAudio*/ and reconcile any new internal target
        // deps below against upstream's Package.swift.

        .target(
            name: "MLXAudioCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/MLXAudioCore"
        ),

        .target(
            name: "MLXAudioCodecs",
            dependencies: [
                "MLXAudioCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/MLXAudioCodecs"
        ),

        .target(
            name: "MLXAudioG2P",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ],
            path: "Sources/MLXAudioG2P"
        ),

        .target(
            name: "MLXAudioTTS",
            dependencies: [
                "MLXAudioCore",
                "MLXAudioCodecs",
                "MLXAudioG2P",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/MLXAudioTTS",
            exclude: [
                "Models/Chatterbox/README.md",
                "Models/EchoTTS/README.md",
                "Models/FishSpeech/README.md",
                "Models/Llama/README.md",
                "Models/Marvis/README.md",
                "Models/PocketTTS/README.md",
                "Models/Qwen3/README.md",
                "Models/Qwen3TTS/README.md",
                "Models/Soprano/README.md",
                "Models/StyleTTS2/KittenTTS/README.md",
                "Models/StyleTTS2/Kokoro/README.md",
            ]
        ),
    ]
)
