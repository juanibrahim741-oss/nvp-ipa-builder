import Foundation

// MARK: - DTOs

struct RegisterResponse: Decodable {
    let workerId: String
    let apiKey: String
    let reputation: Double
}

struct ModelDTO: Decodable, Identifiable {
    let id: String
    let name: String
    let downloadUrl: String
    let quant: String
    let sizeMb: Int
    let creditRate: Double
}

struct ModelsResponse: Decodable { let models: [ModelDTO] }

struct JobParams: Decodable {
    let maxTokens: Int?
    let reasoning: Bool?
}

struct Job: Decodable {
    let jobId: String
    let model: String
    let prompt: String
    let params: JobParams?
}

struct SubmitResultResponse: Decodable {
    let accepted: Bool
    let credited: Double
    let balance: Double
    let reason: String?
}

struct BalanceResponse: Decodable {
    let balance: Double
    let currency: String
    let jobsDone: Int
}

struct LedgerEntry: Decodable, Identifiable {
    let id: String
    let amount: Double
    let type: String
    let jobId: String?
    let createdAt: String
}

struct LedgerResponse: Decodable { let entries: [LedgerEntry] }

struct PayoutResponse: Decodable {
    let payoutId: String
    let status: String
    let amount: Double
}

struct Payout: Decodable, Identifiable {
    let id: String
    let amount: Double
    let status: String
    let method: String
    let createdAt: String
}

struct PayoutsResponse: Decodable { let payouts: [Payout] }

struct LinkResponse: Decodable { let ok: Bool; let linkedTo: String? }

struct StatsDTO: Decodable {
    let devicesOnline: Int
    let devicesTotal: Int
    let combinedTops: Int
    let liveTokensPerSec: Double
    let jobsDone: Int
}

struct SettingsDTO: Decodable {
    let nvpSplitEnabled: Bool
    let walletBetaEnabled: Bool
}

enum APIError: Error, LocalizedError {
    case http(Int, String)
    case badURL
    case decoding

    var errorDescription: String? {
        switch self {
        case let .http(code, msg): return "HTTP \(code): \(msg)"
        case .badURL: return "Bad coordinator URL"
        case .decoding: return "Failed to decode response"
        }
    }
}

// MARK: - Client

/// Talks to the coordinator. Bearer auth with the device API key.
final class APIClient {
    private let baseURL: String
    private var apiKey: String?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Dedicated session whose request timeout exceeds the ~25s long-poll window.
    private let longPollSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 40
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    init(baseURL: String, apiKey: String?) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
    }

    func setApiKey(_ key: String) { apiKey = key }

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func run<T: Decodable>(_ req: URLRequest, session: URLSession = .shared) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(0, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do { return try decoder.decode(T.self, from: data) } catch { throw APIError.decoding }
    }

    // MARK: Endpoints

    func register(devicePubkey: String) async throws -> RegisterResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "device_pubkey": devicePubkey,
            "platform": "ios",
            "model_caps": Config.modelCaps,
        ])
        return try await run(try makeRequest("/api/workers/register", method: "POST", body: body))
    }

    func models() async throws -> [ModelDTO] {
        let r: ModelsResponse = try await run(try makeRequest("/api/models"))
        return r.models
    }

    /// Long-poll for a job. Returns nil on HTTP 204 (no job available).
    func nextJob(models: [String]) async throws -> Job? {
        let q = models.joined(separator: ",")
        let req = try makeRequest("/api/jobs/next?models=\(q)")
        let (data, resp) = try await longPollSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(0, "no response") }
        if http.statusCode == 204 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try decoder.decode(Job.self, from: data)
    }

    func submitResult(jobId: String, output: String, latencyMs: Int, tokensOut: Int) async throws -> SubmitResultResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "output": output,
            "latency_ms": latencyMs,
            "tokens_out": tokensOut,
        ])
        return try await run(try makeRequest("/api/jobs/\(jobId)/result", method: "POST", body: body))
    }

    func balance() async throws -> BalanceResponse {
        try await run(try makeRequest("/api/me/balance"))
    }

    func ledger() async throws -> [LedgerEntry] {
        let r: LedgerResponse = try await run(try makeRequest("/api/me/ledger"))
        return r.entries
    }

    func requestPayout(amount: Double) async throws -> PayoutResponse {
        let body = try JSONSerialization.data(withJSONObject: ["amount": amount, "method": "manual"])
        return try await run(try makeRequest("/api/payouts", method: "POST", body: body))
    }

    func payouts() async throws -> [Payout] {
        let r: PayoutsResponse = try await run(try makeRequest("/api/me/payouts"))
        return r.payouts
    }

    /// Public live network stats (no auth required).
    func stats() async throws -> StatsDTO {
        try await run(try makeRequest("/api/stats"))
    }

    /// Public feature flags (NVP split, wallet beta).
    func settings() async throws -> SettingsDTO {
        try await run(try makeRequest("/api/settings"))
    }

    /// Is the coordinator reachable? (pings /api/health, no auth)
    func health() async -> Bool {
        guard let url = URL(string: baseURL + "/api/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Lightweight presence heartbeat (any authed call refreshes last_seen).
    func heartbeat() async {
        _ = try? await balance()
    }

    /// NVP Beta: announce this device's capability to the distributed signaling
    /// registry so the network can place model shards on it.
    func nexusAnnounce(peerId: String, deviceModel: String, ramGB: Double) async {
        let body = try? JSONSerialization.data(withJSONObject: [
            "action": "announce",
            "peer_id": peerId,
            "capability": [
                "deviceName": deviceModel,
                "availableRAM_GB": ramGB,
                "platform": "ios",
            ],
            "shards": [],
        ])
        guard let body, let req = try? makeRequest("/api/nexus/signal", method: "POST", body: body) else { return }
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Register the worker's on-chain wallet address (for NVP withdrawals).
    func linkWallet(address: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["address": address])
        struct OK: Decodable { let ok: Bool }
        let _: OK = try await run(try makeRequest("/api/wallet/link", method: "POST", body: body))
    }

    /// Withdraw earnings on-chain to the linked wallet. amount nil = full balance.
    func walletWithdraw(amount: Double?) async throws -> String {
        let payload: [String: Any] = amount != nil ? ["amount": amount!] : ["amount": "all"]
        let body = try JSONSerialization.data(withJSONObject: payload)
        struct WD: Decodable { let ok: Bool; let txHash: String?; let explorerUrl: String? }
        let r: WD = try await run(try makeRequest("/api/wallet/withdraw", method: "POST", body: body))
        return r.txHash ?? ""
    }

    /// Link this worker device to a chatbot account (email + password).
    func link(email: String, password: String) async throws -> String? {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let r: LinkResponse = try await run(try makeRequest("/api/workers/link", method: "POST", body: body))
        return r.linkedTo
    }
}
