import Foundation

/// Persistent, user-chosen storage for models + NVP shards.
///
/// The user picks a folder in the Files app (iCloud Drive / On My iPhone / an
/// external drive) from Settings. We keep a **security-scoped bookmark** so the
/// app can read/write there across launches. Because the folder lives OUTSIDE
/// the app sandbox, the downloaded models + shards survive an app uninstall —
/// on reinstall the user re-picks the same folder to recover everything.
enum StorageManager {
    private static let key = "nvp_storage_bookmark"
    private static var cached: URL?

    static var isConfigured: Bool { UserDefaults.standard.data(forKey: key) != nil }

    /// Resolve the chosen folder (starts security-scoped access, kept for the session).
    static func folderURL() -> URL? {
        if let c = cached { return c }
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        _ = url.startAccessingSecurityScopedResource() // held for the app session
        cached = url
        return url
    }

    /// Persist the user's folder choice + create the models/ and nexus/ subfolders.
    static func setFolder(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key)
        cached = nil
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("models"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("nexus"), withIntermediateDirectories: true)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key); cached = nil }

    static var displayName: String { folderURL()?.lastPathComponent ?? "Non configuré" }

    /// NVP shard storage (falls back to Caches when no folder is chosen).
    static var nexusDir: URL? { folderURL()?.appendingPathComponent("nexus", isDirectory: true) }
    /// MLX model storage (HubApi downloadBase) — nil → default app cache.
    static var modelsDir: URL? { folderURL()?.appendingPathComponent("models", isDirectory: true) }
}
