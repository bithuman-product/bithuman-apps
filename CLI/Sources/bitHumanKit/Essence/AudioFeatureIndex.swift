import Accelerate
import Foundation

/// In-memory KNN index over the cluster centers stored in an Essence
/// `.imx`'s `audio_feature.f32` entry.
///
/// Mirrors the Python reference at `bithuman/engine/knn.py` —
/// `AudioFeatureIndex` — used at runtime to map an ONNX audio
/// embedding to the nearest pre-baked lip-sync cluster.
///
/// ## Distance metric
///
/// Squared Euclidean (matches Python). For the single-embedding hot
/// path we use the algebraic decomposition
///
/// ```text
/// ||c_i − e||² = ||c_i||² − 2·c_i·e + ||e||²
/// ```
///
/// `||e||²` is constant across clusters and so falls out of the
/// argmin — we only need `||c_i||² − 2·c_i·e`. The cluster norms
/// `||c_i||²` are precomputed at init time; the dot products
/// `c_i·e` are produced for every cluster in one BLAS GEMV call.
///
/// ## Tie-break
///
/// `vDSP_minvi` returns the index of the *first* occurrence of the
/// minimum, which matches numpy's `argmin` semantics.
///
/// ## Concurrency
///
/// The cluster matrix and norms are immutable post-init, so
/// `nearestCluster(...)` is thread-safe for concurrent reads.
struct AudioFeatureIndex: Sendable {

    enum Error: Swift.Error, CustomStringConvertible {
        case headerTooSmall(have: Int)
        case bodyTruncated(expected: Int, have: Int)
        case zeroDimension(numClusters: UInt32, embeddingDim: UInt32)
        case embeddingDimMismatch(have: Int, want: Int)

        var description: String {
            switch self {
            case .headerTooSmall(let have):
                return "AudioFeatureIndex: audio_feature.f32 too small for 16-byte header (have \(have))"
            case .bodyTruncated(let expected, let have):
                return "AudioFeatureIndex: audio_feature.f32 body truncated (expected \(expected) bytes, have \(have))"
            case .zeroDimension(let nc, let ed):
                return "AudioFeatureIndex: invalid header dimensions num_clusters=\(nc) embedding_dim=\(ed)"
            case .embeddingDimMismatch(let have, let want):
                return "AudioFeatureIndex: embedding count=\(have) does not match index dim=\(want)"
            }
        }
    }

    /// Number of cluster centers (rows in the feature matrix).
    let numClusters: Int

    /// Per-cluster embedding dimensionality (columns in the feature
    /// matrix). Must match the audio encoder's output dim.
    let embeddingDim: Int

    /// Row-major `numClusters × embeddingDim` float32 cluster
    /// centers. Allocated as a single contiguous buffer so BLAS can
    /// touch it directly.
    private let features: [Float]

    /// Pre-computed `||c_i||²` for each row. Length `numClusters`.
    /// Matches Python's `np.einsum("ij,ij->i", features, features)`.
    private let featuresSq: [Float]

    // MARK: - Init

    /// Read the cluster centers from an `.imx`'s `audio_feature.f32`
    /// entry.
    init(from container: ImxContainer) throws {
        let data = try container.readFile("audio_feature.f32")
        try self.init(rawBytes: data)
    }

