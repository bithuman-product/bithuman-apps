import CryptoKit
import Foundation

/// Opens an Expression-type `.imx` container, extracts the weight
/// files it carries into a private temp directory, and hands back the
/// internal ``ModelPaths`` the pipeline needs.
///
/// Layout convention (enforced by `bithuman pack` on the Python side):
/// ```text
/// manifest.json
/// weights/dmd2_run9.safetensors
/// weights/wav2vec2.safetensors
/// weights/pos_conv_weight.npy            (optional — computed from
///                                          weight_g/weight_v when absent)
/// weights/vae_encoder.safetensors
/// weights/default_ref_latent.npy
/// weights/turbo_vaed_ane_384.mlpackage/… (flattened — directory tree
///                                          stored as individual entries
///                                          keyed by their relative path)
/// preview.jpg                             (optional — for catalog UIs)
/// ```
///
/// Hold on to the returned ``ExpressionModel`` for the lifetime of
/// the ``Bithuman`` actor: when it deinits, the temp directory is
/// removed. Throwing it away early will delete weights out from under
/// the running pipeline.
internal struct ExpressionModel {

    enum Error: Swift.Error, CustomStringConvertible {
        case missingManifest
        case wrongModelType(found: String?)
        case missingWeight(name: String)
        case extractionFailed(underlying: Swift.Error)

        var description: String {
            switch self {
            case .missingManifest:
                return "ExpressionModel: container has no manifest.json"
            case .wrongModelType(let m):
                return "ExpressionModel: manifest.model_type=\(m ?? "<nil>") — expected \"expression\""
            case .missingWeight(let name):
                return "ExpressionModel: required weight entry missing — \(name)"
            case .extractionFailed(let e):
                return "ExpressionModel: weight extraction failed — \(e)"
            }
        }
    }

    static let manifestEntryName = "manifest.json"
    static let expectedModelType = "expression"
    static let ditEntryName = "weights/dmd2_run9.safetensors"
    static let wav2vecEntryName = "weights/wav2vec2.safetensors"
    static let posConvWeightEntryName = "weights/pos_conv_weight.npy"
    static let vaeEncoderEntryName = "weights/vae_encoder.safetensors"
    static let refLatentEntryName = "weights/default_ref_latent.npy"
    static let aneDecoderPrefix = "weights/turbo_vaed_ane_384.mlpackage/"
    static let aneDecoderDirName = "turbo_vaed_ane_384.mlpackage"
    /// Optional: ANE-resident Wav2Vec2 audio encoder. When the
    /// container ships these entries, the streaming pipeline runs
    /// audio inference on the Neural Engine instead of MLX/Metal.
    /// Backwards-compatible: containers without these entries use
    /// the existing MLX path automatically.
    static let aneWav2VecPrefix = "weights/wav2vec2_ane.mlpackage/"
    static let aneWav2VecDirName = "wav2vec2_ane.mlpackage"
    static let defaultNSteps = 2

    /// Temp directory owning all extracted files. Removed on ``deinit``.
    let workDirectory: URL

    /// Ready-to-use paths for ``PipelineOps/load(box:paths:)``.
    /// Internal — external consumers go through ``Bithuman/create(modelPath:)``
    /// which drives model extraction + load without exposing the
    /// intermediate paths.
    let paths: ModelPaths

    /// Raw manifest dictionary — useful for diagnostics (tool version,
    /// build date). Public-API consumers don't see this; it's stashed
    /// on the Bithuman actor so the SDK can log one startup line.
    let manifest: [String: Any]

    /// Load + extract. Picks a stable, content-addressed directory
    /// under `~/Library/Caches/com.bithuman.expression-extracted/<fingerprint>/`
    /// so the mlmodelc paths stay byte-identical across launches.
    /// That stability matters: ANED keys its compiled-shader cache
    /// on the mlmodelc file path. The previous implementation used
    /// `NSTemporaryDirectory()/com.bithuman.sdk.expression-<UUID>`,
    /// which gave a fresh path on every launch and forced ANED to
    /// recompile from scratch (~2-3 min) every single time, even
    /// when the same `.imx` was already on disk. Same-fingerprint
    /// reuse drops cold-start to ~5 s after the first run.
    ///
    /// The fingerprint is derived from the source `.imx`'s
    /// (resolved-path | mtime | size). SHA-256 of the contents would
    /// be more robust, but on a 1.5 GB file it costs several seconds
    /// every launch — defeating the purpose. Path+mtime+size catches
    /// "user replaced the file" while staying microsecond-fast.
    static func load(from url: URL, nSteps: Int = defaultNSteps) throws -> ExpressionModel {
        let container = try ImxContainer(path: url)

        guard let manifest = container.manifest else { throw Error.missingManifest }
        let modelType = manifest["model_type"] as? String
        guard modelType == expectedModelType else {
            throw Error.wrongModelType(found: modelType)
        }

        // Required entries — fail fast, before we touch the filesystem.
        for required in [ditEntryName, wav2vecEntryName, vaeEncoderEntryName, refLatentEntryName] {
            guard container.hasFile(required) else { throw Error.missingWeight(name: required) }
        }
        let aneEntries = container.entryNames.filter { $0.hasPrefix(aneDecoderPrefix) }
        guard !aneEntries.isEmpty else {
            throw Error.missingWeight(name: "\(aneDecoderPrefix)…")
        }
        // Optional: ANE wav2vec2. Backwards-compatible — older .imx
        // containers that don't ship this fall through to the MLX path.
        let aneWav2VecEntries = container.entryNames.filter { $0.hasPrefix(aneWav2VecPrefix) }
        let hasAneWav2Vec = !aneWav2VecEntries.isEmpty

        let workDir = try Self.makeWorkDirectory(forImxAt: url)
        let sentinelPath = workDir.appendingPathComponent(".bithuman-extracted-ok").path
        let alreadyExtracted = FileManager.default.fileExists(atPath: sentinelPath)

        if !alreadyExtracted {
            // Different fingerprint than what's on disk (or first run
            // for this .imx). Clear any partial leftovers and extract
            // fresh. We re-check the sentinel rather than the dir's
            // existence because a previous launch could have crashed
            // mid-extraction and left a half-populated directory —
            // that would deceive an "is dir non-empty" check into
            // skipping extraction.
            try? FileManager.default.removeItem(at: workDir)
            try FileManager.default.createDirectory(
                at: workDir, withIntermediateDirectories: true
            )
            do {
                try extract(
                    container: container,
                    aneEntries: aneEntries,
                    aneWav2VecEntries: aneWav2VecEntries,
                    into: workDir
                )
                // Mark this extraction complete only after every weight
                // has actually landed — see the half-populated case
                // above. Subsequent launches see this sentinel and
                // skip the (~5–10 s) re-extraction step entirely.
                FileManager.default.createFile(atPath: sentinelPath, contents: Data())
            } catch {
                try? FileManager.default.removeItem(at: workDir)
                throw Error.extractionFailed(underlying: error)
            }
        }

        let paths = ModelPaths(
            ditWeights:     workDir.appendingPathComponent("dmd2_run9.safetensors").path,
            wav2vecWeights: workDir.appendingPathComponent("wav2vec2.safetensors").path,
            wav2vecAne:     hasAneWav2Vec
                ? workDir.appendingPathComponent(aneWav2VecDirName).path
                : nil,
            refLatent:      workDir.appendingPathComponent("default_ref_latent.npy").path,
            aneDecoder:     workDir.appendingPathComponent(aneDecoderDirName).path,
            vaeEncoder:     workDir.appendingPathComponent("vae_encoder.safetensors").path,
            nSteps:         nSteps
        )
        return ExpressionModel(
            workDirectory: workDir,
            paths: paths,
            manifest: manifest
        )
    }

