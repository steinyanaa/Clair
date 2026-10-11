import AVFoundation
import Foundation

// Make a public fixture for sustained realtime tests, never classroom audio.
let source = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let output = try AVAudioFile(forWriting: destination, settings: source.processingFormat.settings)
let count = Int(CommandLine.arguments[3])!
let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192)!
for _ in 0..<count {
    source.framePosition = 0
    while source.framePosition < source.length {
        try source.read(into: buffer)
        try output.write(from: buffer)
    }
}
print("fixtureSeconds=\(Double(source.length) * Double(count) / source.processingFormat.sampleRate)")
