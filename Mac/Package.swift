// swift-tools-version: 6.0
import PackageDescription

// BithumanMac — reference macOS app demonstrating how to embed the
// `bitHumanKit` SDK in a SwiftUI App-lifecycle binary you can ship as
// a notarised .app + Sparkle DMG.
//
// External developers: clone the bithuman-apps repo, then run
// `swift build -c release --product BithumanMac` from this Mac/
// directory. SPM pulls bitHumanKit from the public repo below.
//
// The bithuman-kit package itself is the SDK source of truth at
// https://github.com/bithuman-product/bithuman-kit — this manifest only
// declares the dependency; the SDK package's own manifest pulls in
// MLX, swift-transformers, mlx-audio-swift, etc.

let package = Package(
    name: "BithumanMac",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "BithumanMac", targets: ["BithumanMac"]),
    ],
    dependencies: [
        // The SDK. Bump `from:` to pick up newer SDK releases. A tag
        // matching this version must exist on the bithuman-kit repo.
        .package(
            url: "https://github.com/bithuman-product/bithuman-kit.git",
            from: "0.1.0"
        ),
        // Sparkle: auto-update for the .app distribution. 2.7+ has the
        // modern XPC-based privileged updater needed for sandbox-safe
        // updates. Drop this dep if you're not shipping signed updates.
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.7.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "BithumanMac",
            dependencies: [
                .product(name: "bitHumanKit", package: "bithuman-kit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            // Swift 5 mode — bitHumanKit's audio types (AVAudioPCMBuffer
            // et al.) aren't Sendable yet, and Apple's audio frameworks
            // predate strict concurrency. Match the SDK's setting so
            // call sites compile without isolation noise.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
