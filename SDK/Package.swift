// swift-tools-version: 6.0
import PackageDescription

// bitHumanKit — on-device voice + video chat SDK for Apple Silicon, by bitHuman.
// https://www.bithuman.ai
//
// This package is the canonical Swift source tree for the bitHuman SDK
// inside `bithuman-apps`. Every Swift consumer in this repo (Mac/, iPad/,
// iPhone/, CLI/) builds against this package via `path:` SPM deps. The
// public binary distribution at
// https://github.com/bithuman-product/bithuman-sdk-public/releases is
// produced from this same source by the release pipeline.
//
// Products:
//   - bitHumanKit              — the SDK proper. Avatar engines (Expression,
//                                Essence), LLM/TTS/ASR pipelines, asset
//                                management, cross-platform SwiftUI views.
//   - BithumanRealtimeOpenAI   — optional libwebrtc-based transport for
//                                OpenAI Realtime cloud sessions. Kept as a
//                                separate library so the 100 MB libwebrtc
//                                binary doesn't bloat consumers (Mac/iPad/
//                                iPhone) that don't need cloud realtime.
//
// Internal targets (not exposed as libraries; statically linked into
// bitHumanKit's binary distribution):
//   - BitHumanInt8Conv  — hand-NEON int8 GEMM kernel (C). Used by Essence.
//   - MLXAudioCore / Codecs / G2P / TTS  — vendored from
//     Blaizzy/mlx-audio-swift @ 020b7529. Powers Kokoro + Qwen3-TTS.
//
// Stack:
//   ASR    Apple SpeechAnalyzer + SpeechTranscriber (built into macOS 26)
//   LLM    Gemma 4 E2B 4-bit via mlx-swift-lm (Mac), Gemma 3 1B QAT (iOS)
//   TTS    Qwen3-TTS 0.6B 4-bit (voice mode, cloning) +
//          Kokoro 82M 4-bit (avatar mode, preset)
//   AEC    hardware via AVAudioEngine voice-processing IO unit (macOS only)
//   AVATAR bitHuman expression engine (Wav2Vec2 → DiT → VAE → ANE)

let package = Package(
    name: "bithuman-kit",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "bitHumanKit", targets: ["bitHumanKit"]),
        // Optional cloud-realtime transport. Consumers that don't need
        // OpenAI Realtime (currently iPad / iPhone reference apps) skip
        // this library and avoid pulling libwebrtc.
        .library(name: "BithumanRealtimeOpenAI", targets: ["BithumanRealtimeOpenAI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        // libwebrtc binary xcframework — used only by
        // `BithumanRealtimeOpenAI`. We use **LiveKit's WebRTC fork** rather
        // than stasel/WebRTC: it ships proper macOS headers AND adds an
        // `RTCAudioRenderer` protocol on top of upstream Google libwebrtc,
        // which lets us tap the bot audio track for `EssenceRuntime.pushAudio`
        // to drive lipsync. Stasel's stripped Google build doesn't expose
        // this, so the avatar-cloud lipsync path would otherwise have to
        // fall back to the WebSocket transport — which empirically the
        // server won't VAD over PCM-base64 (voice mode works because it
        // uses an Opus RTP track, never WS audio).
        .package(url: "https://github.com/livekit/webrtc-xcframework", exact: "144.7559.04"),
    ],
    targets: [
        // C target: hand-NEON int8 GEMM + per-channel requantize for the
        // Essence audio encoder. Apple Silicon arm64; falls back to
        // scalar on non-arm64 CI hosts. Consumed by the Swift
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
                // Hand-NEON int8 GEMM kernel.
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
        // OpenAI realtime backend — `bithuman-cli voice --openai` and
        // `bithuman-cli avatar --openai` route here. WebRTC peer
        // connection to OpenAI's realtime endpoint, libwebrtc-managed
        // audio I/O (so AEC + NS + AGC are handled by the same
        // library Chrome uses for `getUserMedia`).
        .target(
            name: "BithumanRealtimeOpenAI",
            dependencies: [
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
            ],
            path: "Sources/BithumanRealtimeOpenAI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

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
