import Accelerate
import CoreGraphics
import Foundation
import ImageIO

#if canImport(MobileCoreServices)
import MobileCoreServices
#endif

/// Pure-Swift image primitives for the Essence runtime.
///
/// Mirrors the operations in `bithuman/engine/image_ops.py` so that the Swift
/// port produces the exact same uint8 BGR frames as the Python reference.
/// Three categories of work live here:
///
///   1. **Decode** of JPEG / WebP blobs that come out of the patch / base
///      archives. ImageIO covers both formats on macOS 11+ / iOS 14+, so
///      no extra dependency is needed.
///   2. **CGImage <-> raw uint8 BGR bytes** conversions. The pipeline runs
///      in cv2-style BGR (not RGB), so the conversions explicitly swizzle
///      channels rather than relying on a generic RGBA bitmap.
///   3. **Lip patch composition** — the alpha blend that pastes a mouth
///      patch onto a base frame using the face mask as the alpha. The
///      blending formula is bit-exact per byte vs the Python reference; see
///      ``blendFaceRegion(base:patch:mask:width:height:)`` for the
///      important detail.
///
/// Spec: `docs/architecture/essence-algorithm-spec.md` §5 "Lip Patch
/// Composition".
enum EssenceImageOps {

    /// Crop the top-left `dstW × dstH` rectangle out of a BGR uint8
    /// buffer of dimensions `srcW × srcH`. Mirrors Python's
    /// `lip[:roi_h, :roi_w]` slicing in `_blend_numpy` — used in the
    /// lip-patch compose path to truncate (rather than resize) head
    /// crops to face-box dimensions.
    static func cropTopLeftBGR(
        src: [UInt8], srcW: Int, srcH: Int, dstW: Int, dstH: Int
    ) -> [UInt8] {
        precondition(dstW <= srcW && dstH <= srcH,
                     "cropTopLeftBGR: dst (\(dstW)×\(dstH)) larger than src (\(srcW)×\(srcH))")
        if dstW == srcW && dstH == srcH { return src }
        var out = [UInt8](repeating: 0, count: dstW * dstH * 3)
        out.withUnsafeMutableBufferPointer { dstP in
            src.withUnsafeBufferPointer { srcP in
                let dstStride = dstW * 3
                let srcStride = srcW * 3
                for y in 0..<dstH {
                    let srcRow = srcP.baseAddress!.advanced(by: y * srcStride)
                    let dstRow = dstP.baseAddress!.advanced(by: y * dstStride)
                    dstRow.update(from: srcRow, count: dstStride)
                }
            }
        }
        return out
    }

    // MARK: - Errors

    enum Error: Swift.Error, CustomStringConvertible {
        case decodeFailed(format: String)
        case unsupportedImage(reason: String)

        var description: String {
            switch self {
            case .decodeFailed(let format):
                return "EssenceImageOps: failed to decode \(format) blob"
            case .unsupportedImage(let reason):
                return "EssenceImageOps: unsupported image (\(reason))"
            }
        }
    }

    // MARK: - Decode

    /// Decodes a JPEG blob into a `CGImage` using ImageIO.
    ///
    /// - Parameter data: Raw JPEG bytes (not the XOR-encrypted archive
    ///   form — callers are expected to have decrypted upstream).
    /// - Throws: ``Error/decodeFailed(format:)`` if ImageIO can't parse the
    ///   blob.
    static func decodeJPEG(_ data: Data) throws -> CGImage {
        try decode(data, label: "JPEG")
    }

    /// Decodes a WebP blob into a `CGImage` using ImageIO.
    ///
    /// ImageIO ships a built-in WebP decoder on macOS 11+ and iOS 14+, so
    /// the implementation is the same code path as ``decodeJPEG(_:)``;
    /// `CGImageSource` sniffs the format from the bytes.
    static func decodeWebP(_ data: Data) throws -> CGImage {
        try decode(data, label: "WebP")
    }

