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
        // Prefer the user-chosen persistent folder (survives uninstall).
        if let dir = StorageManager.nexusDir { return dir }
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
    // Live metrics (what the user wants to see).
    @Published var downloadedMB: Double = 0
    @Published var totalMB: Double = 0
    @Published var speedMBs: Double = 0
    @Published var etaSec: Int = 0

    private let session = URLSession(configuration: .default)
    private var baseBytes: Int64 = 0   // bytes from completed shards
    private var startTime: Date?

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

    /// Download + unzip every shard (and the tokenizer) into the model's cache dir,
    /// reporting live MB downloaded, speed (MB/s) and ETA.
    func download(plan: Plan) async {
        busy = true; status = "Downloading…"; installed = 0
        total = plan.shards.count; totalBytes = plan.bytes
        totalMB = Double(plan.bytes) / 1_000_000
        progress = 0; downloadedMB = 0; speedMBs = 0; etaSec = 0
        baseBytes = 0; startTime = Date()
        let dir = NexusShardStore.modelDir(plan.modelId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (idx, url) in plan.shards {
            status = "Shard \(idx + 1)/\(plan.shards.count)"
            let bytes = await fetchUnzip(url, into: dir)
            if bytes > 0 { installed += 1 }
            baseBytes += max(bytes, 0)
        }
        if let t = plan.tokenizer {
            status = "Tokenizer"
            baseBytes += max(await fetchUnzip(t, into: dir), 0)
        }
        progress = 1; busy = false; speedMBs = 0; etaSec = 0
        status = installed == total ? "Installé ✓" : "Incomplet (\(installed)/\(total))"
    }

    /// Returns the number of bytes downloaded (>0 on success), updating live metrics.
    private func fetchUnzip(_ url: URL, into dir: URL) async -> Int64 {
        let delegate = ProgressDelegate { [weak self] written, expected in
            guard let self else { return }
            Task { @MainActor in self.tick(written: written, expectedThisFile: expected) }
        }
        guard let (tmp, resp) = try? await session.download(from: url, delegate: delegate),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return 0 }
        do { try FileManager.default.unzipItem(at: tmp, to: dir) } catch { return 0 }
        return max(resp.expectedContentLength, delegate.lastBytes)
    }

    private func tick(written: Int64, expectedThisFile: Int64) {
        let total = baseBytes + written
        downloadedMB = Double(total) / 1_000_000
        let elapsed = Date().timeIntervalSince(startTime ?? Date())
        if elapsed > 0.3 { speedMBs = downloadedMB / elapsed }
        if totalMB > 0 {
            // Overall total known (HEAD sizes) → accurate progress + ETA.
            let remain = max(0, totalMB - downloadedMB)
            etaSec = speedMBs > 0.01 ? Int(remain / speedMBs) : 0
            progress = min(1, downloadedMB / totalMB)
        } else if expectedThisFile > 0 {
            // Fallback: per-file fraction (when the server omits Content-Length).
            progress = min(1, Double(written) / Double(expectedThisFile))
            etaSec = 0
        }
    }
}

/// URLSession download delegate: reports (bytes written, expected for this file).
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let onWrite: (Int64, Int64) -> Void
    var lastBytes: Int64 = 0
    init(_ onWrite: @escaping (Int64, Int64) -> Void) { self.onWrite = onWrite }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lastBytes = totalBytesWritten
        onWrite(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
