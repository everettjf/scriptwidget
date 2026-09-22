// Local screenshot inspection only. OCR is a review signal, not a visual-quality proof.
import Foundation
import Vision
import ImageIO

struct Sample: Decodable {
    let id: String
    let attempt: Int
    let expectedText: [String]?
    let screenshots: [String]
}
struct Observation: Encodable {
    let image: String
    let recognizedText: String
    let unrecognizedExpectedText: [String]
}
func normalized(_ text: String) -> String {
    String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
}
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Scripts/ai-quality-images.swift /absolute/artifact/directory")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: directory.appendingPathComponent("quality.json")))
var observations: [Observation] = []
for sample in samples {
    for filename in sample.screenshots {
        // Only inspect locally generated flat PNG names, never arbitrary report paths.
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.contains(".."), filename.hasSuffix(".png") else { fatalError("Invalid screenshot filename") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let hasChinese = (sample.expectedText ?? []).joined().unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        request.recognitionLanguages = hasChinese ? ["zh-Hans", "en-US"] : ["en-US"]
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(url: directory.appendingPathComponent(filename)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        let absent = (sample.expectedText ?? []).filter { !normalized(text).contains(normalized($0)) }
        observations.append(.init(image: filename, recognizedText: text, unrecognizedExpectedText: absent))
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(observations).write(to: directory.appendingPathComponent("vision.json"), options: .atomic)
print("OCR inspected \(observations.count) screenshots; \(observations.filter { !$0.unrecognizedExpectedText.isEmpty }.count) need review.")
