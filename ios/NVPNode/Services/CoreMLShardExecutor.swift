import Foundation
import CoreML

/// Runs one CoreML model shard (a `.mlmodelc`) for the NVP-D pipeline.
///
/// A shard takes either `input_ids` (first shard) or `hidden_states` (later
/// shards) and produces `hidden_states` (or `logits` on the last shard). Between
/// devices we serialize the activation tensor as raw bytes (`ActivationTensor`)
/// and relay it via NexusClient.
struct ActivationTensor: Codable {
    let shape: [Int]
    let dtype: String   // "float16" | "float32" | "int32"
    let base64: String  // raw little-endian bytes

    static func from(_ a: MLMultiArray) -> ActivationTensor {
        let count = a.count
        let bytes: Data
        let dtype: String
        switch a.dataType {
        case .float16: bytes = Data(bytes: a.dataPointer, count: count * 2); dtype = "float16"
        case .float32: bytes = Data(bytes: a.dataPointer, count: count * 4); dtype = "float32"
        case .int32:   bytes = Data(bytes: a.dataPointer, count: count * 4); dtype = "int32"
        default:       bytes = Data(bytes: a.dataPointer, count: count * 4); dtype = "float32"
        }
        return ActivationTensor(shape: a.shape.map { $0.intValue }, dtype: dtype, base64: bytes.base64EncodedString())
    }

    func toMultiArray() -> MLMultiArray? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        let type: MLMultiArrayDataType = dtype == "float16" ? .float16 : (dtype == "int32" ? .int32 : .float32)
        guard let arr = try? MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type) else { return nil }
        data.withUnsafeBytes { src in
            if let base = src.baseAddress { memcpy(arr.dataPointer, base, min(data.count, arr.count * stride(for: type))) }
        }
        return arr
    }

    private func stride(for t: MLMultiArrayDataType) -> Int { t == .float16 ? 2 : 4 }
}

actor CoreMLShardExecutor {
    let shardIndex: Int
    private var model: MLModel?
    private let url: URL

    init(shardIndex: Int, url: URL) { self.shardIndex = shardIndex; self.url = url }

    func load() throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all // CPU + GPU + Neural Engine
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        model = try MLModel(contentsOf: compiled, configuration: cfg)
    }

    var isLoaded: Bool { model != nil }
    func unload() { model = nil }

    /// Run the shard. `inputs` keys must match the CoreML model's input feature
    /// names (e.g. "input_ids" or "hidden_states"). Returns the named outputs.
    func forward(_ inputs: [String: MLMultiArray]) throws -> [String: MLMultiArray] {
        guard let model else { throw NexusMLError.notLoaded }
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
        let out = try model.prediction(from: provider)
        var result: [String: MLMultiArray] = [:]
        for name in out.featureNames {
            if let v = out.featureValue(for: name)?.multiArrayValue { result[name] = v }
        }
        return result
    }
}

enum NexusMLError: Error, LocalizedError {
    case notLoaded, badInput
    var errorDescription: String? { self == .notLoaded ? "Shard model not loaded" : "Bad shard input" }
}
