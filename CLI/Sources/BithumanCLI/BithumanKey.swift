// Plain-file storage for the bitHuman developer API key, parallel
// to `BithumanKeychain` for OpenAI. Lives under
// `~/Library/Application Support/com.bithuman.cli/bithuman-api-key`
// at mode 0600.
//
// The bitHuman SDK expects this key for the per-minute heartbeat
// against `api.bithuman.ai/v1/runtime-tokens/request`. Without it,
// avatar mode runs unmetered (which the auth-service permits for
// development) but won't surface live cost / balance feedback.
//
// Get a key at https://www.bithuman.ai/#developer

import Foundation

enum BithumanKey {
    private static var stateDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.bithuman.cli", isDirectory: true)
    }

    private static var keyFile: URL {
        stateDirectory.appendingPathComponent("bithuman-api-key", isDirectory: false)
    }

    /// Where the user can pick up an API key. Surfaced in prompts
    /// and error messages so they don't have to dig through docs.
    static let signupURL = "https://www.bithuman.ai/#developer"

    /// Resolve in priority order: env > saved file. Returns nil
    /// when neither is set; callers run the avatar without billing
    /// (development mode).
    static func load() -> String? {
        if let env = ProcessInfo.processInfo.environment["BITHUMAN_API_KEY"], !env.isEmpty {
            return env
        }
        guard let raw = try? String(contentsOf: keyFile, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try FileManager.default.createDirectory(
                at: stateDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(trimmed.utf8).write(to: keyFile, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: keyFile.path
            )
            return true
        } catch {
            return false
        }
    }
}
