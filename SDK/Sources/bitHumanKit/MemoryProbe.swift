// MemoryProbe — periodic os_proc_available_memory() + phys_footprint
// readout for sideloaded test builds. Used during the entitlement-
// drop validation: if `available` stays well above zero across a
// full conversation, the app fits under the default jetsam ceiling
// without `increased-memory-limit`.
//
// iOS / iPadOS only — macOS doesn't have these APIs in the same
// shape and isn't memory-constrained anyway.

#if canImport(UIKit)
import Foundation
import Darwin

public enum MemoryProbe {
    /// Snapshot of process memory at a moment in time.
    public struct Snapshot: Sendable {
        /// Current dirty + compressed pages charged to this process,
        /// in MB. This is the number jetsam compares against the
        /// per-app limit. Equivalent to Xcode's "Memory" gauge.
        public let physFootprintMB: Int
        /// Bytes left before the OS kills this process for memory
        /// pressure, in MB. Crosses zero → jetsam imminent. iOS 13+.
        public let availableMB: Int
    }

    /// Read once, no allocation.
    public static func snapshot() -> Snapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kerr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = (kerr == KERN_SUCCESS)
            ? Int(info.phys_footprint) / 1_048_576
            : -1
        let avail = Int(os_proc_available_memory()) / 1_048_576
        return Snapshot(physFootprintMB: footprint, availableMB: avail)
    }

    /// Start a 2-second polling task that prints to stdout. Cancel the
    /// returned Task to stop. Safe to call on launch — it'll stay
    /// silent until the engine starts allocating.
    @discardableResult
    public static func startLogging(intervalSeconds: Double = 2.0, label: String = "mem") -> Task<Void, Never> {
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                let s = snapshot()
                NSLog("[\(label)] footprint=\(s.physFootprintMB)MB available=\(s.availableMB)MB")
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
    }
}
#endif
