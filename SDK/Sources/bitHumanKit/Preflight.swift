import AVFoundation
import Foundation

/// Hard / soft prerequisites for running `bithuman-cli` on this machine.
/// Run before model loads so a misconfigured environment fails fast
/// with an actionable message instead of crashing 30 seconds in
/// during a Hugging Face download.
public enum Preflight {
    /// Which checks to run for this invocation. Text mode doesn't
    /// touch audio hardware, so it skips the audio-output probe (a
    /// headless dev box without speakers should still be able to do
    /// `bithuman-cli text`).
    public struct Checks: Sendable {
        public var audioOutput: Bool
        public init(audioOutput: Bool = true) {
            self.audioOutput = audioOutput
        }
        public static let voice = Checks(audioOutput: true)
        public static let text = Checks(audioOutput: false)
    }

    /// Hardware + OS sanity. Throws `.hardError` for showstoppers
    /// (wrong arch, wrong OS); just prints a friendly warning for
    /// soft issues (low RAM, low disk) so the user sees the risk
    /// without being blocked.
    public static func run(_ checks: Checks = .voice) throws {
        try checkMacOSVersion()
        try checkArchitecture()
        warnOnLowMemory()
        warnOnLowDisk()
        if checks.audioOutput {
            try checkAudioOutput()
        }
    }

    // MARK: hard checks

    private static func checkMacOSVersion() throws {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        // SpeechAnalyzer (modular Speech API) and FoundationModels
        // both shipped at WWDC25 in macOS 26. Earlier versions don't
        // have the required symbols.
        if v.majorVersion < 26 {
            let actual = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            throw PreflightError.unsupportedOS(actual: actual, requiredMajor: 26)
        }
    }

    private static func checkArchitecture() throws {
        #if !arch(arm64)
        throw PreflightError.unsupportedArch(actual: "\(currentArch())")
        #elseif os(macOS)
        // Build-time arch check covers the typical case. Belt-and-
        // braces runtime sysctl in case someone built fat and is
        // running through Rosetta2 on Intel hardware.
        // macOS-only — on iOS/iPadOS, `hw.machine` returns the
        // device model (e.g. "iPad17,3"), not the architecture, so
        // this check would always fail. The build-time guard above
        // is sufficient for iOS — Apple's App Store rejects
        // x86 iOS binaries.
        if currentArch() != "arm64" {
            throw PreflightError.unsupportedArch(actual: currentArch())
        }
        #endif
    }

    private static func checkAudioOutput() throws {
        // Quick smoke: can AVAudioEngine see a non-empty default
        // output format? An empty / 0-channel output usually means
        // "no audio device" (e.g. headless CI) and the rest of the
        // pipeline will fail more confusingly later.
        let engine = AVAudioEngine()
        let fmt = engine.outputNode.outputFormat(forBus: 0)
        if fmt.channelCount == 0 || fmt.sampleRate == 0 {
            throw PreflightError.noAudioOutput
        }
    }

    // MARK: soft checks (warn + continue)

    /// Recommended floor: 8 GB physical RAM (working set is ~4 GB so
    /// 8 GB leaves headroom for the rest of the system). Warn at <8,
    /// don't block.
    private static func warnOnLowMemory() {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Double(bytes) / 1_073_741_824
        if gb < 8 {
            let formatted = String(format: "%.1f", gb)
            FileHandle.standardError.write(Data(
                "⚠️  warning: only \(formatted) GB physical RAM — bithuman-cli expects ≥ 8 GB. Expect heavy swap during long conversations.\n".utf8
            ))
        }
    }

    /// Recommended floor: 5 GB free in the Hugging Face cache volume
    /// (model weights total ~3 GB; leave ~2 GB slack for the speech
    /// model lazy-download and OS pressure). macOS-only — iOS apps
    /// run inside a sandboxed container with the OS managing storage
    /// pressure for them, so this check would just be noise on
    /// iPad/iPhone.
    private static func warnOnLowDisk() {
        #if os(macOS)
        // Probe the volume that ~/.cache lives on; fall back to ~ if
        // the cache dir hasn't been created yet (first-run users).
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
        let url = FileManager.default.fileExists(atPath: cacheDir.path)
            ? cacheDir
            : FileManager.default.homeDirectoryForCurrentUser
        guard
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let bytes = values.volumeAvailableCapacityForImportantUsage
        else { return }
        let gb = Double(bytes) / 1_073_741_824
        if gb < 5 {
            let formatted = String(format: "%.1f", gb)
            FileHandle.standardError.write(Data(
                "⚠️  warning: only \(formatted) GB free disk on the cache volume — first-run model download needs ~3 GB.\n".utf8
            ))
        }
        #endif
    }

    private static func currentArch() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

public enum PreflightError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case unsupportedOS(actual: String, requiredMajor: Int)
    case unsupportedArch(actual: String)
    case noAudioOutput

    public var description: String {
        switch self {
        case .unsupportedOS(let actual, let required):
            return """
            macOS \(actual) is too old. bithuman-cli needs macOS \(required).0 or newer.
            (SpeechAnalyzer and FoundationModels both shipped with macOS \(required).)
            """
        case .unsupportedArch(let actual):
            return """
            Unsupported architecture: \(actual). bithuman-cli is Apple Silicon only —
            mlx-swift's Metal kernels don't run on Intel or under Rosetta 2.
            """
        case .noAudioOutput:
            return """
            No usable audio output device found. Plug in headphones or
            speakers and try again.
            """
        }
    }

    /// `LocalizedError.errorDescription` is what `Error.localizedDescription`
    /// reads from. SwiftUI shows that string when an app catches an Error
    /// and surfaces it as boot error text — without this, callers see
    /// the generic "PreflightError error N" Foundation autobridges.
    public var errorDescription: String? { description }
}
