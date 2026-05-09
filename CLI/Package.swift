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
// `BithumanRealtimeOpenAI` cloud transport. Both come from a sibling
// package at `../SDK` in this monorepo; CLI/Sources/BithumanCLI/ holds
// only CLI-specific code (arg parsing, mode dispatch, runners, terminal
// rendering, key storage, billing display).
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
        // The SDK lives in a sibling directory in this monorepo.
        // `path:` keeps the dev loop tight: edit SDK source, rebuild
        // CLI, no checkout/release cycle. The same `bithuman-apps/SDK`
        // tree is what the public binary distribution at
        // bithuman-product/bithuman-sdk-public is produced from.
        .package(path: "../SDK"),
    ],
    targets: [
        .executableTarget(
            name: "BithumanCLI",
            dependencies: [
                .product(name: "bitHumanKit", package: "SDK"),
                .product(name: "BithumanRealtimeOpenAI", package: "SDK"),
            ],
            path: "Sources/BithumanCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
