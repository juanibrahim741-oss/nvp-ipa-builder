import Foundation
import Combine
import CryptoKit
import UIKit
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    // Registration
    @Published var workerId: String?
    @Published var isRegistered = false

    // Worker runtime
    @Published var isWorker = false
    @Published var status = "idle"
    @Published var lastLatencyMs = 0
    @Published var jobsToday = 0
    @Published var creditsToday = 0.0
    @Published var queueDepth = 0          // jobs waiting in the local queue
    @Published var tokensPerSec = 0.0      // last job decode speed
    @Published var errorMessage: String?

    // Earnings
    @Published var balance = 0.0
    @Published var jobsDone = 0
    @Published var ledger: [LedgerEntry] = []
    @Published var payoutsList: [Payout] = []

    // Catalog
    @Published var models: [ModelDTO] = []

    // Linked chatbot account (email), if any.
    @Published var linkedEmail: String? = UserDefaults.standard.string(forKey: "linked_email")

    // Live network + activity (for the animated Network view)
    @Published var networkOnline = 0
    @Published var networkTotal = 0
    @Published var networkTops = 0
    @Published var liveTokps = 0.0
    @Published var activity: WorkerActivity = .idle
    @Published var loadProgress: Double = 0 // model download/load 0...1
    @Published var isPreloading = false
    @Published var connected = false // coordinator reachable?
    @Published var downloadMB: Double = 0
    @Published var downloadTotalMB: Double = 0
    @Published var downloadSpeedMBs: Double = 0
    @Published var loadingIntoMemory = false // download done, initializing weights
    @Published var nvpEnabled = false // NVP split protocol active (admin)
    @Published var walletBetaEnabled = false // wallet beta allowed (admin)
    @Published var nvpBetaOn = Config.nvpBetaEnabled // user joined distributed compute
    private var nvpBaselineSet = false // first settings poll establishes baseline
    private var dlLastMB: Double = 0
    private var dlLastTime: Date?
    private var dlLastLog: Date?

    private var statsTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    let deviceState = DeviceState()
    private var api: APIClient
    // Real on-device inference (MLX). Swap to StubInferenceEngine() only to test
    // the loop without loading a model.
    private let engine: InferenceEngine = MLXInferenceEngine()
    private var loop: WorkerLoop?

    init() {
        let key = KeychainStore.get(KeychainStore.apiKeyKey)
        api = APIClient(baseURL: Config.coordinatorURL, apiKey: key)
        workerId = KeychainStore.get(KeychainStore.workerIdKey)
        isRegistered = (key != nil && workerId != nil)

        // Re-render views observing AppState when device conditions change
        // (charging / thermal / foreground).
        deviceState.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        engine.progressHandler = { [weak self] frac, done, total in
            Task { @MainActor in self?.onDownloadProgress(frac, done, total) }
        }
        startStatsPolling()
        startConnectivityPolling()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if isRegistered { Task { try? await loadModels() } }
    }

    /// Local notification fired when the admin turns the NVP protocol ON.
    private func notifyNVPActivated() {
        nvpLog(.success, "NVP Protocol activated by the network")
        let content = UNMutableNotificationContent()
        content.title = "NVP Protocol activated"
        content.body = "Your iPhone is now part of the distributed NVP network (answers split across devices)."
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "nvp-activated-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil,
        )
        UNUserNotificationCenter.current().add(req)
    }

    /// Ping the coordinator so the UI can show connected/unreachable clearly.
    private func startConnectivityPolling() {
        Task { [weak self] in
            while !Task.isCancelled {
                let ok = await self?.api.health() ?? false
                await MainActor.run { self?.connected = ok }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    /// Change the on-device model the worker runs. Reloads the engine on the
    /// next loop iteration and advertises the new model to the coordinator.
    func setWorkerModel(_ id: String) {
        let previous = Config.effectiveModelId
        Config.workerModelId = id
        // Only drop the loaded model if the *effective* model actually changed —
        // avoids unloading/reloading (a memory spike) mid-work when re-selecting
        // the same model.
        if Config.effectiveModelId != previous {
            engine.unload()
            nvpLog(.info, "Switched on-device model to \(Config.effectiveModelId)")
        }
        objectWillChange.send()
    }

    /// Download + load a model now (from Settings), with visible progress —
    /// independent of the worker toggle. Lets the user pre-install models.
    func preloadModel(_ id: String) {
        guard !isPreloading else { return }
        setWorkerModel(id)
        isPreloading = true
        activity = .loadingModel
        loadProgress = 0
        downloadMB = 0
        downloadSpeedMBs = 0
        downloadTotalMB = Config.declaredMB(Config.effectiveModelId)
        loadingIntoMemory = false
        dlLastMB = 0
        dlLastTime = nil
        errorMessage = nil
        nvpLog(.info, "Downloading model \(Config.effectiveModelId)…")
        Task {
            do {
                try await engine.load(modelDir: nil)
                nvpLog(.success, "Model ready: \(Config.effectiveModelId)")
            } catch {
                errorMessage = "Download failed: \(error.localizedDescription)"
                nvpLog(.error, "Download failed: \(error.localizedDescription)")
            }
            isPreloading = false
            loadingIntoMemory = false
            activity = .idle
            objectWillChange.send()
        }
    }

    /// Poll public network stats so the Network view always shows live counts.
    private func startStatsPolling() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                if let s = try? await self?.api.stats() {
                    await MainActor.run {
                        guard let self else { return }
                        self.networkOnline = s.devicesOnline
                        self.networkTotal = s.devicesTotal
                        self.networkTops = s.combinedTops
                        self.liveTokps = s.liveTokensPerSec
                    }
                }
                if let f = try? await self?.api.settings() {
                    await MainActor.run {
                        guard let self else { return }
                        let wasOn = self.nvpEnabled
                        self.nvpEnabled = f.nvpSplitEnabled
                        self.walletBetaEnabled = f.walletBetaEnabled
                        // Notify the owner when the admin switches NVP ON (skip the
                        // first poll, which just establishes the baseline).
                        if self.nvpBaselineSet, !wasOn, f.nvpSplitEnabled {
                            self.notifyNVPActivated()
                        }
                        self.nvpBaselineSet = true
                    }
                }
                // NVP Beta: keep this device announced in the distributed registry.
                if Config.nvpBetaEnabled {
                    await self?.api.nexusAnnounce(
                        peerId: Config.peerId,
                        deviceModel: await MainActor.run { UIDevice.current.model },
                        ramGB: Config.deviceRamGB,
                    )
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    /// Toggle NVP Beta (distributed compute participation).
    func setNvpBeta(_ on: Bool) {
        Config.nvpBetaEnabled = on
        nvpBetaOn = on
        nvpLog(.info, on ? "NVP Beta ON — joining distributed compute network" : "NVP Beta OFF")
        if on {
            Task { await api.nexusAnnounce(peerId: Config.peerId, deviceModel: UIDevice.current.model, ramGB: Config.deviceRamGB) }
        }
    }

    /// Rebuild the API client (e.g. after the coordinator URL changes in Settings).
    func rebuildClient() {
        api = APIClient(baseURL: Config.coordinatorURL, apiKey: KeychainStore.get(KeychainStore.apiKeyKey))
    }

    /// Live download progress -> MB + speed, with periodic log lines.
    /// The MLX downloader often reports only a fraction (no byte counts), so we
    /// estimate MB from the model's known size.
    private func onDownloadProgress(_ frac: Double, _ done: Int64, _ total: Int64) {
        loadProgress = frac
        let mb = 1_048_576.0
        let totalMB = total > 0 ? Double(total) / mb : Config.declaredMB(Config.effectiveModelId)
        downloadTotalMB = totalMB
        downloadMB = total > 0 ? Double(done) / mb : frac * totalMB
        // Download finished, now loading weights into GPU memory (no progress).
        loadingIntoMemory = frac >= 0.999

        let now = Date()
        if let t = dlLastTime {
            let dt = now.timeIntervalSince(t)
            if dt > 0.5 {
                downloadSpeedMBs = max(0, (downloadMB - dlLastMB) / dt)
                dlLastMB = downloadMB
                dlLastTime = now
            }
        } else {
            dlLastMB = downloadMB
            dlLastTime = now
        }
        if dlLastLog == nil || now.timeIntervalSince(dlLastLog!) > 1.0 {
            dlLastLog = now
            if loadingIntoMemory {
                nvpLog(.info, "Download complete — loading model into memory (can take 1-2 min)…")
            } else {
                nvpLog(.info, String(format: "Downloading %.0f/%.0f MB · %.1f MB/s (%.0f%%)",
                                     downloadMB, downloadTotalMB, downloadSpeedMBs, frac * 100))
            }
        }
    }

    /// Deterministic wallet address derived from the device key (beta; off-chain).
    /// When real testnet NVP lands, this becomes the on-chain address.
    var walletAddress: String {
        guard let raw = KeychainStore.get(KeychainStore.devicePrivKey),
              let data = Data(base64Encoded: raw),
              let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
        else { return "—" }
        let pub = priv.publicKey.rawRepresentation
        return "nvp1" + pub.prefix(20).map { String(format: "%02x", $0) }.joined()
    }

    /// Wallet is usable only if the user opted in AND the admin allows it.
    var walletActive: Bool { Config.walletBetaActive && walletBetaEnabled }

    /// Ping the coordinator (onboarding before registering).
    func checkHealth() async -> Bool {
        let ok = await api.health()
        connected = ok
        return ok
    }

    // MARK: Registration

    func register() async {
        errorMessage = nil
        do {
            let pubkey = devicePublicKey()
            let res = try await api.register(devicePubkey: pubkey)
            KeychainStore.set(res.apiKey, for: KeychainStore.apiKeyKey)
            KeychainStore.set(res.workerId, for: KeychainStore.workerIdKey)
            api.setApiKey(res.apiKey)
            workerId = res.workerId
            isRegistered = true
            nvpLog(.success, "Registered worker \(res.workerId)")
            try? await loadModels()
        } catch {
            errorMessage = error.localizedDescription
            nvpLog(.error, "Registration failed: \(error.localizedDescription)")
        }
    }

    private func devicePublicKey() -> String {
        if let raw = KeychainStore.get(KeychainStore.devicePrivKey),
           let data = Data(base64Encoded: raw),
           let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return "ed25519:" + priv.publicKey.rawRepresentation.base64EncodedString()
        }
        let priv = Curve25519.Signing.PrivateKey()
        KeychainStore.set(priv.rawRepresentation.base64EncodedString(), for: KeychainStore.devicePrivKey)
        return "ed25519:" + priv.publicKey.rawRepresentation.base64EncodedString()
    }

    func loadModels() async throws {
        models = try await api.models()
    }

    // MARK: Worker toggle

    func setWorker(_ on: Bool) {
        isWorker = on
        // Keep the screen awake while working so the (large) model download and
        // inference aren't cancelled by auto-lock / backgrounding.
        UIApplication.shared.isIdleTimerDisabled = on
        nvpLog(.info, on ? "Worker turned ON (screen kept awake)" : "Worker turned OFF")
        if on { startLoop() } else { Task { await stopLoop() } }
    }

    private func startLoop() {
        let loop = WorkerLoop(api: api, engine: engine, models: Config.modelCaps)
        self.loop = loop
        status = "working"
        Task {
            await loop.start(
                shouldRun: { [weak self] in
                    await MainActor.run { (self?.deviceState.canWork ?? false) && (self?.isWorker ?? false) }
                },
                onStatus: { [weak self] msg in await MainActor.run { self?.status = msg } },
                onActivity: { [weak self] act in await MainActor.run { self?.activity = act } },
                onQueue: { [weak self] depth in await MainActor.run { self?.queueDepth = depth } },
                onJob: { [weak self] outcome in await self?.handleJob(outcome) },
                onError: { [weak self] msg in await MainActor.run { self?.errorMessage = msg } }
            )
        }
        // Presence heartbeat (keeps us "online" even while the model downloads).
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.api.heartbeat()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private func stopLoop() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await loop?.stop()
        loop = nil
        status = "idle"
        activity = .idle
        queueDepth = 0
    }

    private func handleJob(_ o: JobOutcome) {
        lastLatencyMs = o.latencyMs
        tokensPerSec = o.tokensPerSec
        if o.accepted {
            jobsToday += 1
            creditsToday += o.credited
            balance = o.balance
        }
    }

    // MARK: Earnings

    func refreshEarnings() async {
        do {
            let b = try await api.balance()
            balance = b.balance
            jobsDone = b.jobsDone
            ledger = try await api.ledger()
            payoutsList = try await api.payouts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestPayout(amount: Double) async -> Bool {
        do {
            _ = try await api.requestPayout(amount: amount)
            await refreshEarnings()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: Recovery key (reconnect on another device)

    /// Human-readable recovery file contents (contains the device API key).
    var recoveryString: String? {
        guard let key = KeychainStore.get(KeychainStore.apiKeyKey),
              let wid = KeychainStore.get(KeychainStore.workerIdKey) else { return nil }
        return """
        NVP NODE — RECOVERY KEY
        Keep this private. It reconnects your worker account (and earnings) on another device.

        worker_id=\(wid)
        api_key=\(key)
        """
    }

    /// Restore an account from a pasted/imported recovery key.
    func restore(from text: String) async -> Bool {
        errorMessage = nil
        func field(_ name: String) -> String? {
            for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("\(name)=") { return String(s.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
            }
            return nil
        }
        let key = field("api_key") ?? (text.contains("nvp_live_") ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        let wid = field("worker_id")
        guard let apiKey = key, apiKey.hasPrefix("nvp_live_") else {
            errorMessage = "Invalid recovery key"
            return false
        }
        KeychainStore.set(apiKey, for: KeychainStore.apiKeyKey)
        if let wid { KeychainStore.set(wid, for: KeychainStore.workerIdKey) }
        rebuildClient()
        // Validate by fetching balance.
        do {
            let b = try await api.balance()
            balance = b.balance
            jobsDone = b.jobsDone
            workerId = wid ?? KeychainStore.get(KeychainStore.workerIdKey)
            isRegistered = true
            nvpLog(.success, "Account restored from recovery key")
            return true
        } catch {
            errorMessage = "Recovery key not accepted by coordinator"
            KeychainStore.delete(KeychainStore.apiKeyKey)
            return false
        }
    }

    // MARK: Link to chatbot account

    func linkAccount(email: String, password: String) async -> Bool {
        errorMessage = nil
        do {
            _ = try await api.link(email: email, password: password)
            linkedEmail = email
            UserDefaults.standard.set(email, forKey: "linked_email")
            nvpLog(.success, "Linked to chatbot account \(email)")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: NVP wallet (on-chain)

    /// Register the on-chain wallet address so earnings can be withdrawn to it.
    func linkWalletAddress(_ address: String) async -> Bool {
        do { try await api.linkWallet(address: address); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }

    /// Withdraw off-chain earnings as real NVP to the linked wallet. Returns tx hash.
    func withdrawEarnings(amount: Double?) async -> String? {
        do {
            let tx = try await api.walletWithdraw(amount: amount)
            await refreshEarnings()
            return tx
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func signOut() {
        KeychainStore.delete(KeychainStore.apiKeyKey)
        KeychainStore.delete(KeychainStore.workerIdKey)
        isRegistered = false
        workerId = nil
        isWorker = false
        linkedEmail = nil
        UserDefaults.standard.removeObject(forKey: "linked_email")
        UIApplication.shared.isIdleTimerDisabled = false
        Task { await stopLoop() }
    }
}
