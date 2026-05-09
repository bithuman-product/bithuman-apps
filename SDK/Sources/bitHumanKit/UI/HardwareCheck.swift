// HardwareCheck.swift — runtime device-capability gate for the
// iPad / iOS apps.
//
// macOS gates separately inside `Bithuman.create` (it throws
// `unsupportedHardware(reason:)` on M1/M2/Intel). iOS targets need
// an UP-FRONT check before the engine even tries to load — by the
// time we hit `Bithuman.create` we've already downloaded ~1.6 GB
// of int4 weights, which is wasteful on hardware we know can't
// run them.
//
// Hardware floor:
//   - iPad: M4 iPad Pro (`iPad16,X` and later) with ≥16 GB unified
//     memory. With int4 DiT + int4 W2V2 + ANE wav2vec2 the active
//     working set lands around ~5.5 GB during speech (was ~11 GB
//     pre-optimization at fp16). 8 GB SKUs still jetsam under load
//     when the LLM/TTS/MLX scratch slabs all spike together.
//     M2/M3 iPad Pro chips can't sustain 25 FPS thermally. iPad
//     Air (M3) is unsupported — same chip class but sustained
//     inference is borderline thermally.
//   - iPhone: iPhone 16 Pro (`iPhone17,1`) and later, A18 Pro+.
//     The A18 (non-Pro) and earlier passive-cooled phones throttle
//     at 25 FPS within ~30 s.
//   - Mac: handled by the engine itself; this file's macOS branch
//     reports `.supported` unconditionally.

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Result of a runtime hardware-capability probe.
public enum DeviceCapability: Equatable {
    /// The device meets the bitHuman engine's minimum requirements.
    case supported
    /// The device does not meet the requirements. Show
    /// `UnsupportedDeviceView(reason:)` instead of booting the app.
    case unsupported(reason: String)
}

/// Probes the running device against bitHuman's hardware floor.
public enum HardwareCheck {

    /// Evaluate the current device. Call once at app launch (before
    /// kicking off `BithumanPadLifecycle.start()` /
    /// `BithumanPhoneLifecycle.start()`); cache the result.
    @MainActor
    public static func evaluate() -> DeviceCapability {
        #if os(iOS)
        let machine = machineIdentifier()
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return evaluateIPad(machine: machine, ramGB: ramGB)
        } else {
            return evaluateIPhone(machine: machine, ramGB: ramGB)
        }
        #else
        // macOS: `Bithuman.create` is the authoritative gate (M3+ check
        // lives in `HardwareSupport.swift`). Don't second-guess it here.
        return .supported
        #endif
    }

    #if os(iOS)
    private static func evaluateIPad(machine: String, ramGB: Double) -> DeviceCapability {
        // iPad16,X is the M4 iPad Pro (2024). iPad17+ presumed M5+.
        // Older identifiers (iPad13, iPad14, iPad15) cover M1/M2/M3 —
        // refuse those even on the 16 GB SKUs because the chip
        // itself can't sustain 25 FPS under thermal load.
        let supportedPrefixes = ["iPad16,", "iPad17,", "iPad18,", "iPad19,", "iPad20,"]
        let chipOK = supportedPrefixes.contains { machine.hasPrefix($0) }
        guard chipOK else {
            return .unsupported(reason:
                "bitHuman needs an iPad Pro M4 or newer. This device " +
                "(\(machine)) doesn't have the GPU + Neural Engine bandwidth " +
                "to sustain the avatar engine at 25 FPS."
            )
        }
        // 16 GB SKUs report ~14.5 GiB physicalMemory after the system
        // reservation; 8 GB SKUs report ~7 GiB. 13 GiB is the safe
        // threshold for "this is at least a 16 GB device".
        guard ramGB >= 13 else {
            let ramRounded = Int((ramGB * 10).rounded()) / 10
            return .unsupported(reason:
                "bitHuman needs ≥16 GB unified memory. This iPad reports " +
                "~\(ramRounded) GB available — the avatar engine peaks " +
                "around 5.5 GB during speech and would be killed by jetsam mid-conversation."
            )
        }
        return .supported
    }

    private static func evaluateIPhone(machine: String, ramGB: Double) -> DeviceCapability {
        // iPhone17,1 = 16 Pro / 17,2 = 16 Pro Max (both A18 Pro).
        // iPhone17,3 = 16 / 17,4 = 16 Plus (A18, NOT Pro) — refuse.
        // iPhone18,X presumed iPhone 17 family.
        let supportedPrefixes = ["iPhone17,", "iPhone18,", "iPhone19,", "iPhone20,"]
        let chipOK = supportedPrefixes.contains { machine.hasPrefix($0) }
        guard chipOK else {
            return .unsupported(reason:
                "bitHuman needs an iPhone 16 Pro or newer. This device " +
                "(\(machine)) thermal-throttles at 25 FPS within ~30 seconds " +
                "of sustained avatar inference."
            )
        }
        // Pro models: 16 Pro = 8 GB RAM, 16 Pro Max = 8 GB. The
        // non-Pro 16 / 16 Plus also have 8 GB. RAM alone doesn't
        // distinguish — but the chip-prefix check above catches the
        // non-Pro models via specific identifiers (17,3 / 17,4) which
        // we list explicitly:
        let nonProIdentifiers = ["iPhone17,3", "iPhone17,4"]
        if nonProIdentifiers.contains(where: { machine == $0 }) {
            return .unsupported(reason:
                "bitHuman needs an A18 Pro chip (iPhone 16 Pro / Pro Max). " +
                "This device (\(machine)) is the standard A18 — same RAM, " +
                "but lacks the GPU cores + thermal envelope for sustained 25 FPS."
            )
        }
        guard ramGB >= 7 else {
            let ramRounded = Int((ramGB * 10).rounded()) / 10
            return .unsupported(reason:
                "bitHuman needs ≥8 GB RAM. This iPhone reports " +
                "~\(ramRounded) GB available."
            )
        }
        return .supported
    }
    #endif

    /// Read the canonical machine identifier (e.g. `iPad16,1`,
    /// `iPhone17,1`, `Mac15,3`) via `uname(2)`. The string maps 1:1
    /// to a specific Apple-Silicon SKU and is the best signal we have
    /// without a private API for chip family.
    @MainActor
    public static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier
    }
}