    /// Decode a raw `audio_feature.f32` blob (header + body).
    /// Useful for tests that synthesize the byte layout in memory
    /// rather than going through a full `.imx` container.
    init(rawBytes data: Data) throws {
        guard data.count >= 16 else {
            throw Error.headerTooSmall(have: data.count)
        }
        let (numClusters, embeddingDim): (UInt32, UInt32) = data.withUnsafeBytes { raw in
            let nc = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
            let ed = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            // bytes 8..16 are reserved=0 per the spec; we don't
            // strictly validate them — a non-zero reserved field is
            // tolerated for forward compatibility.
            return (nc, ed)
        }
        guard numClusters > 0, embeddingDim > 0 else {
            throw Error.zeroDimension(numClusters: numClusters, embeddingDim: embeddingDim)
        }
        let nc = Int(numClusters)
        let ed = Int(embeddingDim)
        let bodyByteCount = nc * ed * MemoryLayout<Float>.size
        guard data.count >= 16 + bodyByteCount else {
            throw Error.bodyTruncated(expected: 16 + bodyByteCount, have: data.count)
        }

        // Copy the body into a fresh [Float] (safe alignment, owned).
        var features = [Float](repeating: 0, count: nc * ed)
        features.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                let bodySrc = src.baseAddress!.advanced(by: 16)
                memcpy(dst.baseAddress!, bodySrc, bodyByteCount)
            }
        }

        // Precompute per-row squared norms: features_sq[i] = c_i · c_i.
        var featuresSq = [Float](repeating: 0, count: nc)
        features.withUnsafeBufferPointer { fb in
            featuresSq.withUnsafeMutableBufferPointer { sb in
                for i in 0..<nc {
                    let row = fb.baseAddress!.advanced(by: i * ed)
                    var dot: Float = 0
                    vDSP_dotpr(row, 1, row, 1, &dot, vDSP_Length(ed))
                    sb[i] = dot
                }
            }
        }

        self.numClusters = nc
        self.embeddingDim = ed
        self.features = features
        self.featuresSq = featuresSq
    }

    // MARK: - Inference

    /// Squared-Euclidean argmin of `embedding` against the cached
    /// cluster centers.
    ///
    /// Hot path:
    ///   1. `cblas_sgemv` to produce `dots[i] = c_i · embedding`
    ///      for every cluster in one BLAS call.
    ///   2. `vDSP_vsmsa` to compute `featuresSq[i] − 2·dots[i]`
    ///      (the constant `||e||²` term is omitted — it doesn't
    ///      affect argmin).
    ///   3. `vDSP_minvi` for first-occurrence argmin (matches
    ///      numpy's tie-break).
    ///
    /// `embedding` must point to `count == embeddingDim` floats.
    func nearestCluster(embedding: UnsafePointer<Float>, count: Int) -> Int {
        precondition(count == embeddingDim, "embedding count \(count) != index dim \(embeddingDim)")

        let nc = numClusters
        let ed = embeddingDim

        // Step 1: dots = features (nc × ed) · embedding (ed)  →  (nc)
        var dots = [Float](repeating: 0, count: nc)
        features.withUnsafeBufferPointer { fb in
            dots.withUnsafeMutableBufferPointer { db in
                cblas_sgemv(
                    CblasRowMajor, CblasNoTrans,
                    Int32(nc), Int32(ed),
                    1.0,
                    fb.baseAddress, Int32(ed),
                    embedding, 1,
                    0.0,
                    db.baseAddress, 1
                )
            }
        }

        // Step 2: scores[i] = featuresSq[i] − 2·dots[i]
        // vDSP_vsmsa: D[i] = A[i]*scalar1 + scalar2; we want
        // dots[i]*(-2) + featuresSq[i] — but the additive term is a
        // *vector*, not a scalar, so use vDSP_vsma + a copy instead.
        //   scores = featuresSq
        //   scores += dots * (-2)
        var scores = featuresSq
        var negTwo: Float = -2.0
        scores.withUnsafeMutableBufferPointer { sb in
            dots.withUnsafeBufferPointer { db in
                vDSP_vsma(
                    db.baseAddress!, 1,
                    &negTwo,
                    sb.baseAddress!, 1,
                    sb.baseAddress!, 1,
                    vDSP_Length(nc)
                )
            }
        }

        // Step 3: argmin (first occurrence on ties).
        var minValue: Float = 0
        var minIndex: vDSP_Length = 0
        scores.withUnsafeBufferPointer { sb in
            vDSP_minvi(sb.baseAddress!, 1, &minValue, &minIndex, vDSP_Length(nc))
        }
        return Int(minIndex)
    }

    /// Convenience overload for `[Float]` callers.
    func nearestCluster(embedding: [Float]) -> Int {
        return embedding.withUnsafeBufferPointer { eb in
            nearestCluster(embedding: eb.baseAddress!, count: embedding.count)
        }
    }
}
