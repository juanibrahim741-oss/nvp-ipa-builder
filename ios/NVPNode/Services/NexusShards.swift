import Foundation
import ZIPFoundation

/// On-device store + downloader for NVP-D CoreML shards.
///
/// Shards are published by the GitHub Actions split as a Release (one zip per
/// `shard_i.mlmodelc` + a `tokenizer` zip). The coordinator registers a manifest
/// with each shard's download URL; this downloads + unzips them into the app's
/// caches so `NexusPipeline` / `NexusWorker` can run them.
enum NexusShardStore {
    static var rootDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("nexus", isDirectory: true)
    }
    static func modelDir(_ modelId: String) -> URL { rootDir.appendingPathComponent(modelId, isDirectory: true) }

    /// Located shard model: IPA bundle first, then the downloaded cache.
    static func shardURL(modelId: String, shard: Int) -> URL? {
        if let res = Bundle.main.resourceURL {
            let b = res.appendingPathComponent("Models/\(modelId)/shard_\(shard).mlmodelc")
            if FileManager.default.fileExists(atPath: b.path) { return b }
        }
        let d = modelDir(modelId).appendingPathComponent("shard_\(shard).mlmodelc")
        return FileManager.default.fileExists(atPath: d.path) ? d : nil
    }

    static func tokenizerDir(_ modelId: String) -> URL? {
        let d = modelDir(modelId).appendingPathComponent("tokenizer")
        return FileManager.default.fileExists(atPath: d.path) ? d : nil
    }

    static func installedShardCount(modelId: String, total: Int) -> Int {
        (0..<max(0, total)).filter { shardURL(modelId: modelId, shard: $0) != nil }.count
    }
}

/// Drives shard downloads with live, observable progress (for the animated UI).
@MainActor
final class NexusDownloadManager: ObservableObject {
    @Published var progress: Double = 0      // 0…1 across all shards
    @Published var status: String = "Idle"
    @Published var busy = false
    @Published var installed = 0
    @Published var total = 0
    @Published var totalBytes: Int64 = 0

    private let session = URLSession(configuration: .default)

    struct Plan { let modelId: String; let shards: [(index: Int, url: URL)]; let tokenizer: URL?; let bytes: Int64 }

    /// Build a download plan from a manifest dict (sizes via HEAD requests).
    func plan(manifest: [String: Any]) async -> Plan? {
        let modelId = (manifest["modelID"] as? String) ?? (manifest["name"] as? String) ?? ""
        guard !modelId.isEmpty else { return nil }
        var shards: [(Int, URL)] = []
        for s in (manifest["shards"] as? [[String: Any]]) ?? [] {
            guard let idx = s["index"] as? Int,
                  let str = s["url"] as? String, let url = URL(string: str) else { continue }
            shards.append((idx, url))
        }
        let tok = (manifest["tokenizerUrl"] as? String).flatMap { URL(string: $0) }
        var bytes: Int64 = 0
        for (_, u) in shards { bytes += await contentLength(u) }
        if let t = tok { bytes += await contentLength(t) }
        return Plan(modelId: modelId, shards: shards.map { (index: $0.0, url: $0.1) }, tokenizer: tok, bytes: bytes)
    }

    private func contentLength(_ url: URL) async -> Int64 {
        var req = URLRequest(url: url); req.httpMethod = "HEAD"
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              let len = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(len) else { return 0 }
        return n
    }

    /// Download + unzip every shard (and the tokenizer) into the model's cache dir.
    func download(plan: Plan) async {
        busy = true; status = "Downloading…"; installed = 0
        total = plan.shards.count; totalBytes = plan.bytes; progress = 0
        let dir = NexusShardStore.modelDir(plan.modelId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let steps = max(1, plan.shards.count + (plan.tokenizer != nil ? 1 : 0))
        let unit = 1.0 / Double(steps)
        for (idx, url) in plan.shards {
            status = "Shard \(idx + 1)/\(plan.shards.count)…"
            if await fetchUnzip(url, into: dir) { installed += 1 }
            progress = min(1, progress + unit)
        }
        if let t = plan.tokenizer {
            status = "Tokenizer…"
            _ = await fetchUnzip(t, into: dir)
            progress = min(1, progress + unit)
        }
        progress = 1; busy = false
        status = installed == total ? "Installed ✓" : "Incomplete (\(installed)/\(total))"
    }

    private func fetchUnzip(_ url: URL, into dir: URL) async -> Bool {
        guard let (tmp, resp) = try? await session.download(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
        do { try FileManager.default.unzipItem(at: tmp, to: dir); return true }
        catch { return false }
    }
}
