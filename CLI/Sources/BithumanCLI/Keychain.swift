// Plain-file storage for the OpenAI API key under
// `~/Library/Application Support/com.bithuman.cli/openai-api-key`,
// permission-locked to `0600` (owner-only read/write).
//
// **Why we left the Keychain.** Keychain is the more secure option —
// the OS prompts the user the first time another app reads it — but
// `SecItemAdd` triggers a "<binary> wants to access your keychain"
// password dialog every cold-launch when the binary isn't in a
// signed app bundle (which is true for `bithuman-cli` since it's a
// loose Mach-O sitting in `/usr/local/bin`). The user reported having
// to type their login password TWICE on every launch (once for read,
// once for save when validating freshness) which is unacceptable for
// a tool that's meant to be ergonomic.
//
// Plain file is good enough for an API key the user pasted in
// themselves: any process running as the user already has full
// access to their environment, OPENAI_API_KEY env vars, dotfiles,
// etc. The 0600 perms keep other UNIX users on the same Mac out.
// Type-name and call sites kept identical (`BithumanKeychain`,
// `saveOpenAIKey` / `loadOpenAIKey` / `deleteOpenAIKey`) so the
// rest of the CLI didn't need touching.

import Foundation
import Security

enum BithumanKeychain {
    /// Directory that holds CLI-owned per-user state. Under
    /// `~/Library/Application Support/` per Apple's "the right place
    /// for app-private user data" convention.
    private static var stateDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.bithuman.cli", isDirectory: true)
    }

    /// Single-file home for the API key. The filename is stable so a
    /// user troubleshooting from a forum thread can `cat` or
    /// `rm` it without grepping the source.
    private static var keyFile: URL {
        stateDirectory.appendingPathComponent("openai-api-key", isDirectory: false)
    }

    /// Save (or replace) the OpenAI API key. Returns true on success.
    /// Creates the parent directory if it doesn't exist and locks
    /// the file to `0600`.
    static func saveOpenAIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try FileManager.default.createDirectory(
                at: stateDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = Data(trimmed.utf8)
            try data.write(to: keyFile, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: keyFile.path
            )
            return true
        } catch {
            return false
        }
    }

    /// Load the OpenAI API key. Returns nil when the file doesn't
    /// exist; caller treats that as "no saved key". On first read
    /// from a machine that previously stored the key in the macOS
    /// Keychain (the pre-0.11 storage), silently migrate the
    /// keychain entry into our file and delete it from the keychain
    /// — so users upgrading don't have to re-paste their key.
    static func loadOpenAIKey() -> String? {
        if let raw = try? String(contentsOf: keyFile, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // File missing or empty — try the legacy Keychain entry
        // and migrate it forward.
        if let legacy = readLegacyKeychain(), !legacy.isEmpty {
            _ = saveOpenAIKey(legacy)
            deleteLegacyKeychain()
            return legacy
        }
        return nil
    }

    /// Pre-0.11 used `kSecClassGenericPassword` under
    /// `service=ai.bithuman.cli`, `account=openai-api-key`. Read
    /// here only for the migration path; new saves all go through
    /// `keyFile` above.
    private static let legacyService = "ai.bithuman.cli"
    private static let legacyAccount = "openai-api-key"

    private static func readLegacyKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deleteLegacyKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Remove the saved OpenAI key. Idempotent.
    @discardableResult
    static func deleteOpenAIKey() -> Bool {
        try? FileManager.default.removeItem(at: keyFile)
        return true
    }
}
