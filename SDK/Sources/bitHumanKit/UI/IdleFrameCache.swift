import CoreGraphics
import Foundation

/// Per-portrait palindrome cache of idle DiT frames. The first
/// ~10 s of idle generation feeds frames in via `absorb(_:)`. Once
/// `isReady` flips true, the producer stops calling the engine and
/// just calls `next()` — which bounces an index forward from 0 to
/// the last frame, then back, then forward, indefinitely. The
/// palindrome traversal makes the loop visually seamless: the
/// boundary between forward and reverse playback is a single shared
/// frame, so there's no jump.
///
/// **Why not just a forward-only loop?** Idle motion is small jitter
/// around a neutral pose. The first and last frames of any 10 s
/// window aren't identical, so a plain forward-only loop pops at
/// the seam every cycle. Palindrome avoids that without needing to
/// engineer a perfectly-looping segment from the engine.
///
/// **Memory:** at 384 px × 384 px × 4 B × 250 frames ≈ 150 MB. Fine
/// against the avatar's ~4 GB resident set; we don't bother
/// compressing.
final class IdleFrameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CGImage] = []
    private var index = 0
    private var direction = 1
    /// Bumped on every `reset()`. The producer captures the epoch
    /// BEFORE calling `generateIdleChunk()` and passes it back to
    /// `absorb(_:epoch:)`; absorb drops frames whose epoch is
    /// stale. This closes the race where:
    ///   1. Producer is mid-`generateIdleChunk` (~600 ms) using the
    ///      OLD identity.
    ///   2. User picks a new agent → `reset()` runs, frames cleared.
    ///   3. Producer's in-flight call returns with OLD frames.
    ///   4. Without epoch guard, those OLD frames absorb into the
    ///      fresh cache and the palindrome loops them forever — the
    ///      bug the user reported as "after switching agents the
    ///      old idle motion keeps playing".
    private var epoch: Int = 0

    /// 10 s @ 25 FPS. Tuneable: bigger = smoother loop but slower
    /// fill + more memory; smaller = noticeable repetition.
    static let targetCount = 250

    /// True once we've collected enough frames to start replaying.
    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return frames.count >= Self.targetCount
    }

    /// Current frame count (0 → `targetCount`). Drives the
    /// pre-chat splash progress bar so the user sees the agent
    /// "warming up" instead of staring at a static placeholder.
    var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    /// Read the current epoch. Producer captures this immediately
    /// before kicking off `generateIdleChunk` and hands it back to
    /// `absorb`; the cache rejects stale generations.
    var currentEpoch: Int {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }

    /// Snapshot the current frames so callers can persist them to
    /// disk after prewarm completes.
    func snapshot() -> [CGImage] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    /// Take frames from a freshly-generated idle chunk, up to the
    /// target count. Drops the frames if the epoch has rolled (the
    /// cache was reset between the producer's snapshot and now).
    func absorb(_ newFrames: [CGImage], epoch: Int) {
        lock.lock(); defer { lock.unlock() }
        guard epoch == self.epoch else { return }
        let room = Self.targetCount - frames.count
        guard room > 0 else { return }
        frames.append(contentsOf: newFrames.prefix(room))
    }

    /// Pop the next palindrome-looped frame. Nil only if the cache
    /// is somehow empty (shouldn't happen post-`isReady`).
    func next() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        let frame = frames[index]
        if frames.count >= 2 {
            // Bounce between 0 and frames.count - 1.
            let nextIndex = index + direction
            if nextIndex < 0 || nextIndex >= frames.count {
                direction = -direction
                index += direction
            } else {
                index = nextIndex
            }
        }
        return frame
    }

    /// Clear the cache and bump the epoch so any in-flight
    /// producer-side `generateIdleChunk` can't slip stale frames
    /// back in. Call after a portrait swap since the new face has
    /// different breathing motion.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        frames.removeAll(keepingCapacity: true)
        index = 0
        direction = 1
        epoch &+= 1
    }
}