    // MARK: - Extraction

    private static func extract(
        container: ImxContainer,
        aneEntries: [String],
        aneWav2VecEntries: [String] = [],
        into workDir: URL
    ) throws {
        // Flat weight files — go straight to workDir root under their
        // bare filenames so existing pipeline code paths (e.g. the
        // sibling `pos_conv_weight.npy` lookup in Wav2Vec2) work
        // unchanged.
        let flatEntries: [(String, String)] = [
            (ditEntryName,         "dmd2_run9.safetensors"),
            (wav2vecEntryName,     "wav2vec2.safetensors"),
            (vaeEncoderEntryName,  "vae_encoder.safetensors"),
            (refLatentEntryName,   "default_ref_latent.npy"),
        ]
        for (entryName, fileName) in flatEntries {
            try container.extractFile(entryName, to: workDir.appendingPathComponent(fileName))
        }

        if container.hasFile(posConvWeightEntryName) {
            try container.extractFile(
                posConvWeightEntryName,
                to: workDir.appendingPathComponent("pos_conv_weight.npy")
            )
        }

        // `.mlpackage` is a directory — pack flattened the tree into
        // individual entries keyed by their path inside the package.
        // Recreate that tree under workDir/turbo_vaed_ane_384.mlpackage/.
        let fm = FileManager.default
        let aneRoot = workDir.appendingPathComponent(aneDecoderDirName)
        for entryName in aneEntries {
            let relativePath = String(entryName.dropFirst(aneDecoderPrefix.count))
            guard !relativePath.isEmpty else { continue }
            let dest = aneRoot.appendingPathComponent(relativePath)
            try fm.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try container.extractFile(entryName, to: dest)
        }

        // Same flattened-tree extraction for the optional ANE Wav2Vec2.
        if !aneWav2VecEntries.isEmpty {
            let w2v2Root = workDir.appendingPathComponent(aneWav2VecDirName)
            for entryName in aneWav2VecEntries {
                let relativePath = String(entryName.dropFirst(aneWav2VecPrefix.count))
                guard !relativePath.isEmpty else { continue }
                let dest = w2v2Root.appendingPathComponent(relativePath)
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try container.extractFile(entryName, to: dest)
            }
        }
    }

    /// Stable per-`.imx` extraction directory. Hashes
    /// (resolvedPath | mtime | size) so the same source file maps
    /// to the same path across launches — keeping the ANED shader
    /// cache hot — but a different file (or a replaced file with
    /// new mtime/size) gets its own directory automatically.
    /// Lives under `~/Library/Caches/com.bithuman.expression-extracted/`
    /// so it survives reboots and isn't auto-cleaned by the OS the
    /// way `NSTemporaryDirectory()` is.
    private static func makeWorkDirectory(forImxAt source: URL) throws -> URL {
        let resolvedPath = source.resolvingSymlinksInPath().path
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let fingerprint = "\(resolvedPath)|\(Int(mtime))|\(size)"
        let hash = SHA256.hash(data: Data(fingerprint.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()

        let cachesBase = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let base = cachesBase
            .appendingPathComponent("com.bithuman.expression-extracted", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
        try FileManager.default.createDirectory(
            at: base.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return base
    }

    // MARK: - Lifetime

    /// No-op now that the extraction directory is content-addressed
    /// and meant to survive across launches (otherwise we'd defeat
    /// the ANED shader-cache reuse this whole layout was added to
    /// preserve). Old call sites that invoked `cleanup()` on shutdown
    /// keep compiling — the body is just empty. To free the cache
    /// disk space, the user runs `bithuman-cli cleanup` (which wipes
    /// `~/Library/Caches/com.bithuman.expression-extracted/`).
    func cleanup() {
        // intentionally empty — see the comment above.
    }
}
