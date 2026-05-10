// Auth + fatal-error helpers.
//
// `fatalUsage` is the canonical "user-facing parse error" exit
// path used throughout the parser and validators. It always emits
// a one-line `Run \`bithuman-cli --help\` for usage` pointer after
// the error so the user has a next step.
//
// `fatalKey`, `fatalBitHumanKeyMissing`, and
// `fatalBitHumanAuthFailed` are the three credential-failure
// flavours: missing OpenAI key, missing bitHuman developer key,
// and the bitHuman billing service rejecting an otherwise
// well-formed key (suspended / out of credit / unreachable).
// Each prints a message tailored to the actual cause and exits
// with a distinct code (2 for usage, 3 for auth) so callers can
// branch on `$?`.
//
// `makeBithumanHeartbeat` is the shared "is the developer key
// reachable; can we actually bill?" probe used by Expression and
// Essence cloud paths before they spin up the runtime.

import Foundation
import bitHumanKit

func makeBithumanHeartbeat(
    billingType: String,
    tags: String
) -> BithumanHeartbeat? {
    guard let key = BithumanKey.load(), !key.isEmpty else {
        FileHandle.standardError.write(Data("""
            ℹ️  No BITHUMAN_API_KEY set — running unmetered.
               Get a key at \(BithumanKey.signupURL) and either:
                 export BITHUMAN_API_KEY=...
               or save it once:
                 mkdir -p ~/Library/Application\\ Support/com.bithuman.cli
                 printf %s 'sk-...' > ~/Library/Application\\ Support/com.bithuman.cli/bithuman-api-key
                 chmod 600     ~/Library/Application\\ Support/com.bithuman.cli/bithuman-api-key

            """.utf8))
        return nil
    }
    return BithumanHeartbeat(config: BithumanAuthConfig(
        apiSecret: key,
        billingType: billingType,
        tags: tags
    ))
}

func missingKeyMessage() -> String {
    let cyan = "\u{1B}[36m"
    let bold = "\u{1B}[1m"
    let dim = "\u{1B}[2m"
    let reset = "\u{1B}[0m"
    return """
        --openai needs an OpenAI API key, and none was found.

        \(bold)Pick the option that fits:\(reset)

          \(bold)1.\(reset) \(dim)Easiest — paste a key now (we'll save it for next time):\(reset)
                \(cyan)bithuman-cli avatar\(reset)
              When prompted, paste your key and answer "y" to "Save it locally?"

          \(bold)2.\(reset) \(dim)Export in your shell so every tool sees it:\(reset)
                \(cyan)echo 'export OPENAI_API_KEY=sk-...' >> ~/.zshrc\(reset)
                \(cyan)source ~/.zshrc\(reset)

          \(bold)3.\(reset) \(dim)Write the saved-key file directly:\(reset)
                \(cyan)mkdir -p ~/Library/Application\\ Support/com.bithuman.cli\(reset)
                \(cyan)printf %s 'sk-...' > ~/Library/Application\\ Support/com.bithuman.cli/openai-api-key\(reset)
                \(cyan)chmod 600     ~/Library/Application\\ Support/com.bithuman.cli/openai-api-key\(reset)

        \(dim)Get a key at https://platform.openai.com/api-keys\(reset)
        """
}

/// Like `fatalUsage` but skips the full help-text dump — the
/// message itself is already self-contained instructions, and
/// stacking the entire `--help` block beneath it just buries the
/// thing the user actually needs to read.
internal func fatalKey() -> Never {
    FileHandle.standardError.write(Data("error: \(missingKeyMessage())\n\n".utf8))
    exit(2)
}

internal func fatalUsage(_ message: String) -> Never {
    // Tight error first, then a one-liner pointer to --help. Dumping
    // the full help text on every malformed flag was producing an
    // overwhelming wall of output that buried the actual cause.
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    FileHandle.standardError.write(Data("Run `bithuman-cli --help` for usage.\n".utf8))
    exit(2)
}

/// Avatar mode requires a bitHuman API key — there is no unmetered
/// fallback. Print the setup hint that mirrors `doctor` and exit.
internal func fatalBitHumanKeyMissing() -> Never {
    let msg = """

    error: avatar mode requires a bitHuman API key.

    Get a key at \(BithumanKey.signupURL) and either:
        export BITHUMAN_API_KEY=...
        # or save it to the 0600 key file:
        echo "<key>" > ~/Library/Application\\ Support/com.bithuman.cli/bithuman-api-key
        chmod 600 ~/Library/Application\\ Support/com.bithuman.cli/bithuman-api-key

    Run `bithuman-cli doctor` to verify the key is picked up.

    """
    FileHandle.standardError.write(Data(msg.utf8))
    exit(2)
}

/// The bitHuman billing service refused the supplied key. Surface the
/// underlying reason — bad credential, insufficient balance, suspended —
/// without forcing the user to read a Swift stack trace.
internal func fatalBitHumanAuthFailed(_ err: BithumanAuthError) -> Never {
    let detail: String
    switch err {
    case .insufficientBalance(let m):
        detail = "insufficient balance — \(m)\nTop up at https://www.bithuman.ai/#developer"
    case .accountSuspended(let m):
        detail = "account suspended — \(m)\nContact bitHuman support at hello@bithuman.ai"
    case .invalidResponseShape:
        detail = "the bitHuman billing service returned an unexpected response. Try again, or contact hello@bithuman.ai if it persists."
    case .networkFailure(let underlying):
        detail = "couldn't reach the bitHuman billing service: \(underlying.localizedDescription)\nCheck your network connection and try again."
    case .unexpectedStatus(let code, _):
        detail = "the bitHuman billing service returned HTTP \(code). Verify your key at https://www.bithuman.ai/#developer."
    }
    let msg = """

    error: bitHuman authentication failed.

    \(detail)

    """
    FileHandle.standardError.write(Data(msg.utf8))
    exit(3)
}

func cliWarn(_ message: String) {
    FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
}

