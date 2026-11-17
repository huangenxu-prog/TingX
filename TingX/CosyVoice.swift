import FluidAudio
import Foundation

actor CosyVoice {
    private let directory: URL
    private var manager: CosyVoice3TtsManager?
    private var prompt: CosyVoice3PromptAssets?

    init(directory: URL) { self.directory = directory }

    func audio(for text: String) async throws -> Data {
        let engine: CosyVoice3TtsManager
        if let manager { engine = manager }
        else {
            engine = CosyVoice3TtsManager(
                modelsDirectory: directory,
                tokenizerDirectory: directory.appendingPathComponent("tokenizer"),
                textEmbeddingsFile: directory.appendingPathComponent("embeddings/embeddings-runtime-fp32.safetensors"),
                specialTokensFile: directory.appendingPathComponent("tokenizer/special_tokens.json"))
            try await engine.initialize()
            try Task.checkCancellation()
            prompt = try CosyVoice3PromptAssets.load(from: directory.appendingPathComponent("voices/cosyvoice3-default-zh.safetensors"))
            manager = engine
        }
        try Task.checkCancellation()
        guard let prompt else { throw CocoaError(.fileReadCorruptFile) }
        let result = try await engine.synthesize(text: text, promptAssets: prompt)
        try Task.checkCancellation()
        let samples = result.samples
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }),
              samples.contains(where: { abs($0) > 0.0001 }) else {
            let finite = samples.filter { $0.isFinite }.count
            print("Invalid PCM: tokens=\(result.generatedTokenCount), samples=\(samples.count), finite=\(finite)")
            throw NSError(domain: "TingX", code: 1, userInfo: [NSLocalizedDescriptionKey: "语音引擎未生成有效声音。"])
        }
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }
        append(UInt32(36 + samples.count * 2))
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(24_000)); append(UInt32(48_000)); append(UInt16(2)); append(UInt16(16))
        wav.append(Data("data".utf8)); append(UInt32(samples.count * 2))
        for sample in samples { append(Int16(max(-1, min(1, sample)) * 32767)) }
        return wav
    }
}
