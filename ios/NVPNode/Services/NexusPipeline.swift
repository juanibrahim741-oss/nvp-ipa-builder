import Foundation
import CoreML
import Tokenizers

/// NVP-D distributed inference (BETA, relay transport).
///
/// Two roles, both over the Vercel HTTP relay (`NexusClient`):
///  - `NexusWorker`: serves shard steps requested by others (runs a CoreML shard).
///  - `NexusPipeline`: the requesting device — tokenizes, then threads activations
///    through the shards (local executor or remote peer), samples, streams text.
///
/// Runtime correctness depends on real multi-shard `.mlmodelc` files + on-device
/// validation; this is the compiling beta scaffold of the full pipeline.

// NexusShardStore lives in NexusShards.swift (store + downloader).

/// Serializes/deserializes the relay payload for a tensor (base64 of ActivationTensor JSON).
private enum Wire {
    static func encode(_ t: ActivationTensor) -> String {
        (try? JSONEncoder().encode(t)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    static func decode(_ s: String) -> ActivationTensor? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ActivationTensor.self, from: d)
    }
}

/// Worker: answer shard-step requests from peers.
actor NexusWorker {
    private let client: NexusClient
    private let peerId: String
    private var running = false
    private var modelId: String

    init(client: NexusClient = NexusClient(), peerId: String = Config.peerId, modelId: String) {
        self.client = client; self.peerId = peerId; self.modelId = modelId
    }

    func start() {
        guard !running else { return }
        running = true
        Task { await loop() }
    }
    func stop() { running = false }

    private var execByKey: [String: CoreMLShardExecutor] = [:]

    /// Executor for a given model+shard (serves any model the device has shards for).
    private func executor(modelId: String, shard: Int) async -> CoreMLShardExecutor? {
        let key = "\(modelId)#\(shard)"
        if let e = execByKey[key] { return e }
        guard let url = NexusShardStore.shardURL(modelId: modelId, shard: shard) else { return nil }
        let e = CoreMLShardExecutor(shardIndex: shard, url: url)
        try? await e.load()
        guard await e.isLoaded else { return nil }
        execByKey[key] = e
        return e
    }

    private func loop() async {
        while running {
            let msgs = await client.poll(peerId: peerId)
            for m in msgs {
                guard (m["kind"] as? String) == "step",
                      let from = m["from"] as? String,
                      let p = m["payload"] as? [String: Any],
                      let shard = p["shard"] as? Int,
                      let tStr = p["tensor"] as? String,
                      let tensor = Wire.decode(tStr),
                      let input = tensor.toMultiArray(),
                      let exec = await executor(modelId: (p["modelId"] as? String) ?? modelId, shard: shard) else { continue }
                let inputName = (p["input"] as? String) ?? (shard == 0 ? "input_ids" : "hidden_states")
                guard let out = try? await exec.forward([inputName: input]) else { continue }
                // Forward the first output tensor (hidden_states or logits) back.
                if let first = out["logits"] ?? out["hidden_out"] ?? out["hidden_states"] ?? out.values.first {
                    let reply = ActivationTensor.from(first)
                    await client.send(from: peerId, to: from, kind: "result", payload: [
                        "job": p["job"] as? String ?? "", "shard": shard, "tensor": Wire.encode(reply),
                    ])
                }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }
}

/// Orchestrator: drive the pipeline from the requesting device.
actor NexusPipeline {
    private let client: NexusClient
    private let peerId: String
    /// Separate mailbox for shard results, so the orchestrator's own NexusWorker
    /// (polling `peerId` for "step"s) never drains the pipeline's "result"s.
    private let inbox: String
    private var tokenizer: Tokenizer?

    init(client: NexusClient = NexusClient(), peerId: String = Config.peerId) {
        self.client = client; self.peerId = peerId
        self.inbox = peerId + "#orch"
    }

    private func loadTokenizer(modelId: String) async -> Tokenizer? {
        if let t = tokenizer { return t }
        // Prefer the downloaded shard tokenizer, then a bundled one, else HF.
        if let dir = NexusShardStore.tokenizerDir(modelId),
           let t = try? await AutoTokenizer.from(modelFolder: dir) { tokenizer = t; return t }
        if let res = Bundle.main.resourceURL {
            let dir = res.appendingPathComponent("Models/\(modelId)/tokenizer")
            if FileManager.default.fileExists(atPath: dir.path),
               let t = try? await AutoTokenizer.from(modelFolder: dir) { tokenizer = t; return t }
        }
        tokenizer = try? await AutoTokenizer.from(pretrained: modelId)
        return tokenizer
    }

    /// Generate text for `prompt` by threading through `shards`, each assigned to a
    /// peer in `assignment` (peerId == local → run with `local`). Streams tokens.
    func run(prompt: String, modelId: String, shardIndices: [Int], assignment: [Int: String],
             local: NexusWorkerLocal, maxTokens: Int = 64) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                guard let tok = await loadTokenizer(modelId: modelId) else { continuation.finish(); return }
                var tokens = tok.encode(text: prompt)
                for _ in 0..<maxTokens {
                    guard let logits = await forwardAll(tokens: tokens, modelId: modelId,
                                                        shardIndices: shardIndices, assignment: assignment, local: local)
                    else { break }
                    let next = argmax(logits)
                    tokens.append(next)
                    let piece = tok.decode(tokens: [next])
                    continuation.yield(piece)
                    if next == 0 { break } // crude EOS guard
                }
                continuation.finish()
            }
        }
    }

    /// One full forward pass across all shards → logits.
    private func forwardAll(tokens: [Int], modelId: String, shardIndices: [Int],
                            assignment: [Int: String], local: NexusWorkerLocal) async -> MLMultiArray? {
        // Shard 0 input is token ids; later shards take hidden states.
        guard var current = try? makeInputIds(tokens) else { return nil }
        for shard in shardIndices.sorted() {
            let peer = assignment[shard] ?? peerId
            let inputName = shard == shardIndices.min() ? "input_ids" : "hidden_states"
            if peer == peerId {
                guard let out = await local.run(shard: shard, inputName: inputName, input: current) else { return nil }
                current = out
            } else {
                let payload: [String: Any] = [
                    "job": UUID().uuidString, "shard": shard, "modelId": modelId,
                    "input": inputName, "tensor": Wire.encode(ActivationTensor.from(current)),
                ]
                await client.send(from: inbox, to: peer, kind: "step", payload: payload)
                guard let result = await awaitResult(shard: shard) else { return nil }
                current = result
            }
        }
        return current
    }

    private func awaitResult(shard: Int, timeoutMs: Int = 30_000) async -> MLMultiArray? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            let msgs = await client.poll(peerId: inbox)
            for m in msgs where (m["kind"] as? String) == "result" {
                if let p = m["payload"] as? [String: Any], (p["shard"] as? Int) == shard,
                   let s = p["tensor"] as? String, let t = Wire.decode(s) { return t.toMultiArray() }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return nil
    }

    private func makeInputIds(_ tokens: [Int]) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
        for (i, t) in tokens.enumerated() { arr[i] = NSNumber(value: t) } // contiguous
        return arr
    }

    private func argmax(_ logits: MLMultiArray) -> Int {
        // Last position's vocab vector → argmax. Assumes [..., vocab] last dim.
        let vocab = logits.shape.last?.intValue ?? logits.count
        let offset = logits.count - vocab
        var best = 0; var bestVal = -Double.greatestFiniteMagnitude
        for v in 0..<vocab {
            let val = logits[offset + v].doubleValue
            if val > bestVal { bestVal = val; best = v }
        }
        return best
    }
}

/// Thin wrapper so the orchestrator can run a shard locally (own executors).
actor NexusWorkerLocal {
    private var executors: [Int: CoreMLShardExecutor] = [:]
    private let modelId: String
    init(modelId: String) { self.modelId = modelId }
    func run(shard: Int, inputName: String, input: MLMultiArray) async -> MLMultiArray? {
        let exec: CoreMLShardExecutor
        if let e = executors[shard] { exec = e }
        else {
            guard let url = NexusShardStore.shardURL(modelId: modelId, shard: shard) else { return nil }
            exec = CoreMLShardExecutor(shardIndex: shard, url: url)
            try? await exec.load()
            guard await exec.isLoaded else { return nil }
            executors[shard] = exec
        }
        guard let out = try? await exec.forward([inputName: input]) else { return nil }
        return out["logits"] ?? out["hidden_out"] ?? out["hidden_states"] ?? out.values.first
    }
}
