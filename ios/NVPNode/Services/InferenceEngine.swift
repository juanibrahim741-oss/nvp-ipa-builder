import Foundation

struct GenResult {
    let text: String
    let tokensOut: Int
    let latencyMs: Int
}

/// On-device inference (docs/06 §6). Greedy, deterministic, stop on <end_of_turn>.
///
/// v0 bring-up uses `StubInferenceEngine` so the full worker loop + UI + earning
/// path build and run with zero external dependencies. The next milestone swaps
/// in a real MLX-backed engine (Qwen2.5-0.5B natively, then the Gemma 4 E2B port)
/// behind this same protocol — `WorkerLoop` doesn't change.
protocol InferenceEngine: AnyObject {
    var isLoaded: Bool { get }
    /// Reports model download/load progress: (fraction 0...1, completedBytes, totalBytes).
    var progressHandler: ((Double, Int64, Int64) -> Void)? { get set }
    /// Load weights + tokenizer from a local directory.
    func load(modelDir: URL?) async throws
    /// Greedy generation for a single user prompt. When `reasoning` is true and the
    /// model supports it (Gemma 4), think step-by-step before answering.
    func generate(prompt: String, maxTokens: Int, reasoning: Bool) async throws -> GenResult
    /// Free memory when the worker goes OFF / app backgrounds.
    func unload()
}

/// Placeholder engine: returns a deterministic stub. It does NOT run a model, so
/// it will (correctly) fail hidden canary checks — that's expected until the real
/// MLX engine is wired in. Real chatbot answers require the real engine.
final class StubInferenceEngine: InferenceEngine {
    private(set) var isLoaded = false
    var progressHandler: ((Double, Int64, Int64) -> Void)?

    func load(modelDir: URL?) async throws {
        // Simulate a short load.
        try? await Task.sleep(nanoseconds: 200_000_000)
        isLoaded = true
    }

    func generate(prompt: String, maxTokens: Int, reasoning: Bool) async throws -> GenResult {
        let start = Date()
        // Pretend to think briefly, scaled by requested length.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let text = "[stub] received \(prompt.count) chars; real on-device inference lands in the next build."
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return GenResult(text: text, tokensOut: max(1, text.count / 4), latencyMs: ms)
    }

    func unload() { isLoaded = false }
}

/// Builds the Gemma chat prompt literally (docs/06 §3). Not used by the stub, but
/// kept here so the real engine swap is a drop-in.
enum GemmaPrompt {
    static func build(userPrompt: String) -> String {
        "<bos><start_of_turn>user\n\(userPrompt)<end_of_turn>\n<start_of_turn>model\n"
    }
}