    private static func decode(_ data: Data, label: String) throws -> CGImage {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw Error.decodeFailed(format: label)
        }
        return image
    }

    // MARK: - CGImage → Planar8 grayscale

    /// Renders `image` into a tightly packed `width * height` byte
    /// buffer of 8-bit luminance. Used for the face masks (which the
    /// pre-v0.18.15 path stored as 3-channel BGR with R==G==B per
    /// pixel — verified across the v2 corpus). Saves 2/3 of the per-
    /// frame mask memory; the blend kernel reads one mask byte per
    /// BGR pixel and broadcasts to the 3 colour channels.
    static func cgImageToGrayscaleBytes(_ image: CGImage) -> Data {
        let width = image.width
        let height = image.height
        let bytesPerRow = width
        var gray = Data(count: bytesPerRow * height)
        let cs = CGColorSpaceCreateDeviceGray()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.none.rawValue
        let _ = gray.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress,
                width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: cs,
                bitmapInfo: bitmapInfo
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return gray
    }

    // MARK: - CGImage <-> BGR bytes

    /// Renders `image` into a tightly packed `width * height * 3` byte
    /// buffer ordered BGR (B,G,R, B,G,R, ...).
    ///
    /// Why BGR and not RGB: the Python reference uses OpenCV (`cv2`),
    /// which stores BGR by default. The patches and bases on disk were
    /// authored against that convention, so this Swift port has to match.
    static func cgImageToBGRBytes(_ image: CGImage) -> Data {
        let width = image.width
        let height = image.height

        // v0.18.8: vImage SIMD path replaces the previous CGContext +
        // scalar Swift swizzle (~316 µs / 225×329 patch on M5). Step 1
        // pulls the CGImage into an RGB888 vImage_Buffer via
        // `vImageBuffer_InitWithCGImage` (~150 µs — handles JPEG-YCbCr,
        // WebP, and already-RGB sources uniformly with CG's color
        // pipeline). Step 2 swaps R/B in place via
        // `vImagePermuteChannels_RGB888` (~30 µs — NEON gather/scatter,
        // 16 pixels per cycle). Net: ~180 µs / patch, 1.7× faster than
        // the CGContext path.
        var srcFmt = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            colorSpace: Unmanaged.passUnretained(
                image.colorSpace
                    ?? CGColorSpace(name: CGColorSpace.sRGB)
                    ?? CGColorSpaceCreateDeviceRGB()
            ),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        var rgbBuf = vImage_Buffer()
        let initErr = vImageBuffer_InitWithCGImage(
            &rgbBuf, &srcFmt, nil, image, vImage_Flags(kvImageNoFlags)
        )
        guard initErr == kvImageNoError, let rgbBase = rgbBuf.data else {
            return Data()
        }
        defer { free(rgbBuf.data) }

        // Permute R/B channels in place: input (R,G,B) → (B,G,R).
        var permute: [UInt8] = [2, 1, 0]
        let permErr = vImagePermuteChannels_RGB888(
            &rgbBuf, &rgbBuf, &permute, vImage_Flags(kvImageNoFlags)
        )
        guard permErr == kvImageNoError else { return Data() }

        // Copy out as a tightly-packed BGR Data buffer. vImage's
        // `rowBytes` may exceed `width * 3` due to alignment — pack
        // row-by-row so callers see a contiguous bgr buffer.
        let outBytes = width * height * 3
        var bgr = Data(count: outBytes)
        let stride = rgbBuf.rowBytes
        let src = rgbBase.assumingMemoryBound(to: UInt8.self)
        bgr.withUnsafeMutableBytes { dst in
            let dstPtr = dst.bindMemory(to: UInt8.self).baseAddress!
            if stride == width * 3 {
                memcpy(dstPtr, src, outBytes)
            } else {
                for y in 0..<height {
                    memcpy(dstPtr.advanced(by: y * width * 3),
                           src.advanced(by: y * stride),
                           width * 3)
                }
            }
        }
        return bgr
    }

    /// Rebuilds a `CGImage` from a tightly-packed BGR byte buffer.
    ///
    /// The implementation goes BGR -> RGBA on the way out (CoreGraphics
    /// has no native BGR888 bitmap layout) and lets CG own the pixel
    /// memory via a `CFData` provider, so the returned image is
    /// independent of the input pointer's lifetime.
    static func bgrBytesToCGImage(
        _ bytes: UnsafePointer<UInt8>,
        width: Int,
        height: Int
    ) -> CGImage? {
        // v0.18.7: single-pass BGR→RGB swap via
        // `vImagePermuteChannels_RGB888`, then build a 24-bit
        // CGImage directly. Replaces the previous 2-pass path
        // (RGB888→ARGB8888 pad + permute back to ARGB) which spent
        // ~320 µs per 1280×722 frame on the pad alone. The 24-bit
        // CGImage path is supported by Core Graphics on every modern
        // Apple platform; the consumers in this codebase (`AvatarWindow`
        // / `AvatarRendererView` CALayer.contents) accept any CGImage
        // bit depth, so dropping the unused alpha pad is a free
        // simplification.
        let bytesPerRow = width * 3
        let byteCount = bytesPerRow * height
        var rgb = [UInt8](repeating: 0, count: byteCount)
        let permuteOK: vImage_Error = rgb.withUnsafeMutableBufferPointer { dst in
            var srcBuf = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: bytes),
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: bytesPerRow
            )
            var dstBuf = vImage_Buffer(
                data: dst.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: bytesPerRow
            )
            var permute: [UInt8] = [2, 1, 0]
            return vImagePermuteChannels_RGB888(
                &srcBuf, &dstBuf, &permute, vImage_Flags(kvImageNoFlags)
            )
        }
        guard permuteOK == kvImageNoError else { return nil }
        guard let provider = CGDataProvider(data: Data(rgb) as CFData) else {
            return nil
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: bytesPerRow,
            space: cs, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: - Lip patch composition

    /// Bit-exact div-by-255 approximation, matching the Python reference.
    ///
    /// Formula: `(x + 1 + ((x + 1) >> 8)) >> 8`. This is **not** the same
    /// as `x / 255` — for inputs like 38200 (mask=128 50/50 blend) the
    /// two differ by 1, which is enough to break byte-equivalence with
    /// the cross-SDK fixtures.
    @inline(__always)
    static func div255(_ x: UInt32) -> UInt8 {
        let y = x &+ 1
        return UInt8(truncatingIfNeeded: (y &+ (y >> 8)) >> 8)
    }

    /// Composes a mouth patch onto a base face crop, in place.
    ///
    /// All three buffers must describe the same `width * height` rectangle
    /// in tightly packed uint8 BGR layout — `base` is the face crop from
    /// the base frame at `[y1:y2, x1:x2]`, `patch` is the mouth patch
    /// straight from the patches archive, and `mask` is the per-pixel
    /// alpha (single-channel replicated to 3 channels, or a real 3-channel
    /// mask — both work identically as long as the byte layout matches).
    ///
    /// Per byte, the operation is:
    /// ```
    /// out = div255(patch * mask + base * (255 - mask))
    /// ```
    ///
    /// **Why a hand-rolled scalar loop instead of vImage:**
    /// `vImageAlphaBlend_ARGB8888` is the obvious candidate, but its
    /// internal rounding is `(s * a + d * (255 - a) + 127) / 255` (round-
    /// to-nearest), whereas the bit-shift formula here is the
    /// `(x + 1 + (x+1)>>8) >> 8` approximation OpenCV uses. The two
    /// disagree by 1 on a non-trivial fraction of bytes (specifically,
    /// inputs where `x % 255` falls in [128, 254]), and that 1-LSB delta
    /// breaks byte-equivalence with Python-rendered fixtures used to
    /// pin-test the lip-sync output. The scalar path is fast enough at
    /// our crop sizes (~64x64 mouth region * 3 channels = 12 KB per
    /// frame) that the extra cycles vs SIMD are not the bottleneck.
    static func blendFaceRegion(
        base: inout [UInt8],
        patch: [UInt8],
        mask: [UInt8],
        width: Int,
        height: Int
    ) {
        let count = width * height * 3
        precondition(base.count == count, "base buffer size mismatch")
        precondition(patch.count == count, "patch buffer size mismatch")
        precondition(mask.count == count, "mask buffer size mismatch")

        base.withUnsafeMutableBufferPointer { basePtr in
            patch.withUnsafeBufferPointer { patchPtr in
                mask.withUnsafeBufferPointer { maskPtr in
                    blendBytes(basePtr.baseAddress!, patchPtr.baseAddress!,
                               maskPtr.baseAddress!, count: count)
                }
            }
        }
    }

    /// In-place SIMD-vectorized alpha blend of a `(w × h)` lip patch
    /// into the `(x, y)` region of a tightly-packed `(frameW × frameH)`
    /// BGR uint8 frame buffer, using `mask` as the per-byte alpha.
    ///
    /// Equivalent to:
    /// ```
    /// for row in 0..<h:
    ///     for col in 0..<w:
    ///         frame[(y+row, x+col)] = div255(
    ///             patch[(row, col)] * mask[(row, col)]
    ///             + frame[(y+row, x+col)] * (255 - mask[(row, col)])
    ///         )
    /// ```
    /// but issues one `SIMD16<UInt16>` multiply-and-add per 16 bytes,
    /// processing the row in ~1 cycle per 16 pixel-bytes. The previous
    /// implementation went `extractRegion → blend → writeRegion`,
    /// allocating + copying the face region twice; this version
    /// mutates the frame buffer directly. Saves ~0.3 ms per call on a
    /// 60×60 face region.
    static func blendFaceRegionInPlace(
        frame: inout [UInt8],
        frameW: Int, frameH: Int,
        patch: [UInt8], mask: [UInt8],
        x: Int, y: Int, w: Int, h: Int
    ) {
        precondition(patch.count == w * h * 3, "patch size mismatch")
        // v0.18.15: callers store the mask as 1-channel grayscale to
        // save 2/3 of per-instance memory (~28 MB on the demo fixture);
        // expand to 3-channel BGR right before the blend so the
        // tightly-tuned byte-level SIMD kernel below sees contiguous
        // memory. The expansion is a single vImage broadcast pass —
        // ~5–10 µs / call on a 225×329 mask, well under the savings
        // from not strided-reading a 1-channel mask in the kernel.
        precondition(mask.count == w * h, "mask size mismatch (expected w*h grayscale)")
        let mask3 = grayscaleToBGRBroadcast(mask, w: w, h: h)
        // Clip region to frame bounds (defensive — face_coords have
        // come back > frame in unusual fixtures).
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(frameW, x + w), y1 = min(frameH, y + h)
        let clipW = x1 - x0, clipH = y1 - y0
        guard clipW > 0, clipH > 0 else { return }
        let rowBytes = w * 3
        let frameRowBytes = frameW * 3
        let xOffset = (x0 - x) * 3
        let yOffset = (y0 - y)

        frame.withUnsafeMutableBufferPointer { fp in
            patch.withUnsafeBufferPointer { pp in
                mask3.withUnsafeBufferPointer { mp in
                    let f = fp.baseAddress!, p = pp.baseAddress!, m = mp.baseAddress!
                    for row in 0..<clipH {
                        let frameOff = (y0 + row) * frameRowBytes + x0 * 3
                        let patchOff = (yOffset + row) * rowBytes + xOffset
                        blendBytes(
                            f.advanced(by: frameOff),
                            p.advanced(by: patchOff),
                            m.advanced(by: patchOff),
                            count: clipW * 3
                        )
                    }
                }
            }
        }
    }

    /// Broadcast a `(w × h)` 1-channel grayscale mask to a tightly-
    /// packed `(w × h × 3)` BGR buffer where each pixel's R, G, B
    /// bytes equal the source mask byte. Used by
    /// `blendFaceRegionInPlace` to feed the byte-level SIMD kernel
    /// from grayscale storage.
    @inline(__always)
    private static func grayscaleToBGRBroadcast(_ src: [UInt8], w: Int, h: Int) -> [UInt8] {
        let n = w * h
        var dst = [UInt8](repeating: 0, count: n * 3)
        // SIMD16 broadcast: load 16 grayscale bytes, store 48 BGR
        // bytes (each grayscale byte replicated 3×). Tail in scalar.
        src.withUnsafeBufferPointer { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                let s = sp.baseAddress!, d = dp.baseAddress!
                var i = 0
                let block = n - (n % 16)
                while i < block {
                    var v = SIMD16<UInt8>()
                    for j in 0..<16 { v[j] = s[i + j] }
                    for j in 0..<16 {
                        let off = (i + j) * 3
                        let b = v[j]
                        d[off] = b; d[off + 1] = b; d[off + 2] = b
                    }
                    i &+= 16
                }
                while i < n {
                    let b = s[i], off = i * 3
                    d[off] = b; d[off + 1] = b; d[off + 2] = b
                    i &+= 1
                }
            }
        }
        return dst
    }

    /// SIMD-vectorized core: for each byte i, compute
    ///   base[i] = div255(patch[i] * mask[i] + base[i] * (255 - mask[i])).
    /// Processes 16 bytes per iteration via `SIMD16<UInt16>` multiplies
    /// — Apple Silicon NEON dispatches the multiply-add as one
    /// instruction per lane, so the inner loop is throughput-bound on
    /// L1 reads. Falls back to a scalar tail for the last <16 bytes.
    @inline(__always)
    private static func blendBytes(
        _ base: UnsafeMutablePointer<UInt8>,
        _ patch: UnsafePointer<UInt8>,
        _ mask: UnsafePointer<UInt8>,
        count: Int
    ) {
        var i = 0
        let blockEnd = count - (count % 16)
        while i < blockEnd {
            var bv = SIMD16<UInt16>()
            var pv = SIMD16<UInt16>()
            var mv = SIMD16<UInt16>()
            for j in 0..<16 {
                bv[j] = UInt16(base[i + j])
                pv[j] = UInt16(patch[i + j])
                mv[j] = UInt16(mask[i + j])
            }
            let inv = SIMD16<UInt16>(repeating: 255) &- mv
            let acc = pv &* mv &+ bv &* inv
            let y = acc &+ SIMD16<UInt16>(repeating: 1)
            let result = (y &+ (y &>> SIMD16<UInt16>(repeating: 8)))
                &>> SIMD16<UInt16>(repeating: 8)
            for j in 0..<16 {
                base[i + j] = UInt8(truncatingIfNeeded: result[j])
            }
            i &+= 16
        }
        while i < count {
            let mvb = UInt32(mask[i])
            let acc = UInt32(patch[i]) &* mvb
                &+ UInt32(base[i]) &* (255 &- mvb)
            base[i] = div255(acc)
            i &+= 1
        }
    }

    // MARK: - Grayscale uint8 bilinear resize

    /// Bilinear resize of a tightly-packed `width * height` grayscale
    /// uint8 buffer via Accelerate's `vImageScale_Planar8`. Used for
    /// the 1-channel face masks introduced in v0.18.15. Returns the
    /// input unchanged when sizes match.
    static func bilinearResizeGrayscale(
        src: [UInt8],
        srcW: Int, srcH: Int, dstW: Int, dstH: Int
    ) -> [UInt8] {
        precondition(src.count == srcW * srcH, "src grayscale size mismatch")
        if srcW == dstW && srcH == dstH { return src }
        var dst = [UInt8](repeating: 0, count: dstW * dstH)
        let ok: vImage_Error = src.withUnsafeBufferPointer { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                var sb = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sp.baseAddress!),
                    height: vImagePixelCount(srcH), width: vImagePixelCount(srcW),
                    rowBytes: srcW
                )
                var db = vImage_Buffer(
                    data: dp.baseAddress, height: vImagePixelCount(dstH),
                    width: vImagePixelCount(dstW), rowBytes: dstW
                )
                return vImageScale_Planar8(&sb, &db, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        if ok != kvImageNoError {
            // Fallback to scalar bilinear — reuses the per-channel
            // grayscale interpolation logic below.
            return scalarBilinearGrayscale(src: src, srcW: srcW, srcH: srcH,
                                            dstW: dstW, dstH: dstH)
        }
        return dst
    }

    /// Scalar bilinear grayscale resize (fallback for the very rare
    /// case `vImageScale_Planar8` errors out — e.g., alignment quirks
    /// on a non-canonical Apple Silicon SKU).
    private static func scalarBilinearGrayscale(
        src: [UInt8], srcW: Int, srcH: Int, dstW: Int, dstH: Int
    ) -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: dstW * dstH)
        let xScale = Double(srcW) / Double(dstW)
        let yScale = Double(srcH) / Double(dstH)
        for y in 0..<dstH {
            let srcY = (Double(y) + 0.5) * yScale - 0.5
            let y0 = max(0, min(srcH - 1, Int(srcY.rounded(.down))))
            let y1 = max(0, min(srcH - 1, y0 + 1))
            let dy = max(0.0, min(1.0, srcY - Double(y0)))
            for x in 0..<dstW {
                let srcX = (Double(x) + 0.5) * xScale - 0.5
                let x0 = max(0, min(srcW - 1, Int(srcX.rounded(.down))))
                let x1 = max(0, min(srcW - 1, x0 + 1))
                let dx = max(0.0, min(1.0, srcX - Double(x0)))
                let p00 = Double(src[y0 * srcW + x0])
                let p01 = Double(src[y0 * srcW + x1])
                let p10 = Double(src[y1 * srcW + x0])
                let p11 = Double(src[y1 * srcW + x1])
                let top = p00 + (p01 - p00) * dx
                let bot = p10 + (p11 - p10) * dx
                dst[y * dstW + x] = UInt8(max(0, min(255, (top + (bot - top) * dy).rounded())))
            }
        }
        return dst
    }

    // MARK: - BGR uint8 bilinear resize

    /// Bilinear resize of a tightly packed `width * height * 3` BGR uint8
    /// buffer to (`dstW`, `dstH`). De-interleaves into 3 planar uint8
    /// buffers, runs `vImageScale_Planar8` (Accelerate's SIMD bilinear),
    /// and re-interleaves. Per-channel single-plane resize avoids the
    /// premultiplication round-trip in `vImageScale_ARGB8888` that was
    /// the source of edge brightening when CG drew an RGBA source into a
    /// premultipliedFirst layout.
    ///
    /// Bit-equivalent to `cv2.resize(src, (dstW, dstH), INTER_LINEAR)`
    /// within ±1 LSB on the cross-SDK fixtures.
    static func bilinearResizeBGR(
        src: [UInt8],
        srcW: Int,
        srcH: Int,
        dstW: Int,
        dstH: Int
    ) -> [UInt8] {
        precondition(src.count == srcW * srcH * 3, "src size mismatch")
        if srcW == dstW && srcH == dstH {
            return src
        }
        let nSrc = srcW * srcH
        let nDst = dstW * dstH

        // Pad BGR→BGRX with vImage SIMD, scale once via the
        // 4-channel resampler, then strip the unused channel back to
        // BGR. One ARGB resample pass replaces the 3 planar passes
        // and the de/re-interleave shuffles, ~2× faster on large
        // (1280×722-class) buffers. Alpha is set to a constant 0xFF
        // and never modified by the bilinear filter (constants
        // interpolate to themselves), so no premul/unpremul rounding
        // can sneak in like it did with `vImageScale_ARGB8888` on
        // CG-decoded sources.
        var srcBGRA = [UInt8](repeating: 0, count: nSrc * 4)
        let convOK: vImage_Error = src.withUnsafeBufferPointer { sp in
            srcBGRA.withUnsafeMutableBufferPointer { dp in
                var sb = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sp.baseAddress!),
                    height: vImagePixelCount(srcH),
                    width: vImagePixelCount(srcW),
                    rowBytes: srcW * 3
                )
                var db = vImage_Buffer(
                    data: dp.baseAddress,
                    height: vImagePixelCount(srcH),
                    width: vImagePixelCount(srcW),
                    rowBytes: srcW * 4
                )
                return vImageConvert_RGB888toARGB8888(
                    &sb, nil, 0xFF, &db, false, vImage_Flags(kvImageNoFlags)
                )
            }
        }
        if convOK != kvImageNoError {
            // Fallback to the slower planar path on any unexpected
            // vImage failure.
            return bilinearResizeBGRPlanar(
                src: src, srcW: srcW, srcH: srcH, dstW: dstW, dstH: dstH
            )
        }

        var dstBGRA = [UInt8](repeating: 0, count: nDst * 4)
        let scaleOK: vImage_Error = srcBGRA.withUnsafeMutableBufferPointer { sp in
            dstBGRA.withUnsafeMutableBufferPointer { dp in
                var sb = vImage_Buffer(
                    data: sp.baseAddress,
                    height: vImagePixelCount(srcH),
                    width: vImagePixelCount(srcW),
                    rowBytes: srcW * 4
                )
                var db = vImage_Buffer(
                    data: dp.baseAddress,
                    height: vImagePixelCount(dstH),
                    width: vImagePixelCount(dstW),
                    rowBytes: dstW * 4
                )
                return vImageScale_ARGB8888(&sb, &db, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        if scaleOK != kvImageNoError {
            return bilinearResizeBGRPlanar(
                src: src, srcW: srcW, srcH: srcH, dstW: dstW, dstH: dstH
            )
        }

        // Strip ARGB → RGB via vImage SIMD. Our scaled buffer's actual
        // memory layout (after `vImageConvert_RGB888toARGB8888` was
        // fed BGR-as-RGB) is (A, B, G, R) per pixel.
        // `vImageConvert_ARGB8888toRGB888` drops the leading byte (A),
        // outputting (B, G, R) — exactly the BGR triplet we want.
        var dst = [UInt8](repeating: 0, count: nDst * 3)
        let stripOK: vImage_Error = dstBGRA.withUnsafeMutableBufferPointer { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                var sb = vImage_Buffer(
                    data: sp.baseAddress,
                    height: vImagePixelCount(dstH),
                    width: vImagePixelCount(dstW),
                    rowBytes: dstW * 4
                )
                var db = vImage_Buffer(
                    data: dp.baseAddress,
                    height: vImagePixelCount(dstH),
                    width: vImagePixelCount(dstW),
                    rowBytes: dstW * 3
                )
                return vImageConvert_ARGB8888toRGB888(&sb, &db, vImage_Flags(kvImageNoFlags))
            }
        }
        if stripOK != kvImageNoError {
            return bilinearResizeBGRPlanar(
                src: src, srcW: srcW, srcH: srcH, dstW: dstW, dstH: dstH
            )
        }
        return dst
    }

    /// Slower fallback bilinear resize using 3 planar passes. Kept as
    /// a safety net for the unlikely case a vImage convert/scale call
    /// fails (out-of-memory, alignment quirk).
    private static func bilinearResizeBGRPlanar(
        src: [UInt8], srcW: Int, srcH: Int, dstW: Int, dstH: Int
    ) -> [UInt8] {
        let nSrc = srcW * srcH, nDst = dstW * dstH
        var pB = [UInt8](repeating: 0, count: nSrc)
        var pG = [UInt8](repeating: 0, count: nSrc)
        var pR = [UInt8](repeating: 0, count: nSrc)
        src.withUnsafeBufferPointer { sp in
            let s = sp.baseAddress!
            for i in 0..<nSrc {
                let o = i * 3
                pB[i] = s[o]; pG[i] = s[o + 1]; pR[i] = s[o + 2]
            }
        }
        var dB = [UInt8](repeating: 0, count: nDst)
        var dG = [UInt8](repeating: 0, count: nDst)
        var dR = [UInt8](repeating: 0, count: nDst)
        @inline(__always) func scalePlanar(_ s: inout [UInt8], _ d: inout [UInt8]) {
            s.withUnsafeMutableBufferPointer { sp in
                d.withUnsafeMutableBufferPointer { dp in
                    var sb = vImage_Buffer(data: sp.baseAddress,
                        height: vImagePixelCount(srcH), width: vImagePixelCount(srcW),
                        rowBytes: srcW)
                    var db = vImage_Buffer(data: dp.baseAddress,
                        height: vImagePixelCount(dstH), width: vImagePixelCount(dstW),
                        rowBytes: dstW)
                    _ = vImageScale_Planar8(&sb, &db, nil, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        scalePlanar(&pB, &dB); scalePlanar(&pG, &dG); scalePlanar(&pR, &dR)
        var dst = [UInt8](repeating: 0, count: nDst * 3)
        dst.withUnsafeMutableBufferPointer { dp in
            let d = dp.baseAddress!
            for i in 0..<nDst {
                let o = i * 3
                d[o] = dB[i]; d[o + 1] = dG[i]; d[o + 2] = dR[i]
            }
        }
        return dst
    }

    // MARK: - Resize

    /// Resize a `CGImage` to (`width`, `height`).
    ///
    /// Uses a non-premultiplied RGBA8 destination context with CG's
    /// built-in bilinear interpolation (`interpolationQuality = .low`,
    /// which CG documents as bilinear). Drawing into a non-premul layout
    /// avoids the unpremul rounding step at edges that
    /// `vImageScale_ARGB8888` introduces — vImage premultiplies, scales,
    /// and the un-premul on read shifts edge pixels brighter when the
    /// resampler dips alpha below 0xFF. CG bilinear gives byte-stable
    /// values that line up with `cv2.resize(..., INTER_LINEAR)` to
    /// within ±2 LSB across the whole frame, which is what the cross-SDK
    /// fixtures need.
    static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let srcBytesPerRow = width * 4
        var dstBytes = [UInt8](repeating: 0, count: height * srcBytesPerRow)
        // Use the source's own colorspace as the dest so the draw is an
        // identity color transform. See cgImageToBGRBytes for why
        // CGColorSpace(name: .sRGB) and a CGImage's tagged sRGB profile
        // aren't bit-equivalent in CG color matching.
        let cs = image.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        // noneSkipLast = RGBX (alpha byte is undefined and not premultiplied
        // into the color channels). Drawing into this layout means CG
        // never has to premultiply or un-premultiply during the resample.
        let bitmapInfo: UInt32 = CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = dstBytes.withUnsafeMutableBytes({ buf -> CGContext? in
            CGContext(
                data: buf.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: srcBytesPerRow,
                space: cs,
                bitmapInfo: bitmapInfo
            )
        }) else {
            return nil
        }
        ctx.interpolationQuality = .low // CG documents .low as bilinear
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let provider = CGDataProvider(data: Data(dstBytes) as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: srcBytesPerRow,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
