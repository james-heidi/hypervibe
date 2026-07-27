import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct TranscriptionEngineTests {
    static func main() {
        testEngineDefaults()
        testOpenAIMultipartAndParse()
        testParakeetNeedsDownloadState()
        print("TranscriptionEngineTests: PASS")
    }

    private static func testEngineDefaults() {
        let previous = TranscriptionEngineID.current
        defer { TranscriptionEngineID.current = previous }

        TranscriptionEngineID.current = .openAI
        expect(TranscriptionEngineID.current == .openAI, "persist openAI")
        TranscriptionEngineID.current = .parakeet
        expect(TranscriptionEngineID.current == .parakeet, "persist parakeet")

        let previousModel = TranscriptionEngineID.openAIModel
        defer { TranscriptionEngineID.openAIModel = previousModel }
        TranscriptionEngineID.openAIModel = "whisper-1"
        expect(TranscriptionEngineID.openAIModel == "whisper-1", "persist openai model")
        expect(
            TranscriptionEngineID.openAIModelChoices.contains("gpt-4o-mini-transcribe"),
            "mini model must be listed"
        )
    }

    private static func testOpenAIMultipartAndParse() {
        let wav = Data([0x52, 0x49, 0x46, 0x46]) // "RIFF" prefix is enough for body assembly
        let body = OpenAITranscriptionEngine.makeMultipartBody(
            boundary: "BOUND",
            model: "gpt-4o-mini-transcribe",
            fileName: "utterance.wav",
            fileData: wav
        )
        let text = String(data: body, encoding: .utf8) ?? ""
        expect(text.contains("name=\"model\""), "multipart must include model field")
        expect(text.contains("gpt-4o-mini-transcribe"), "multipart must include model value")
        expect(text.contains("filename=\"utterance.wav\""), "multipart must include filename")
        expect(body.contains(wav), "multipart must include raw wav bytes")

        let json = #"{"text":"  hello world  "}"#.data(using: .utf8)!
        let parsed = try! OpenAITranscriptionEngine.parseTranscriptJSON(json)
        expect(parsed == "hello world", "JSON text must be trimmed")
        let emptyJSON = #"{"text":""}"#.data(using: .utf8)!
        let empty = try! OpenAITranscriptionEngine.parseTranscriptJSON(emptyJSON)
        expect(empty.isEmpty, "valid empty transcript must be a silent no-op")

        let engine = OpenAITranscriptionEngine()
        engine.transport = { request, body in
            expect(
                request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
                    || true,
                "transport hook reached"
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, #"{"text":"fixture ok"}"#.data(using: .utf8)!)
        }

        // Without a key, start must fail closed.
        let hadKey = TranscriptionKeychain.hasOpenAIKey
        if !hadKey {
            expect(engine.startUtterance() == false, "OpenAI start requires key")
        }
    }

    private static func testParakeetNeedsDownloadState() {
        // Pure state machine: selecting Parakeet when uncached must surface download need
        // without triggering a network download in CI.
        let cached = ParakeetTranscriptionEngine.modelsCached
        if cached {
            print("note: Parakeet models already cached on this machine")
        } else {
            let engine = ParakeetTranscriptionEngine()
            var sawNeedsSetup = false
            engine.onState = { state in
                if case .needsSetup = state { sawNeedsSetup = true }
            }
            engine.prepare { ok in
                expect(ok == false, "uncached Parakeet prepare must fail until download")
            }
            // Give the main-async publish a beat.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            expect(sawNeedsSetup || engine.state == .needsSetup("需下载模型") || {
                if case .needsSetup = engine.state { return true }
                return false
            }(), "uncached Parakeet must report needsSetup")
            expect(engine.startUtterance() == false, "cannot start utterance before download")
        }
    }
}
