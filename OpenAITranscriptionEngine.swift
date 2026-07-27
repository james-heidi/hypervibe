//
//  OpenAITranscriptionEngine.swift
//  HyperVibe
//
//  Buffers push-to-talk PCM and uploads a temp WAV to OpenAI transcriptions.
//

import Foundation

final class OpenAITranscriptionEngine: TranscriptionEngine {
    let id: TranscriptionEngineID = .openAI
    var displayName: String { id.displayName }
    private(set) var state: TranscriptionEngineState = .idle
    var onState: ((TranscriptionEngineState) -> Void)?

    private let queue = DispatchQueue(label: "com.hypervibe.openai-transcription")
    private var samples = [Int16]()
    private var sampleRate: Double = 48_000
    private var generation = UUID()
    private var session: URLSession

    /// Injectable for tests.
    var transport: ((URLRequest, Data) throws -> (HTTPURLResponse, Data))?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func prepare(completion: ((Bool) -> Void)?) {
        if TranscriptionKeychain.hasOpenAIKey {
            publish(.ready)
            completion?(true)
        } else {
            publish(.needsSetup("需设置 OpenAI Key"))
            completion?(false)
        }
    }

    @discardableResult
    func startUtterance() -> Bool {
        guard TranscriptionKeychain.hasOpenAIKey else {
            publish(.needsSetup("需设置 OpenAI Key"))
            return false
        }
        generation = UUID()
        queue.async { [weak self] in
            self?.samples.removeAll(keepingCapacity: true)
        }
        publish(.listening)
        return true
    }

    func append(pcmS16 samples: [Int16], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.sampleRate = sampleRate
            if self.samples.count < Int(sampleRate) * 60 {
                self.samples.append(contentsOf: samples)
            }
        }
    }

    func finishUtterance(completion: @escaping (Result<String?, Error>) -> Void) {
        publish(.recognizing)
        // Snapshot synchronously so a subsequent startUtterance cannot wipe in-flight audio.
        let (pcm, rate): ([Int16], Int) = queue.sync {
            let captured = samples
            samples.removeAll(keepingCapacity: true)
            return (captured, Int(sampleRate))
        }
        guard pcm.count >= 12_000 else {
            publish(.ready)
            rmDebug("🎤 OpenAI skip short clip samples=\(pcm.count)")
            DispatchQueue.main.async { completion(.success(nil)) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let text = try self.transcribe(samples: pcm, sampleRate: rate)
                self.publish(.ready)
                rmDebug("🎤 OpenAI result samples=\(pcm.count) text=\(text ?? "<empty>")")
                DispatchQueue.main.async { completion(.success(text)) }
            } catch {
                self.publish(.ready)
                rmDebug("🎤 OpenAI error: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func cancel() {
        generation = UUID()
        queue.async { [weak self] in
            self?.samples.removeAll(keepingCapacity: true)
        }
        publish(.ready)
    }

    // MARK: - Networking helpers (testable)

    static func makeMultipartBody(
        boundary: String,
        model: String,
        fileName: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        func append(_ string: String) {
            if let data = string.data(using: .utf8) {
                body.append(data)
            }
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(fileData)
        append("\r\n")
        append("--\(boundary)--\r\n")
        return body
    }

    static func parseTranscriptJSON(_ data: Data) throws -> String {
        struct Response: Decodable { let text: String? }
        if let decoded = try? JSONDecoder().decode(Response.self, from: data),
           let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        throw TranscriptionEngineError.backend("OpenAI response missing text: \(raw.prefix(200))")
    }

    private func transcribe(samples: [Int16], sampleRate: Int) throws -> String? {
        guard let apiKey = TranscriptionKeychain.loadOpenAIKey() else {
            throw TranscriptionEngineError.missingAPIKey
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hypervibe-openai-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try PCMWaveWriter.write(samples: PCMWaveWriter.boostForASR(samples), sampleRate: sampleRate, to: url)
        let fileData = try Data(contentsOf: url)
        let boundary = "HyperVibeBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let model = TranscriptionEngineID.openAIModel
        let body = Self.makeMultipartBody(
            boundary: boundary,
            model: model,
            fileName: "utterance.wav",
            fileData: fileData
        )
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let responseData: Data
        let http: HTTPURLResponse
        if let transport {
            (http, responseData) = try transport(request, body)
        } else {
            let semaphore = DispatchSemaphore(value: 0)
            var captured: (Data?, URLResponse?, Error?)
            session.uploadTask(with: request, from: body) { data, response, error in
                captured = (data, response, error)
                semaphore.signal()
            }.resume()
            semaphore.wait()
            if let error = captured.2 {
                throw TranscriptionEngineError.network(error.localizedDescription)
            }
            guard let data = captured.0,
                  let response = captured.1 as? HTTPURLResponse else {
                throw TranscriptionEngineError.network("empty OpenAI response")
            }
            http = response
            responseData = data
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: responseData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw TranscriptionEngineError.network("OpenAI \(http.statusCode): \(message.prefix(240))")
        }
        let text = try Self.parseTranscriptJSON(responseData)
        return text.isEmpty ? nil : text
    }

    private func publish(_ state: TranscriptionEngineState) {
        self.state = state
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onState?(state)
        }
    }
}
