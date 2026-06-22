import Foundation

/// Client for the NVP-D distributed network (discovery + relay transport) over the
/// coordinator's Vercel-compatible HTTP signaling (`/api/nexus/*`). Used in NVP
/// Beta: a device announces its capability, discovers peers, and relays pipeline
/// activations. This avoids WebRTC/TURN for v1 (everything goes through HTTPS).
struct NexusPeer: Codable, Identifiable {
    var id: String { peerId }
    let peerId: String
    let capability: NexusCapability
    /// Per-model shard availability, encoded as "<modelId>:<shardIndex>" tokens.
    let shards: [String]
    let ageSec: Double?

    enum CodingKeys: String, CodingKey { case peerId, capability, shards, ageSec }
}

struct NexusCapability: Codable {
    let deviceName: String?
    let availableRAM_GB: Double?
    let platform: String?
}

struct NexusSignal: Codable {
    let from: String
    let kind: String
    let payload: NexusJSON
}

/// A tiny JSON value wrapper so signal payloads (tensors, offers, etc.) decode.
struct NexusJSON: Codable {
    let raw: Data
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode([String: String].self) { raw = (try? JSONEncoder().encode(d)) ?? Data() }
        else { raw = Data() }
    }
    func encode(to encoder: Encoder) throws {}
}

final class NexusClient {
    private let baseURL: String
    private let session: URLSession
    init(baseURL: String = Config.coordinatorURL) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    private func post(_ body: [String: Any]) async -> [String: Any]? {
        guard let url = URL(string: baseURL + "/api/nexus/signal"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let (out, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
    }

    /// Announce this device's capability + the "<modelId>:<shard>" tokens it serves.
    func announce(peerId: String, deviceName: String, ramGB: Double, shards: [String]) async {
        _ = await post([
            "action": "announce", "peer_id": peerId,
            "capability": ["deviceName": deviceName, "availableRAM_GB": ramGB, "platform": "ios"],
            "shards": shards,
        ])
    }

    /// Online peers in the network (capabilities + served shards).
    func peers() async -> [NexusPeer] {
        guard let obj = await post(["action": "peers"]),
              let arr = obj["peers"],
              let data = try? JSONSerialization.data(withJSONObject: arr) else { return [] }
        return (try? JSONDecoder().decode([NexusPeer].self, from: data)) ?? []
    }

    /// Relay a message (e.g. a pipeline activation step) to a peer's mailbox.
    func send(from: String, to: String, kind: String, payload: [String: Any]) async {
        _ = await post(["action": "send", "from": from, "to": to, "kind": kind, "payload": payload])
    }

    /// Drain this peer's pending messages.
    func poll(peerId: String) async -> [[String: Any]] {
        guard let obj = await post(["action": "poll", "peer_id": peerId]),
              let arr = obj["signals"] as? [[String: Any]] else { return [] }
        return arr
    }

    /// Fetch a model split manifest by id.
    func manifest(modelId: String) async -> [String: Any]? {
        guard let url = URL(string: baseURL + "/api/nexus/manifest?id=\(modelId)") else { return nil }
        guard let (out, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
    }

    /// All distributed models registered on the network (id + manifest + updatedAt).
    func manifests() async -> [[String: Any]] {
        guard let url = URL(string: baseURL + "/api/nexus/manifest") else { return [] }
        guard let (out, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
              let arr = obj["manifests"] as? [[String: Any]] else { return [] }
        return arr
    }
}
