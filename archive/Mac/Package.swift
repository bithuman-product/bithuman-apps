// swift-tools-version: 6.0
import PackageDescription

// BithumanMac — reference macOS app demonstrating how to embed the
// `bitHumanKit` SDK in a SwiftUI App-lifecycle binary you can ship as
// a notarised .app + Sparkle DMG.
//
// External developers: clone the bithuman-apps repo, then run
// `swift build -c release --product BithumanMac` from this Mac/
// directory. SPM pulls bitHumanKit from the public binary distribution
// at https://github.com/bithuman-product/bithuman-sdk-public — a single
// `bitHumanKit` binaryTarget with every transitive dep statically
// linked, so this manifest needs no other dependencies for the engine
// itself. Sparkle stays as a build-time dep for the auto-updater.

let package = Package(
    name: "BithumanMac",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "BithumanMac", targets: ["BithumanMac"]),
    ],
    dependencies: [
        // The SDK — public binary distribution. `bithuman-sdk-public`
        // wraps the pre-compiled `bitHumanKit.xcframework` as a
        // SwiftPM binaryTarget; every transitive Swift Package
        // dependency (MLX, swift-transformers, …) is statically linked
        // into the framework binary, so this is the only SDK package
        // needed.
        //
        // 0.8.1 is the latest published binary release; it carries
        // the heartbeat-metering + bundled CLI key + extended agentic
        // docs work from bithuman-kit 0.8.1. Essence (the rectangular
        // full-frame on-device runtime) lands in 0.10.0 — until that
        // ships, the Essence branch in `BithumanMacApp.videoSessionLaunch`
        // stays gated behind the `BITHUMAN_KIT_ESSENCE` Swift compile
        // flag and the demo falls through to the existing Expression
        // path. See `RuntimeDispatch.swift` for the planned
        // `Bithuman.createRuntime` dispatch — it's the additive new
        // branch, not a replacement of the existing Expression
        // behaviour.
        // TODO: bump `from:` to 0.10.0 (or whatever the next
        // bithuman-sdk-public release happens to be) and uncomment
        // the `.define("BITHUMAN_KIT_ESSENCE")` swift setting below
        // when that release ships.
        //
        // Single source of truth: `../version.yml`. When you bump the
        // version below, also update `../iPad/App/project.yml` and
        // `../iPhone/App/project.yml` and `../version.yml` together
        // — CI's `sdk-version-consistency` workflow fails otherwise.
        .package(
            url: "https://github.com/bithuman-product/bithuman-sdk-public.git",
            from: "0.8.1"
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
                .product(name: "bitHumanKit", package: "bithuman-sdk-public"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            // Swift 5 mode — bitHumanKit's audio types (AVAudioPCMBuffer
            // et al.) aren't Sendable yet, and Apple's audio frameworks
            // predate strict concurrency. Match the SDK's setting so
            // call sites compile without isolation noise.
            //
            // BITHUMAN_KIT_ESSENCE — enable the Essence runtime branch in
            // `RuntimeDispatch.swift`. Off by default because the public
            // 0.8.1 / 0.9.0 SDK does not yet export
            // `Bithuman.createRuntime` or `EssenceRuntime`. Re-enable
            // (and bump the dep `from:` above to 0.10.0+) when the next
            // bithuman-sdk-public release ships. Until then the demo
            // takes the existing Expression-only path unchanged.
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // .define("BITHUMAN_KIT_ESSENCE"),  // ← uncomment with 0.10.0+
            ]
        ),
    ]
)
