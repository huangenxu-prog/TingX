import Foundation

let path = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let voice = CosyVoice(directory: path)
let data = try await voice.audio(for: "春天到了。")
precondition(data.count > 4844)
try data.write(to: URL(fileURLWithPath: "cosyvoice-check.wav"))
print("Generated \((data.count - 44) / 2) PCM samples")
