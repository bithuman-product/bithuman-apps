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
        // workspace layout. Both `bitHumanKit` and `BithumanRealtimeOpenAI`
        // products are exposed by that package.
        .package(path: "../../bithuman-sdk/swift"),
        // JWTKit drives the LiveKit access-token minting in
        // `Sources/BithumanCLI/Serve/LiveKitTokenGenerator.swift`
        // (used by `bithuman-cli serve`'s local livekit-server dev
        // mode). Version pin matches the bithuman-sdk swift/Package.swift
        // so the resolver doesn't have to reconcile two ranges.
        .package(url: "https://github.com/vapor/jwt-kit", from: "5.0.0"),
        // Hummingbird hosts the static web client at :8090 in
        // `bithuman-cli serve`. Same major-version pin as the
        // bithuman-sdk EssenceServer dep so SwiftPM resolution is a
        // straight shot.
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "BithumanCLI",
            dependencies: [
                .product(name: "bitHumanKit", package: "swift"),
                .product(name: "BithumanRealtimeOpenAI", package: "swift"),
                .product(name: "BithumanLiveKitBridge", package: "swift"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/BithumanCLI",
            // Serve-mode static web client bundled via Bundle.module
            // for ServeRunner. `.copy` preserves the serve-web/
            // directory inside the resource bundle so the runner can
            // do `Bundle.module.url(forResource:withExtension:subdirectory:)`.
            resources: [.copy("Resources/serve-web")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
