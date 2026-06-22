import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Gemma4SwiftCore

/// Real on-device inference via MLX Swift (mlx-swift-lm 2.30.x).
///
/// Supports **Gemma 4 E2B** through the `Gemma4SwiftCore` sidecar
/// (github.com/yejingyang8963-byte/Swift-gemma4-core) — the first native Swift
/// Gemma 4 decoder — plus Gemma 3 / Gemma 3n / Qwen via the built-in registry.
/// Greedy decoding (temperature 0) keeps output deterministic for verification.
final class MLXInferenceEngine: InferenceEngine {
    private var container: ModelContainer?
    private var isGemma4 = false
    var isLoaded: Bool { container != nil }
    var progressHandler: ((Double, Int64, Int64) -> Void)?

    func load(modelDir: URL?) async throws {
        if container != nil { return }
        // Memory safety (prevents the OOM/jetsam crash with large models like
        // Gemma 4): keep the reuse-cache small, and set a *soft* memory limit at
        // the device's recommended working set so MLX evicts buffers instead of
        // letting the app blow past its jetsam budget and get killed.
        MLX.GPU.set(cacheLimit: Config.gpuCacheLimitBytes)
        if let ws = MLX.GPU.maxRecommendedWorkingSetBytes(), ws > 0 {
            MLX.GPU.set(memoryLimit: ws, relaxed: true)
        }
        MLX.GPU.clearCache()

        let id = Config.effectiveModelId
        isGemma4 = (id == "gemma4_e2b")
        // Gemma 4 needs its sidecar model type registered before any load.
        if isGemma4 { await Gemma4Registration.registerIfNeeded().value }

        let configuration: ModelConfiguration
        if let dir = Config.bundledModelDir(id) {
            // Pre-installed in the IPA → load straight from the bundle (no download).
            configuration = ModelConfiguration(directory: dir)
            nvpLog(.info, "Loading bundled model \(id) from app (no download)")
        } else {
            switch id {
            case "gemma4_e2b":
                configuration = ModelConfiguration(id: Gemma4SwiftCore.verifiedModelId)
            case "gemma3n_e2b":
                configuration = LLMRegistry.gemma3n_E2B_it_lm_4bit
            case "gemma3_1b":
                configuration = LLMRegistry.gemma3_1B_qat_4bit
            default:
                // Qwen, Phi-4-mini, Llama 3.2 3B (incl. uncensored/abliterated):
                // standard architectures the MLX factory dispatches by config.json.
                configuration = ModelConfiguration(id: Config.hfRepo(for: id))
            }
        }

        let handler = progressHandler
        container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration,
            progressHandler: { progress in
                handler?(progress.fractionCompleted, progress.completedUnitCount, progress.totalUnitCount)
            }
        )
        handler?(1.0, 0, 0)
    }

    func generate(prompt: String, maxTokens: Int, reasoning: Bool) async throws -> GenResult {
        guard let container else { throw NVPError.notLoaded }
        let start = Date()
        var params = GenerateParameters(temperature: 0) // greedy
        params.maxTokens = maxTokens
        // Bound + quantize the KV cache so memory stays flat as the answer grows
        // — this is what keeps large models (Gemma 4) from OOM-crashing the app.
        params.kvBits = 8
        params.kvGroupSize = 64
        params.quantizedKVStart = 0
        params.maxKVSize = 4096
        params.prefillStepSize = 256

        // Always release transient GPU buffers afterwards, even on error.
        defer { MLX.GPU.clearCache() }

        let text: String
        if isGemma4 {
            // Gemma 4: use the package's chat-template bypass (applyChatTemplate is
            // broken for Gemma 4) + the streaming generate API. Reasoning mode adds
            // a hidden <|think|> chain-of-thought we strip before returning.
            let formatted = reasoning
                ? Gemma4PromptFormatter.userTurnWithThinking(prompt)
                : Gemma4PromptFormatter.userTurn(prompt)
            let tokens = await container.encode(formatted)
            let input = LMInput(tokens: MLXArray(tokens))
            let stream = try await container.generate(input: input, parameters: params)
            var acc = ""
            for await event in stream {
                if case .chunk(let s) = event { acc += s }
            }
            text = reasoning ? Self.stripThinking(acc) : acc
        } else {
            // Gemma 3 / 3n / Qwen: ChatSession applies the correct chat template.
            let session = ChatSession(container, generateParameters: params)
            text = try await session.respond(to: prompt)
        }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return GenResult(text: text, tokensOut: max(1, text.count / 4), latencyMs: ms)
    }

    func unload() {
        container = nil
        isGemma4 = false
        MLX.GPU.clearCache()
    }

    /// Gemma 4 thinking mode emits a `<|channel>thought … <channel|>` block before
    /// the final answer. Return only the answer (everything after the last
    /// `<channel|>`), stripping any leftover channel markers.
    private static func stripThinking(_ s: String) -> String {
        var out = s
        if let r = out.range(of: "<channel|>", options: .backwards) {
            out = String(out[r.upperBound...])
        }
        for marker in ["<|channel>", "<channel|>", "<|think|>", "thought"] {
            if out.hasPrefix(marker) { out = String(out.dropFirst(marker.count)) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum NVPError: Error, LocalizedError {
    case notLoaded
    var errorDescription: String? { "Inference engine not loaded" }
}
