// Retired 2026-05-09. The CLI used to inject the bitHuman API key
// into this file at release time so the brew-distributed binary
// carried the key as a Mach-O string literal accessible without any
// user configuration. That convenience came at the cost of credential
// exposure — `strings bithuman-cli` revealed the key — which is the
// wrong shape for a credential that's meant to scope per-account
// metering.
//
// The CLI now resolves the bitHuman API key from environment variable
// or 0600 file at `~/Library/Application Support/com.bithuman.cli/
// bithuman-api-key` (parallel to the OpenAI key). Users without one
// fall through to dev-mode unmetered avatar — the auth service
// permits this — and `bithuman-cli doctor` points them at the signup
// URL when no key is found.
//
// The struct here is intentionally hollow + permanent. Its `value`
// always returns nil, regardless of build mode. Kept around so any
// historical reference (defensive — none in-tree today) still
// compiles, with a deprecation marker so new code doesn't reach for
// it.

internal enum BithumanEmbeddedKey {
    @available(*, deprecated, message: "Embedded keys retired in 0.16.0; resolve via env/file via BithumanKey.load() instead.")
    internal static var value: String? { nil }
}
