/// Converts MLX video tensors into CGImages for display.
///
/// Performance-critical: MLX's `.transposed()` produces a strided view whose
/// `asData(access: .copy)` readback runs a pure-Swift per-element iterator
/// (see MLXArray+Bytes.swift) — 14M elements → multi-second stalls. We keep
/// the GPU output in its native CHW contiguous layout and interleave channels
/// on the CPU with Accelerate's vImage, which is ~10,000x faster.

import Accelerate
import CoreGraphics
import Foundation
@_implementationOnly import MLX

internal enum FrameConverter {
    /// Convert VAE output `[1, 3, T, H, W]` in [-1, 1] to CGImages.
    ///
    /// - Parameters:
    ///   - video: MLXArray with shape `[1, 3, T, H, W]`, float range `[-1, 1]`.
    ///   - startFrame: Number of leading frames to drop (used to skip motion-overlap
    ///     frames from chunks after the first).
    internal static func videoToImages(_ video: MLXArray, startFrame: Int = 0) -> [CGImage] {
        precondition(video.ndim == 5 && video.dim(0) == 1 && video.dim(1) == 3,
                     "Expected video shape [1, 3, T, H, W]")

        let totalFrames = video.dim(2)
        let h = video.dim(3)
        let w = video.dim(4)
        let frameCount = max(0, totalFrames - startFrame)
        guard frameCount > 0 else { return [] }

        let profile = ProcessInfo.processInfo.environment["FH_PROFILE_RENDER"] != nil
        let t0 = CFAbsoluteTimeGetCurrent()

        // Scale [-1, 1] → [0, 255] uint8 on GPU. Shape stays [1, 3, T, H, W],
        // which is contiguous in native C order — no transpose required.
        let scaled = MLX.clip((video + 1.0) * 127.5, min: 0.0, max: 255.0)
            .asType(.uint8)
            .squeezed(axis: 0)                              // [3, T, H, W]
        MLX.eval(scaled)
        let t1 = CFAbsoluteTimeGetCurrent()

        let blob = scaled.asData(access: .copy).data
        let t2 = CFAbsoluteTimeGetCurrent()

        let hw = h * w
        let planeStride = totalFrames * hw       // one color plane = T * H * W bytes
        let bytesPerFrame = hw * 3
        let bytesPerRow = w * 3

        var images: [CGImage] = []
        images.reserveCapacity(frameCount)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        blob.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            for i in 0..<frameCount {
                let t = startFrame + i
                let rOffset = 0 * planeStride + t * hw
                let gOffset = 1 * planeStride + t * hw
                let bOffset = 2 * planeStride + t * hw

                // Allocate a fresh contiguous RGB buffer for this frame. Ownership
                // is transferred to a CFData-backed CGDataProvider so the CGImage
                // can reference it without copying.
                let rgb = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerFrame)

                var rPlane = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: base + rOffset),
                    height: vImagePixelCount(h),
                    width: vImagePixelCount(w),
                    rowBytes: w)
                var gPlane = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: base + gOffset),
                    height: vImagePixelCount(h),
                    width: vImagePixelCount(w),
                    rowBytes: w)
                var bPlane = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: base + bOffset),
                    height: vImagePixelCount(h),
                    width: vImagePixelCount(w),
                    rowBytes: w)
                var rgbBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(rgb),
                    height: vImagePixelCount(h),
                    width: vImagePixelCount(w),
                    rowBytes: bytesPerRow)

                let err = vImageConvert_Planar8toRGB888(
                    &rPlane, &gPlane, &bPlane, &rgbBuf,
                    vImage_Flags(kvImageNoFlags))
                guard err == kvImageNoError else {
                    rgb.deallocate()
                    continue
                }

                // Hand buffer lifetime to CGDataProvider via release callback.
                let cfData = CFDataCreateWithBytesNoCopy(
                    nil, rgb, bytesPerFrame,
                    kCFAllocatorDefault) // default dealloc = free()
                guard let data = cfData,
                      let provider = CGDataProvider(data: data) else {
                    rgb.deallocate()
                    continue
                }
                if let image = CGImage(
                    width: w, height: h,
                    bitsPerComponent: 8, bitsPerPixel: 24,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo,
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                ) {
                    images.append(image)
                }
            }
        }
        let t3 = CFAbsoluteTimeGetCurrent()

        if profile {
            print(String(format: "  [FrameConverter] mlx=%.1fms toData=%.1fms cg=%.1fms total=%.1fms (%d frames)",
                         (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000,
                         (t3 - t0) * 1000, frameCount))
        }
        return images
    }
}
