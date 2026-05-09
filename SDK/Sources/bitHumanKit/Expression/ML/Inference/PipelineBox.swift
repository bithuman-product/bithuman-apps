import Foundation

/// Nonisolated, `@unchecked Sendable` box that owns the MLX / ANE
/// state (DiT pipeline, VAE decoder, VAE encoder) plus the output
/// chunk queue.
///
/// All pipeline work runs on the serial `queue`, keeping the main
/// actor unblocked. The chunk queue is guarded by an `NSLock` so
/// that the producer (background dispatch) and consumer (display
/// tick on the main actor) can append/dequeue without contention.
///
/// Plumbing. Third-party consumers should prefer
/// ``Bithuman/create(modelPath:)``, which constructs and owns a
/// ``PipelineBox`` internally. Only advanced callers who need to
/// override ``Bithuman/ChunkProcessor``, inject a custom audio
/// stream, or share a pre-loaded pipeline across multiple
/// ``Bithuman`` actors touch this type directly.
///
/// The `public` modifier is preserved because ``ChunkProcessor``,
/// ``PipelineOps/processChunk``, and ``PipelineOps/swapIdentity``
/// all accept a ``PipelineBox`` internally. Not exposed outside the
/// SDK — external consumers drive the pipeline through the
/// ``Bithuman`` actor's public API surface.
internal final class PipelineBox: @unchecked Sendable {

    let queue = DispatchQueue(label: "flashhead.pipeline", qos: .userInitiated)
    /// Separate queue for the ANE decode + FrameConverter stage. In
    /// pipelined mode (FH_PIPELINE_DECODE=1), chunk N's decode runs
    /// here concurrently with chunk N+1's DiT on `queue`. DiT on
    /// Metal GPU and ANE decode on the Neural Engine are independent
    /// silicon — serializing them through one queue wastes
    /// ~130 ms/chunk of parallelism. Dedicated serial queue so
    /// ordering between consecutive decodes is preserved.
    let decodeQueue = DispatchQueue(label: "flashhead.decode", qos: .userInitiated)
    var pipeline: StreamingPipeline?
    var decoder: ANEDecoder?
    var encoder: LTXVideoEncoder?
    var encoderWeightsPath: String?

    private let lock = NSLock()
    private var chunks: [TimedChunk] = []

    init() {}

    func enqueueChunk(_ chunk: TimedChunk) {
        lock.lock()
        chunks.append(chunk)
        lock.unlock()
    }

    func dequeueChunk() -> TimedChunk? {
        lock.lock()
        defer { lock.unlock() }
        return chunks.isEmpty ? nil : chunks.removeFirst()
    }

    func clearChunks() {
        lock.lock()
        chunks.removeAll()
        lock.unlock()
    }

    var chunksEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return chunks.isEmpty
    }

    var chunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunks.count
    }
}
