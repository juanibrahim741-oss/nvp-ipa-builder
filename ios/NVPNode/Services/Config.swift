import Foundation

/// App configuration. The coordinator URL is user-editable (Settings) and stored
/// in UserDefaults so testers can point the app at their own deployment.
enum Config {
    private static let coordinatorKey = "coordinator_url"

    /// Default coordinator URL. Override in Settings, or set a real deployment here.
    static let defaultCoordinatorURL = "https://nvp-coordinator.vercel.app"

    static var coordinatorURL: String {
        get { UserDefaults.standard.string(forKey: coordinatorKey) ?? defaultCoordinatorURL }
        set { UserDefaults.standard.set(newValue, forKey: coordinatorKey) }
    }

    private static let modelKey = "worker_model_id"

    /// User selection: a concrete model id, or "auto" (pick by device RAM).
    static var workerModelId: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    /// The concrete model actually loaded/advertised (resolves "auto" by RAM).
    static var effectiveModelId: String {
        if workerModelId != "auto" { return workerModelId }
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gb >= 7.5 { return "gemma4_e2b" }   // iPhone 15 Pro+ (8 GB)
        if gb >= 5.5 { return "gemma3n_e2b" }  // 6 GB devices
        return "gemma3_1b"                      // everything else
    }

    static var modelCaps: [String] { [effectiveModelId] }

    /// User opted into the Wallet (Beta) — only effective if the admin allows it.
    static var walletBetaActive: Bool {
        get { UserDefaults.standard.bool(forKey: "wallet_beta_active") }
        set { UserDefaults.standard.set(newValue, forKey: "wallet_beta_active") }
    }

    /// NVP Beta (distributed compute): when ON, this device joins the network to
    /// run a *share* of bigger models split across devices (pipeline), instead of
    /// only running whole models locally. Announces its capability to the
    /// coordinator's signaling registry.
    static var nvpBetaEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "nvp_beta_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "nvp_beta_enabled") }
    }

    /// Stable per-install peer id for the distributed network.
    static var peerId: String {
        if let p = UserDefaults.standard.string(forKey: "nvp_peer_id") { return p }
        let p = "peer_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
        UserDefaults.standard.set(p, forKey: "nvp_peer_id")
        return p
    }

    /// Rough RAM (GB) available to the app — used to size the shard this device
    /// can run in NVP Beta.
    static var deviceRamGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    }

    /// Models that actually run on-device via MLX (others are coordinator-only).
    static let supportedOnDevice: Set<String> = [
        "auto", "gemma4_e2b", "gemma3n_e2b", "gemma3_1b", "qwen2_5_0_5b",
        "phi4_mini", "llama3_2_3b", "llama3_2_3b_abliterated", "nidum_llama3_2_3b",
    ]

    /// Hugging Face repo id backing each on-device model (for download/cache checks).
    static func hfRepo(for id: String) -> String {
        switch id {
        case "gemma4_e2b": return "mlx-community/gemma-4-e2b-it-4bit"
        case "gemma3n_e2b": return "mlx-community/gemma-3n-E2B-it-lm-4bit"
        case "qwen2_5_0_5b": return "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        case "phi4_mini": return "mlx-community/Phi-4-mini-instruct-4bit"
        case "llama3_2_3b": return "mlx-community/Llama-3.2-3B-Instruct-4bit"
        case "llama3_2_3b_abliterated": return "mlx-community/Llama-3.2-3B-Instruct-abliterated-6bit"
        case "nidum_llama3_2_3b": return "osmapi/Nidum-Llama-3.2-3B-Uncensored-MLX-4bit"
        default: return "mlx-community/gemma-3-1b-it-qat-4bit" // gemma3_1b
        }
    }

    /// Approx download size (MB) per model — used to show MB when the downloader
    /// reports only a fraction (no byte counts).
    static func declaredMB(_ id: String) -> Double {
        switch id {
        case "gemma4_e2b": return 1500
        case "gemma3n_e2b": return 2000
        case "qwen2_5_0_5b": return 300
        case "phi4_mini": return 2200
        case "llama3_2_3b", "nidum_llama3_2_3b": return 1900
        case "llama3_2_3b_abliterated": return 2700
        default: return 900 // gemma3_1b
        }
    }

    /// Models shipped *inside the IPA* (downloaded at build time into `Models/`).
    /// These are ready to launch on first install — no on-device download needed.
    static let bundledModelIds: Set<String> = ["gemma3_1b", "gemma4_e2b"]

    /// Local directory of a model pre-installed in the app bundle, if present and
    /// non-empty (has weights). Returned so the engine can load it directly
    /// instead of downloading from Hugging Face.
    static func bundledModelDir(_ id: String) -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("Models/\(id)", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.contains(where: { $0.hasSuffix(".safetensors") }) ? dir : nil
    }

    /// Metal buffer cache cap. Deliberately small: on iOS the model weights + KV
    /// cache already dominate the app's jetsam budget, so a big reuse-cache is what
    /// pushes large models (Gemma 4) over the limit and crashes the app. Keep it
    /// modest; we also clear the cache between jobs.
    static var gpuCacheLimitBytes: Int {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let mb: Int = gb >= 7.5 ? 48 : 24
        return mb * 1024 * 1024
    }

    /// Max tokens the worker will generate for one job. Capped so the KV cache
    /// stays bounded (we also 8-bit quantize + cap the KV cache in the engine).
    static let maxTokensCap = 1024
    /// Default when a job doesn't specify one.
    static let defaultMaxTokens = 512
    /// How many jobs the worker pre-fetches into its local queue.
    static let maxQueueDepth = 4

    // MARK: - NVP crypto (Base Sepolia testnet)
    /// JSON-RPC endpoint for the NVP chain.
    static let chainRpcUrl = "https://sepolia.base.org"
    /// EIP-155 chain id (Base Sepolia = 84532).
    static let chainId = 84532
    /// Deployed NVP ERC-20 contract address.
    static let nvpContractAddress = "0x989bad8f4124fae433ed0dfa165490ed2585fc70"
    /// Block explorer base for tx/address links.
    static let chainExplorer = "https://sepolia.basescan.org"
}
