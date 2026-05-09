import CoreGraphics

/// A unit of aligned audio + video ready for playback by the
/// 25 FPS display pipeline.
///
/// Returned by ``Bithuman/tryDequeueChunk()`` and
/// ``Bithuman/generateIdleChunk()``. Consumers iterate
/// ``frames`` on their display tick and schedule ``audio24k``
/// onto their audio player whenever it's non-nil.
///
/// `audio24k == nil` means "idle motion, speakers silent" — the
/// display still advances frames (breathing, lip at rest) while
/// no audio is scheduled. Non-nil means real speech: frames and
/// audio MUST play as a 1:1 pair to preserve A/V sync.
public struct TimedChunk: @unchecked Sendable {

    /// Rendered CG frames, displayed at 25 FPS.
    public let frames: [CGImage]

    /// 24 kHz mono Float32 samples covering exactly the same time
    /// span as ``frames``. `nil` means idle — play the frames
    /// without scheduling any audio.
    public let audio24k: [Float]?

    internal init(frames: [CGImage], audio24k: [Float]?) {
        self.frames = frames
        self.audio24k = audio24k
    }
}
