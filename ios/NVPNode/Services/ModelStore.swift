import Foundation

/// Inspects the on-device Hugging Face cache to tell whether a model is already
/// downloaded and how many GB it takes on disk.
///
/// mlx-swift-lm's default Hub client downloads to
/// `<Caches>/models/<repo-id>/…` (swift-transformers `HubApi`), so we look there.
enum ModelStore {
    /// Candidate cache locations the Hub client may use.
    private static func candidates(for modelId: String) -> [URL] {
        let repo = Config.hfRepo(for: modelId)
        let fm = FileManager.default
        var bases: [URL] = []
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            bases.append(caches.appendingPathComponent("models", isDirectory: true))
            bases.append(caches.appendingPathComponent("huggingface/models", isDirectory: true))
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            bases.append(docs.appendingPathComponent("models", isDirectory: true))
        }
        return bases.map { $0.appendingPathComponent(repo, isDirectory: true) }
    }

    /// First existing local directory for a model id: the IPA-bundled copy first
    /// (pre-installed at build time), then the on-device Hub cache.
    static func localDir(for modelId: String) -> URL? {
        if let bundled = Config.bundledModelDir(modelId) { return bundled }
        return candidates(for: modelId).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Is the model ready? (bundled in the IPA, or downloaded with weights present)
    static func isInstalled(_ modelId: String) -> Bool {
        if Config.bundledModelDir(modelId) != nil { return true }
        guard let dir = localDir(for: modelId),
              FileManager.default.fileExists(atPath: dir.path) else { return false }
        // A real download has at least a config.json + a safetensors file.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return contents.contains(where: { $0.hasSuffix(".safetensors") })
    }

    /// On-disk size in GB (0 if not present).
    static func sizeOnDiskGB(_ modelId: String) -> Double {
        guard let dir = localDir(for: modelId) else { return 0 }
        return Double(directorySize(dir)) / 1_073_741_824.0
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }
}
