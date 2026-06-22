import Foundation

struct JobOutcome {
    let accepted: Bool
    let credited: Double
    let balance: Double
    let latencyMs: Int
    let tokensPerSec: Double
}

/// Live worker phase, for the animated network/activity view.
enum WorkerActivity: String, Sendable {
    case idle
    case loadingModel
    case waiting
    case receivedJob
    case inferring
    case submitting
}

/// Drives the worker lifecycle with a small local **job queue**: a producer
/// long-polls the coordinator and pre-fetches up to `maxQueue` jobs while a single
/// consumer runs inference back-to-back (the GPU is single-threaded, so we keep it
/// busy rather than running jobs in parallel). This lets one device accept more
/// requests without going idle between them, and exposes queue depth + speed.
actor WorkerLoop {
    private let api: APIClient
    private let engine: InferenceEngine
    private let models: [String]
    private let maxQueue = Config.maxQueueDepth

    private var pending: [Job] = []
    private var producer: Task<Void, Never>?
    private var consumer: Task<Void, Never>?

    init(api: APIClient, engine: InferenceEngine, models: [String]) {
        self.api = api
        self.engine = engine
        self.models = models
    }

    private func enqueue(_ job: Job) { pending.append(job) }
    private func dequeue() -> Job? { pending.isEmpty ? nil : pending.removeFirst() }
    private var queueDepth: Int { pending.count }

    /// - shouldRun: evaluated each iteration (foreground + thermal ok).
    /// - onStatus: lifecycle/status updates for the UI (e.g. "Loading model…").
    /// - onQueue: current local queue depth (jobs waiting to be processed).
    /// - onJob: called after each processed job with the outcome.
    /// - onError: called on transient errors (kept non-fatal).
    func start(
        shouldRun: @escaping @Sendable () async -> Bool,
        onStatus: @escaping @Sendable (String) async -> Void,
        onActivity: @escaping @Sendable (WorkerActivity) async -> Void,
        onQueue: @escaping @Sendable (Int) async -> Void,
        onJob: @escaping @Sendable (JobOutcome) async -> Void,
        onError: @escaping @Sendable (String) async -> Void
    ) {
        guard producer == nil, consumer == nil else { return }
        producer = Task { await self.runProducer(shouldRun: shouldRun, onQueue: onQueue, onError: onError) }
        consumer = Task {
            await self.runConsumer(
                shouldRun: shouldRun, onStatus: onStatus, onActivity: onActivity,
                onQueue: onQueue, onJob: onJob, onError: onError
            )
        }
    }

    /// Pre-fetches jobs into the local queue (only once the model is loaded, so we
    /// never claim work we can't yet run).
    private func runProducer(
        shouldRun: @escaping @Sendable () async -> Bool,
        onQueue: @escaping @Sendable (Int) async -> Void,
        onError: @escaping @Sendable (String) async -> Void
    ) async {
        while !Task.isCancelled {
            if await !shouldRun() || !engine.isLoaded || pending.count >= maxQueue {
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            do {
                if let job = try await api.nextJob(models: models) {
                    enqueue(job)
                    await onQueue(queueDepth)
                    nvpLog(.info, "Job \(job.jobId) queued (\(job.model)) · depth \(queueDepth)")
                }
            } catch is CancellationError {
                return
            } catch {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Loads the model, then drains the queue: infer → submit, back-to-back.
    private func runConsumer(
        shouldRun: @escaping @Sendable () async -> Bool,
        onStatus: @escaping @Sendable (String) async -> Void,
        onActivity: @escaping @Sendable (WorkerActivity) async -> Void,
        onQueue: @escaping @Sendable (Int) async -> Void,
        onJob: @escaping @Sendable (JobOutcome) async -> Void,
        onError: @escaping @Sendable (String) async -> Void
    ) async {
        while !Task.isCancelled {
            if await !shouldRun() {
                await onActivity(.idle)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            // Lazy-load the model. Bundled models load straight from the IPA;
            // otherwise the first run downloads it.
            if !engine.isLoaded {
                do {
                    await onActivity(.loadingModel)
                    await onStatus("Loading model…")
                    nvpLog(.info, "Loading on-device model…")
                    try await engine.load(modelDir: nil)
                    await onStatus("working")
                    nvpLog(.success, "Model loaded — ready to work")
                } catch is CancellationError {
                    return
                } catch {
                    await onError("Model load failed: \(error.localizedDescription)")
                    nvpLog(.error, "Model load failed: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
            }

            guard let job = dequeue() else {
                await onActivity(.waiting)
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            await onQueue(queueDepth)
            await onActivity(.receivedJob)

            do {
                let maxTokens = min(Config.maxTokensCap, job.params?.maxTokens ?? Config.defaultMaxTokens)
                let reasoning = job.params?.reasoning ?? false
                await onActivity(.inferring)
                let gen = try await engine.generate(prompt: job.prompt, maxTokens: maxTokens, reasoning: reasoning)
                let tps = gen.latencyMs > 0 ? Double(gen.tokensOut) / (Double(gen.latencyMs) / 1000.0) : 0
                nvpLog(.info, String(format: "Inferred %d tok in %d ms (%.1f tok/s)", gen.tokensOut, gen.latencyMs, tps))
                await onActivity(.submitting)
                let res = try await api.submitResult(
                    jobId: job.jobId,
                    output: gen.text,
                    latencyMs: gen.latencyMs,
                    tokensOut: gen.tokensOut
                )
                if res.accepted {
                    nvpLog(.success, "Accepted +$\(String(format: "%.6f", res.credited)) · bal $\(String(format: "%.4f", res.balance))")
                } else {
                    nvpLog(.warn, "Rejected: \(res.reason ?? "verification failed")")
                }
                await onJob(JobOutcome(
                    accepted: res.accepted,
                    credited: res.credited,
                    balance: res.balance,
                    latencyMs: gen.latencyMs,
                    tokensPerSec: tps
                ))
            } catch is CancellationError {
                return
            } catch {
                await onError(error.localizedDescription)
                nvpLog(.error, error.localizedDescription)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        producer?.cancel()
        consumer?.cancel()
        producer = nil
        consumer = nil
        pending.removeAll()
        engine.unload()
    }
}
