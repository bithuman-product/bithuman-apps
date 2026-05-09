/// Convert a source image on disk into the `[1, 3, FRAME_NUM, H, W]` MLX
/// tensor expected by `LTXVideoEncoder`.
///
/// Pipeline:
///   1. Decode → CGImage
///   2. Detect the face with Apple Vision (`VNDetectFaceRectanglesRequest`).
///      If found, expand the face bounding box by a fixed margin (to
///      include hair/chin/shoulders), snap to a square, and clamp to the
///      image bounds.
///   3. Crop the original pixels to that square — preserving the real
///      pixel aspect ratio inside the crop so the avatar is not stretched.
///      If no face is detected, fall back to a center-square crop.
///   4. Aspect-correct resize the square crop to `resolution × resolution`
///      via a `CGContext.draw(in:)`. Because the source is already square,
///      this resize preserves aspect ratio automatically.
///   5. Convert to float32 RGB in `[-1, 1]`, rearrange to `[3, H, W]` CHW,
///      tile temporally to `FRAME_NUM` copies, add batch dim.
///
/// The face-aware crop is what the platform's expression-avatar service
/// (and the Python FlashHead pipeline) use — feeding a stretched face to
/// the VAE gives distorted latents and broken lipsync geometry.

import Accelerate
import CoreGraphics
import Foundation
@_implementationOnly import MLX
import Vision

internal enum ImagePreprocessError: Error {
    case decodeFailed(URL)
    case unsupportedImage
}

