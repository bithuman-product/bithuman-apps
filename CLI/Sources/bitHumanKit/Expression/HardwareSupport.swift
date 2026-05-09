import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Validates the host hardware against bitHuman's minimum-spec
/// guarantee: macOS on Apple M3 or later, or an iPad with M-series
/// Apple Silicon (M1 and newer). Older Apple Silicon (M1/M2 Macs)
/// and every A-series iPad can't sustain the ML pipeline at 25 FPS
/// and would produce a choppy avatar; we fail fast at `create()`
/// time with an actionable error rather than let the runtime limp.
enum HardwareSupport {

    enum Verdict {
        case supported
        case unsupported(reason: String)
    }

    /// Apple Silicon chip families we reject on macOS. Parsed from
    /// `machdep.cpu.brand_string` which returns strings like
    /// `"Apple M1"`, `"Apple M2 Pro"`, `"Apple M3 Max"`. Matching on
    /// the bare generation token (`"M1"`, `"M2"`) rejects all
    /// variants of those chips at once.
    private static let unsupportedMacChips: Set<String> = ["M1", "M2"]

    static func check() -> Verdict {
        #if os(macOS)
        let brand = sysctlString("machdep.cpu.brand_string") ?? ""
        if let gen = appleSiliconGeneration(from: brand),
           unsupportedMacChips.contains(gen) {
            return .unsupported(reason:
                "\(brand) detected — bitHuman requires Apple M3 or later on macOS."
            )
        }
        // Intel Macs (no "Apple M*" brand string) are also out — the
        // runtime needs an Apple Silicon GPU + Neural Engine.
        if !brand.contains("Apple M") {
            return .unsupported(reason:
                "\(brand) detected — bitHuman requires Apple Silicon (M3 or later)."
            )
        }
        return .supported

        #elseif os(iOS) || os(visionOS)
        let machine = sysctlString("hw.machine") ?? ""

        // iPhone: 16 Pro / Pro Max (A18 Pro, identifiers iPhone17,1 /
        // iPhone17,2) and later. A18 Pro is the first iPhone chip with
        // the GPU + thermal envelope to sustain the DiT pipeline at
        // conversational cadence; the int4 weight stack keeps the
        // working set under the iPhone's stricter jetsam ceiling. The
        // non-Pro A18 (iPhone17,3 / 17,4) shares RAM but not the GPU
        // cores or thermal headroom, so it stays rejected. Keep this
        // gate aligned with `UI/HardwareCheck.evaluateIPhone`.
        if machine.hasPrefix("iPhone") {
            let supportedPrefixes = ["iPhone17,", "iPhone18,", "iPhone19,", "iPhone20,"]
            let chipOK = supportedPrefixes.contains { machine.hasPrefix($0) }
            guard chipOK else {
                return .unsupported(reason:
                    "\(machine) detected — bitHuman iOS SDK requires iPhone 16 Pro or later (A18 Pro+)."
                )
            }
            let nonProIdentifiers: Set<String> = ["iPhone17,3", "iPhone17,4"]
            if nonProIdentifiers.contains(machine) {
                return .unsupported(reason:
                    "\(machine) detected — bitHuman iOS SDK requires an A18 Pro chip (iPhone 16 Pro / Pro Max). The standard A18 lacks the GPU cores + thermal envelope for sustained 25 FPS."
                )
            }
            return .supported
        }
        // Non-iPad, non-iPhone (simulator on non-Mac? visionOS?) —
        // reject cleanly rather than letting the pipeline crash.
        if !machine.hasPrefix("iPad") {
            return .unsupported(reason:
                "\(machine) is not a supported device — bitHuman iOS SDK requires an iPad with M-series Apple Silicon or an iPhone 16 Pro+."
            )
        }
        // A-series iPads return identifiers iPad6,* through iPad12,*
        // (2018 iPad Pro through 2021 iPad mini). The first M-series
        // iPad is iPad13,* (2021 iPad Pro M1) — any identifier with a
        // numeric prefix ≥ 13 has an M-series chip.
        guard let generation = iPadGeneration(from: machine) else {
            return .unsupported(reason:
                "\(machine) could not be parsed — unexpected device identifier. If you believe this is a supported iPad, please report it."
            )
        }
        guard generation >= 13 else {
            return .unsupported(reason:
                "\(machine) detected — bitHuman iOS SDK requires an iPad with M-series Apple Silicon (iPad Pro 2021 or later, iPad Air 2022 or later)."
            )
        }
        return .supported

        #else
        return .unsupported(reason:
            "bitHuman SDK runs on macOS (Apple M3+) or iPad (M-series). This platform is not supported."
        )
        #endif
    }

    // MARK: - Helpers

    #if canImport(Darwin)
    /// Read a string-valued `sysctl` by name. Returns nil when the
    /// key isn't recognised on this platform (e.g. `hw.perflevel0.name`
    /// is macOS-only) or the call fails for any reason.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
    #else
    private static func sysctlString(_ name: String) -> String? { nil }
    #endif

    /// Extract the numeric generation from an iPad model identifier.
    /// "iPad13,4" → 13. Returns nil on malformed input.
    static func iPadGeneration(from machine: String) -> Int? {
        guard machine.hasPrefix("iPad") else { return nil }
        // iPadN,M — N is the generation.
        let rest = machine.dropFirst(4)
        let generationPart = rest.prefix { $0.isNumber }
        return Int(generationPart)
    }

    /// Parse an Apple Silicon generation token (`"M1"`, `"M2"`, `"M3"`,
    /// …) out of a `machdep.cpu.brand_string` value. Returns nil on
    /// non-Apple-Silicon hosts (Intel brand strings don't match).
    ///
    /// Examples:
    /// - `"Apple M1"`           → `"M1"`
    /// - `"Apple M2 Pro"`       → `"M2"`
    /// - `"Apple M3 Max"`       → `"M3"`
    /// - `"Intel(R) Core(TM)…"` → `nil`
    static func appleSiliconGeneration(from brandString: String) -> String? {
        // Split on whitespace, look for the first token starting with
        // "M" followed by digits. Handles the "Apple M5 Pro" variant
        // without enumerating every suffix.
        for token in brandString.split(separator: " ") {
            guard token.hasPrefix("M"),
                  token.count >= 2,
                  token.dropFirst().allSatisfy(\.isNumber) else {
                continue
            }
            return String(token)
        }
        return nil
    }
}
