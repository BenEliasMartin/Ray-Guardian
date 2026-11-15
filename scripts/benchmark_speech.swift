import Foundation

@main
enum BenchmarkSpeech {
    struct Measurement: Encodable {
        let decision: String
        let medianMs: Double
    }

    static func main() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let utterances = try JSONDecoder().decode([String].self, from: input)
        let measurements = utterances.map { utterance in
            func classify() -> String {
                let intent = KeywordDetector.intent(utterance, isFinal: true, confidence: 0.9)
                return intent == .distress || intent == .threat || intent == .sos ? "check_in" : "no_check_in"
            }
            for _ in 0..<20 { _ = classify() }
            var decision = ""
            let samples = (0..<100).map { _ in
                let start = DispatchTime.now().uptimeNanoseconds
                decision = classify()
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }.sorted()
            return Measurement(decision: decision, medianMs: (samples[49] + samples[50]) / 2)
        }
        let encoded = try JSONEncoder().encode(measurements)
        FileHandle.standardOutput.write(encoded)
    }
}