internal enum ImagePreprocess {
    internal static func loadReferenceVideo(
        from url: URL,
        resolution: Int = 384,
        frameCount: Int = FRAME_NUM
    ) throws -> MLXArray {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            throw ImagePreprocessError.decodeFailed(url)
        }
        return try makeReferenceVideo(from: cg,
                                      resolution: resolution,
                                      frameCount: frameCount)
    }

    /// Run the same face-aware crop that `loadReferenceVideo`
    /// uses internally, but stop after the cropping step and
    /// return the resulting `CGImage`. Callers that need a
    /// preview thumbnail with the *exact* framing the DiT will
    /// eventually render should use this instead of running
    /// their own cropper — that way preview and live output
    /// agree pixel-for-pixel.
    internal static func referenceCrop(from cg: CGImage) -> CGImage? {
        let rect = faceAwareCropRect(cg: cg)
        return cg.cropping(to: rect)
    }

    /// Convenience overload that decodes the image at `url`
    /// and runs `referenceCrop(from: CGImage)` on the result.
    internal static func referenceCrop(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return referenceCrop(from: cg)
    }

    internal static func makeReferenceVideo(
        from cg: CGImage,
        resolution: Int = 384,
        frameCount: Int = FRAME_NUM
    ) throws -> MLXArray {
        // Step 1+2: locate the face, compute a square crop around it.
        let sourceSquare = faceAwareCropRect(cg: cg)

        // Step 3+4: draw the cropped square into a resolution×resolution
        // RGBA context. CGContext.draw(_:in:) handles the high-quality
        // resample; passing the (crop-aware) source rect via a cropped
        // sub-image guarantees the mapping is square→square, so aspect
        // ratio is preserved.
        guard let cropped = cg.cropping(to: sourceSquare) else {
            throw ImagePreprocessError.unsupportedImage
        }

        let w = resolution
        let h = resolution
        let bytesPerRow = w * 4
        var rgba = [UInt8](repeating: 0, count: h * bytesPerRow)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let ctx = rgba.withUnsafeMutableBytes({ buf -> CGContext? in
            CGContext(
                data: buf.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: info.rawValue)
        }) else {
            throw ImagePreprocessError.unsupportedImage
        }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Step 5: RGBA → three planar float32 buffers in [-1, 1].
        let pixelCount = h * w
        var rPlane = [Float](repeating: 0, count: pixelCount)
        var gPlane = [Float](repeating: 0, count: pixelCount)
        var bPlane = [Float](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            let px = i * 4
            rPlane[i] = (Float(rgba[px + 0]) / 255.0 - 0.5) * 2.0
            gPlane[i] = (Float(rgba[px + 1]) / 255.0 - 0.5) * 2.0
            bPlane[i] = (Float(rgba[px + 2]) / 255.0 - 0.5) * 2.0
        }

        // Build the [1, 3, F, H, W] tensor by tiling each plane F times.
        var chw = [Float](repeating: 0, count: 3 * frameCount * pixelCount)
        for f in 0..<frameCount {
            let rOff = (0 * frameCount + f) * pixelCount
            let gOff = (1 * frameCount + f) * pixelCount
            let bOff = (2 * frameCount + f) * pixelCount
            rPlane.withUnsafeBufferPointer { ptr in
                chw.withUnsafeMutableBufferPointer { dst in
                    (dst.baseAddress! + rOff).update(from: ptr.baseAddress!, count: pixelCount)
                }
            }
            gPlane.withUnsafeBufferPointer { ptr in
                chw.withUnsafeMutableBufferPointer { dst in
                    (dst.baseAddress! + gOff).update(from: ptr.baseAddress!, count: pixelCount)
                }
            }
            bPlane.withUnsafeBufferPointer { ptr in
                chw.withUnsafeMutableBufferPointer { dst in
                    (dst.baseAddress! + bOff).update(from: ptr.baseAddress!, count: pixelCount)
                }
            }
        }
        return MLXArray(chw, [1, 3, frameCount, h, w])
    }

    // MARK: - Face detection

    /// Return a square `CGRect` in the source image's pixel coordinates
    /// (top-left origin) that frames the primary face with enough context
    /// for the head/shoulders. Falls back to a center-square crop if
    /// Vision finds no face.
    ///
    /// The margin (`faceContextPadding`) expands the detected face box by
    /// roughly 60% on each side before snapping to a square. This matches
    /// the framing the Python FlashHead pipeline expects — a headshot
    /// with some shoulder area visible — and keeps the LTX VAE encoder
    /// producing proportionally correct latents.
    private static func faceAwareCropRect(cg: CGImage) -> CGRect {
        let imgW = CGFloat(cg.width)
        let imgH = CGFloat(cg.height)

        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
        } catch {
            engineLog("[ImagePreprocess] Vision face detection failed: \(error)")
            return centerSquare(width: imgW, height: imgH)
        }

        guard let faces = request.results, !faces.isEmpty else {
            engineLog("[ImagePreprocess] No face detected — using center crop")
            return centerSquare(width: imgW, height: imgH)
        }

        // Vision uses normalized [0,1] coordinates with bottom-left origin.
        // Flip Y to match CG pixel coordinates (top-left origin).
        let face = faces.max(by: {
            ($0.boundingBox.width * $0.boundingBox.height)
                < ($1.boundingBox.width * $1.boundingBox.height)
        })!
        let bb = face.boundingBox
        let faceX = bb.origin.x * imgW
        let faceY = (1.0 - bb.origin.y - bb.height) * imgH
        let faceW = bb.width * imgW
        let faceH = bb.height * imgH
        let faceCenterX = faceX + faceW / 2
        let faceCenterY = faceY + faceH / 2

        // Expand the face box to include hair + some shoulder context.
        // 1.8× the max face dimension feels right for a 3/4 headshot.
        let contextSide = max(faceW, faceH) * 1.8
        // Slide the crop window UP (smaller y in top-left coords) so
        // the face sits in the lower-middle of the crop and the hair
        // / top of the head stay in frame. Without this nudge, Vision's
        // face bounding box stops at the eyebrows and the resulting
        // crop clips the forehead and hairline against the upper edge.
        let yNudge = -faceH * 0.20
        var x = faceCenterX - contextSide / 2
        var y = faceCenterY - contextSide / 2 + yNudge
        var side = contextSide

        // If the expanded box escapes the image, shrink until it fits
        // while keeping the face center inside the crop.
        if side > min(imgW, imgH) {
            side = min(imgW, imgH)
            x = faceCenterX - side / 2
            y = faceCenterY - side / 2 + yNudge
        }
        // Clamp to image bounds.
        x = max(0, min(imgW - side, x))
        y = max(0, min(imgH - side, y))

        engineLog(String(format: "[ImagePreprocess] face bb=(%.0f,%.0f,%.0fx%.0f) crop=(%.0f,%.0f,%.0f)",
                         faceX, faceY, faceW, faceH, x, y, side))
        return CGRect(x: x, y: y, width: side, height: side)
    }

    private static func centerSquare(width w: CGFloat, height h: CGFloat) -> CGRect {
        let side = min(w, h)
        return CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
    }
}
