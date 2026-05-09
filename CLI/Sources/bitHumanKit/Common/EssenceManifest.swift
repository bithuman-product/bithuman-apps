import Foundation

/// Strongly-typed view of an Essence `.imx`'s `manifest.json`.
///
/// The container's pre-parsed `[String: Any]?` dict is fine for the
/// Expression branch (which only needs `model_type`), but the Essence
/// runtime touches `output_resolution`, `runtime_version_min`,
/// `frame_count`, `loop`, etc. — letting that surface stay loosely
/// typed invites typos and silent missing-field bugs. Decode once at
/// load time, fail loudly if anything is wrong.
///
/// Schema is documented in `docs/architecture/imx-format-v2.md`.
/// Schema version this struct understands is **`1`**; future bumps
/// require an additive code change here.
struct EssenceManifest: Codable, Sendable {

    /// Single supported value: `"essence"`. The decoder rejects any
    /// other string with ``Error/wrongModelType(found:)``.
    static let expectedModelType = "essence"
    static let supportedSchemaVersion = 1

    enum Error: Swift.Error, CustomStringConvertible {
        /// `model_type` was missing or not `"essence"`.
        case wrongModelType(found: String?)
        /// Container had no `manifest.json` entry, or it was empty.
        case missingManifest
        /// `manifest_version` is newer than this binary supports.
        /// Surface "upgrade your bithuman-kit" rather than risk a
        /// silently-wrong load.
        case unsupportedSchemaVersion(found: Int, supported: Int)
        /// `runtime_version_min` is newer than this binary's version.
        case runtimeTooOld(required: String, current: String)
        /// JSON was structurally invalid (missing required field,
        /// wrong type, etc.).
        case decode(underlying: Swift.Error)

        var description: String {
            switch self {
            case .wrongModelType(let f):
                return "EssenceManifest: model_type=\(f.map { "\"\($0)\"" } ?? "<nil>") — expected \"essence\""
            case .missingManifest:
                return "EssenceManifest: container has no manifest.json"
            case .unsupportedSchemaVersion(let f, let s):
                return "EssenceManifest: manifest_version=\(f) — this build supports only \(s). Upgrade bithuman-kit."
            case .runtimeTooOld(let req, let cur):
                return "EssenceManifest: runtime_version_min=\(req) — this build is \(cur). Upgrade bithuman-kit."
            case .decode(let e):
                return "EssenceManifest: malformed manifest.json — \(e)"
            }
        }
    }

    // MARK: - Required fields

    let modelType: String
    let manifestVersion: Int
    let agentId: String
    /// `[width, height]` of the rendered frame. For Essence: 720²,
    /// 720×1280, 1024², etc. Not 384/448/512 — those are Expression.
    let outputResolution: [Int]
    /// Semver string (`"0.10.0"`). Loaders refuse to run if the
    /// runtime is older than this.
    let runtimeVersionMin: String

    // MARK: - Common optional fields

    let displayName: String?
    let description: String?
    let createdAt: String?
    let packerVersion: String?
    let language: String?

    // MARK: - Essence-specific optional fields

    /// Number of frames in the base MP4. Optional; the runtime can
    /// also derive it from the MP4 itself, but providing it in the
    /// manifest avoids a probe round-trip during cold start.
    let frameCount: Int?
    /// `"forward"`, `"pingpong"`, or `"random"`. Default
    /// `"forward"` — encoded in the ``LoopMode`` accessor below.
    let loop: String?
    /// Name of an action defined in `video_graph.json` to play when
    /// no audio is being driven. Optional — runtime falls back to
    /// the static base loop when absent.
    let idleAction: String?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case manifestVersion = "manifest_version"
        case agentId = "agent_id"
        case outputResolution = "output_resolution"
        case runtimeVersionMin = "runtime_version_min"
        case displayName = "display_name"
        case description
        case createdAt = "created_at"
        case packerVersion = "packer_version"
        case language
        case frameCount = "frame_count"
        case loop
        case idleAction = "idle_action"
    }

    // MARK: - Public accessors

    /// `(width, height)` after validating both dimensions are
    /// positive. Falls back to `(0, 0)` if the manifest's array is
    /// malformed — callers should range-check.
    var resolution: (width: Int, height: Int) {
        guard outputResolution.count >= 2,
              outputResolution[0] > 0, outputResolution[1] > 0 else { return (0, 0) }
        return (outputResolution[0], outputResolution[1])
    }

    enum LoopMode: String, Sendable {
        case forward
        case pingpong
        case random
    }

    var loopMode: LoopMode { LoopMode(rawValue: loop ?? "forward") ?? .forward }

    // MARK: - Decode entry point

    /// Decode + validate from a container. Errors surface the
    /// schema violation directly so consumers never see a partial
    /// `EssenceManifest`.
    static func decode(from container: ImxContainer, currentRuntimeVersion: String) throws -> EssenceManifest {
        guard container.hasFile("manifest.json") else { throw Error.missingManifest }
        let raw: Data
        do {
            raw = try container.readFile("manifest.json")
        } catch {
            throw Error.decode(underlying: error)
        }
        let decoded: EssenceManifest
        do {
            decoded = try JSONDecoder().decode(EssenceManifest.self, from: raw)
        } catch {
            // Try to surface model_type mismatch with a clearer error
            // than "key 'model_type' has unexpected value" buried in
            // a generic JSONDecoder Error.
            if let dict = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let mt = dict["model_type"] as? String, mt != expectedModelType {
                throw Error.wrongModelType(found: mt)
            }
            throw Error.decode(underlying: error)
        }
        guard decoded.modelType == expectedModelType else {
            throw Error.wrongModelType(found: decoded.modelType)
        }
        guard decoded.manifestVersion == supportedSchemaVersion else {
            throw Error.unsupportedSchemaVersion(
                found: decoded.manifestVersion,
                supported: supportedSchemaVersion
            )
        }
        if compareSemver(decoded.runtimeVersionMin, currentRuntimeVersion) > 0 {
            throw Error.runtimeTooOld(
                required: decoded.runtimeVersionMin,
                current: currentRuntimeVersion
            )
        }
        return decoded
    }
}

// MARK: - Tiny semver comparator

/// Returns `1` if `a > b`, `-1` if `a < b`, `0` if equal. Tolerates
/// pre-release suffixes (`"0.10.0-beta.1"`) by ignoring everything
/// after the first `-`. Adequate for runtime gating; callers
/// needing strict semver semantics should bring their own comparator.
private func compareSemver(_ a: String, _ b: String) -> Int {
    func parts(_ s: String) -> [Int] {
        let core = s.split(separator: "-").first.map(String.init) ?? s
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
    let pa = parts(a)
    let pb = parts(b)
    let n = max(pa.count, pb.count)
    for i in 0..<n {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x > y ? 1 : -1 }
    }
    return 0
}
