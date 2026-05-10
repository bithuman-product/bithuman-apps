// swift-tools-version: 6.0
import PackageDescription

// bithuman-cli — on-device voice + video chat CLI for macOS, by bitHuman.
// https://www.bithuman.ai
//
// This package builds the `bithuman-cli` executable that ships via
// `brew install bithuman-cli` from
// https://github.com/bithuman-product/homebrew-bithuman.
//
// The CLI is a thin wrapper around the `bitHumanKit` SDK + the optional
// `BithumanRealtimeOpenAI` cloud transport. Both come from the
// `bithuman-product/bithuman-sdk` private monorepo (the canonical
// engine source-of-truth, alongside the Python SDK). For local
// development the dep is resolved via SwiftPM `path:` against a sibling
// clone — i.e., we expect:
//
//   ~/your-workspace/
//   ├── bithuman-sdk/        (cloned from bithuman-product/bithuman-sdk)
//   └── bithuman-apps/       (cloned from bithuman-product/bithuman-apps)
//
// `swift build` from this directory then resolves
// `../../bithuman-sdk/swift` and pulls bitHumanKit + BithumanRealtimeOpenAI.
//
// CI and the brew release pipeline (release.sh) check out both repos
// side-by-side before invoking the build, so the same `path:` dep
// resolves there too.
//
// The executable PRODUCT is `bithuman-cli` (with the hyphen); the
// internal target is `BithumanCLI` (CamelCase, since Swift target names
// can't contain hyphens). `brew install bithuman-cli` installs the
// hyphen form.

let package = Package(
    name: "bithuman-cli",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "bithuman-cli", targets: ["BithumanCLI"]),
    ],
    dependencies: [
        // Sibling-clone path dep on the bithuman-sdk monorepo's swift/
        // package. See the comment block above for the expected
        // workspace layout. `bitHumanKit` and `BithumanRealtimeOpenAI`
        // are exposed by that package.
        .package(path: "../../bithuman-sdk/swift"),
    ],
    targets: [
        .executableTarget(
            name: "BithumanCLI",
            dependencies: [
                .product(name: "bitHumanKit", package: "swift"),
                .product(name: "BithumanRealtimeOpenAI", package: "swift"),
            ],
            path: "Sources/BithumanCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Unit + smoke tests for the executable target. Uses
        // @testable import to reach internal symbols (closestMatch,
        // FlagHint, knownFlags, etc.). Run via `swift test`.
        //
        // What's covered: pure logic (parsing helpers, Levenshtein,
        // value resolution, persistence formats). What's not: audio
        // I/O, MLX inference, WebRTC, the macOS Keychain backing
        // store, network calls — those require hardware / live
        // services and are validated manually.
        .testTarget(
            name: "BithumanCLITests",
            dependencies: ["BithumanCLI"],
            path: "Tests/BithumanCLITests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
