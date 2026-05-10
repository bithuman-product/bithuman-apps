// ServePreflight.swift
//
// Pre-flight checks for `bithuman-cli serve`. All read-only —
// catches missing dependencies before we start spawning subprocesses
// (livekit-server, essence-server, brain bridge) and binding ports.

import Foundation
import Darwin

/// Pre-flight checks for `bithuman-cli serve`.
public enum ServePreflight {

    // MARK: - Binary locators

    /// Locate the `livekit-server` binary. Searches `$PATH` first,
    /// then `/opt/homebrew/bin/livekit-server`,
    /// then `/usr/local/bin/livekit-server`. Returns the absolute
    /// path or nil.
    public static func locateLiveKitServer() -> URL? {
        if let p = whichInPath("livekit-server") { return p }
        for fallback in [
            "/opt/homebrew/bin/livekit-server",
            "/usr/local/bin/livekit-server",
        ] {
            if FileManager.default.isExecutableFile(atPath: fallback) {
                return URL(fileURLWithPath: fallback)
            }
        }
        return nil
    }

    /// Locate the `essence-server` binary. Searches `$PATH` first,
    /// then the homebrew prefixes, then the local SDK dev-build
    /// path `~/bithuman/bithuman-sdk/swift/.build/release/essence-server`.
    /// Returns nil if not found.
    public static func locateEssenceServer() -> URL? {
        if let p = whichInPath("essence-server") { return p }
        var candidates = [
            "/opt/homebrew/bin/essence-server",
            "/usr/local/bin/essence-server",
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append("\(home)/bithuman/bithuman-sdk/swift/.build/release/essence-server")
        candidates.append("\(home)/bithuman/bithuman-sdk/swift/.build/debug/essence-server")
        candidates.append("\(home)/bithuman/bithuman-sdk/swift/.build/arm64-apple-macosx/release/essence-server")
        candidates.append("\(home)/bithuman/bithuman-sdk/swift/.build/arm64-apple-macosx/debug/essence-server")
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                return URL(fileURLWithPath: c)
            }
        }
        return nil
    }

    // MARK: - Port probe

    /// Probe a TCP port to make sure it's free. Returns true if
    /// nothing's listening on (127.0.0.1, port).
    ///
    /// Implementation: try to `bind()` an ephemeral TCP socket to
    /// 127.0.0.1:port. If bind succeeds, nothing else is bound there
    /// → port is free. If bind fails with EADDRINUSE → port is in use.
    /// This is the standard idiom — vastly more reliable than a
    /// connect-probe (which has to disambiguate ECONNREFUSED from
    /// timeouts and from listening-but-not-accepting on a backlog'd
    /// socket).
    public static func portIsFree(_ port: Int) -> Bool {
        guard port > 0, port < 65_536 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // SO_REUSEADDR so a recently-closed socket in TIME_WAIT
        // doesn't make us spuriously report "in use".
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                       socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }

    // MARK: - Hints

    /// Compose a friendly multi-line install hint to print to stderr
    /// when livekit-server is missing.
    public static var liveKitServerInstallHint: String {
        """
        livekit-server is not on your PATH. Install via Homebrew:

            brew install livekit

        Then re-run `bithuman-cli serve`. (LiveKit's homebrew formula
        provides the `livekit-server` binary that bithuman-cli spawns
        in dev mode for local serve.)
        """
    }

    // MARK: - Internal helpers

    /// `which(1)` lookup on the current process's PATH, scanning each
    /// colon-separated entry for an executable file.
    private static func whichInPath(_ name: String) -> URL? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }
        let fm = FileManager.default
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}

// MARK: - fd_set helpers
//
// Swift can't index Darwin's fd_set bitmask directly because it imports
// as a tuple. These two shims poke the right bit.

private func fdZero(_ set: inout fd_set) {
    set = fd_set()
}

private func fdSet(_ fd: Int32, set: inout fd_set) {
    let intOffset = Int(fd / 32)
    let bitOffset = Int(fd % 32)
    let mask = Int32(bitPattern: UInt32(1) << UInt32(bitOffset))
    withUnsafeMutablePointer(to: &set.fds_bits) {
        $0.withMemoryRebound(to: Int32.self, capacity: Int(__DARWIN_FD_SETSIZE) / 32) { p in
            p[intOffset] |= mask
        }
    }
}

#if DEBUG
// Compile-time smoke: reference each public symbol so the API
// surface is checked at build time.
private let _servePreflightSmoke: @Sendable () -> Void = {
    _ = ServePreflight.locateLiveKitServer()
    _ = ServePreflight.locateEssenceServer()
    _ = ServePreflight.portIsFree(7880)
    _ = ServePreflight.liveKitServerInstallHint
}
#endif
