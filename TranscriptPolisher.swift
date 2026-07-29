//
//  TranscriptPolisher.swift
//  HyperVibe
//
//  Optional post-ASR light cleanup. Prefers Apple Foundation Models locally,
// falls back to an OpenAI mini model, and always fails open to the raw transcript.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Mode

enum TranscriptPolishMode: String, CaseIterable {
    case automatic
    case local
    case cloud
    case off

    static let defaultsKey = "transcriptPolishMode"

    static var current: TranscriptPolishMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let mode = TranscriptPolishMode(rawValue: raw) else {
                return .automatic
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var displayName: String {
        switch self {
        case .automatic: return "自动（本地 → 云端）"
        case .local: return "仅本地"
        case .cloud: return "Cloud Mini"
        case .off: return "关闭"
        }
    }
}

// MARK: - Backend protocol

protocol TranscriptPolishBackend: AnyObject {
    var isAvailable: Bool { get }
    /// Polish `text` under `instructions`. Throw or return empty to signal failure.
    /// Implementations must honour `generation` by returning empty when cancelled.
    func polish(
        _ text: String,
        instructions: String,
        generation: UUID,
        isCurrent: @escaping () -> Bool
    ) async throws -> String
}

enum TranscriptPolishError: Error {
    case unavailable
    case cancelled
    case emptyResult
    case network(String)
    case backend(String)
}

// MARK: - Shared instructions / helpers

enum TranscriptPolishPrompt {
    /// Keep this short — every token adds cloud TTFT latency.
    static let instructions = """
    Lightly clean a speech transcript. Remove fillers (uh/um/like/嗯/啊/那个) and stutters. Fix punctuation/casing/obvious ASR typos. Preserve meaning, language mix, code, URLs, numbers. Return only the cleaned text.
    """

    /// Below this length, polish latency is not worth it.
    static let minimumLength = 12

    static func shouldSkip(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count < minimumLength { return true }
        // Already-clean short utterances: skip the round trip.
        if looksAlreadyClean(trimmed) { return true }
        return false
    }

    /// Heuristic: no common fillers and already has end punctuation / no obvious ASR junk.
    static func looksAlreadyClean(_ text: String) -> Bool {
        let lower = text.lowercased()
        let fillers = [" uh", " um", " er", " ah", "like,", "you know", "嗯", "啊", "那个", "就是说"]
        if fillers.contains(where: { lower.contains($0) }) { return false }
        // Very short, no filler — typing delay from polish isn't worth it.
        if text.count <= 24 { return true }
        return false
    }

    static func sanitizeResult(_ polished: String, raw: String) -> String {
        let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return raw }
        // Polish is a light edit: filler removal shrinks text, casing/punctuation
        // barely grows it. Output much longer than the input means the model
        // rambled or hallucinated a continuation — fail open to the raw text.
        if trimmed.count > raw.count + max(16, raw.count / 4) { return raw }
        // Strip accidental wrapping quotes from overly obedient models.
        if trimmed.count >= 2,
           (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("“") && trimmed.hasSuffix("”")) {
            let inner = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? raw : inner
        }
        return trimmed
    }

    /// Cap generation so the model cannot ramble past a light edit.
    static func maxOutputTokens(for input: String) -> Int {
        max(48, min(256, input.count + 32))
    }
}

// MARK: - Local backend (Apple Foundation Models)

final class LocalTranscriptPolishBackend: TranscriptPolishBackend {
    #if canImport(FoundationModels)
    /// Retained warm session so the shared on-device model stays resident and the
    /// instruction prefix is pre-encoded — the first real utterance isn't a cold load.
    @available(macOS 26, *)
    private var warmSession: LanguageModelSession? {
        get { _warmSession as? LanguageModelSession }
        set { _warmSession = newValue }
    }
    private var _warmSession: AnyObject?
    #endif

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return Self.modelAvailability() == .available
        }
        #endif
        return false
    }

    var availabilitySummary: String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch Self.modelAvailability() {
            case .available:
                return "可用"
            case .unavailable(.deviceNotEligible):
                return "设备不支持"
            case .unavailable(.appleIntelligenceNotEnabled):
                return "需开启 Apple Intelligence"
            case .unavailable(.modelNotReady):
                return "模型未就绪"
            case .unavailable:
                return "不可用"
            @unknown default:
                return "不可用"
            }
        }
        #endif
        return "需 macOS 26+"
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func modelAvailability() -> SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    /// Cleanup is an edit, not creative generation: pin low temperature for stable,
    /// repeatable output and cap tokens so it can't ramble past a light pass.
    @available(macOS 26, *)
    private static func options(for text: String) -> GenerationOptions {
        GenerationOptions(
            temperature: 0.2,
            maximumResponseTokens: TranscriptPolishPrompt.maxOutputTokens(for: text)
        )
    }
    #endif

    /// Load the shared on-device model ahead of the first utterance so its latency
    /// fits the polish budget instead of paying a cold start.
    func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard case .available = Self.modelAvailability() else { return }
            let session = warmSession ?? LanguageModelSession(
                instructions: TranscriptPolishPrompt.instructions
            )
            warmSession = session
            session.prewarm()
        }
        #endif
    }

    func polish(
        _ text: String,
        instructions: String,
        generation: UUID,
        isCurrent: @escaping () -> Bool
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard isCurrent() else { throw TranscriptPolishError.cancelled }
            guard case .available = Self.modelAvailability() else {
                throw TranscriptPolishError.unavailable
            }
            // Fresh session per utterance keeps transcripts independent (no context
            // bleed or unbounded growth); the retained warm session keeps the model hot.
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: text, options: Self.options(for: text))
            guard isCurrent() else { throw TranscriptPolishError.cancelled }
            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { throw TranscriptPolishError.emptyResult }
            return content
        }
        #endif
        throw TranscriptPolishError.unavailable
    }
}

// MARK: - Cloud backend (OpenAI Responses)

final class CloudTranscriptPolishBackend: TranscriptPolishBackend {
    /// Fastest GPT-4.1 tier — polish is a short-prompt edit, not reasoning.
    static let model = "gpt-4.1-nano"
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    /// Injectable for tests.
    var transport: ((URLRequest, Data) throws -> (HTTPURLResponse, Data))?
    private var session: URLSession
    private var task: URLSessionDataTask?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 4
            config.timeoutIntervalForResource = 4
            config.waitsForConnectivity = false
            config.httpMaximumConnectionsPerHost = 2
            // Keep TLS/session warm across utterances.
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    /// Snapshot, not a Keychain read: this is queried from the main thread to build
    /// the menu, and `SecItemCopyMatching` can block behind a SecurityAgent prompt.
    var isAvailable: Bool { TranscriptionKeychain.hasOpenAIKeyCached }

    var availabilitySummary: String {
        isAvailable ? "已配置 Key" : "需 OpenAI Key"
    }

    func cancelInFlight() {
        task?.cancel()
        task = nil
    }

    /// Fire a tiny no-op auth probe so the next real polish avoids cold TLS.
    /// The Keychain read happens off the caller's thread — prewarm runs at launch.
    func prewarm() {
        let session = self.session
        TranscriptionKeychain.withOpenAIKey { apiKey in
            guard let apiKey else { return }
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 3
            session.dataTask(with: request) { _, _, _ in }.resume()
        }
    }

    func polish(
        _ text: String,
        instructions: String,
        generation: UUID,
        isCurrent: @escaping () -> Bool
    ) async throws -> String {
        guard isCurrent() else { throw TranscriptPolishError.cancelled }
        guard let apiKey = TranscriptionKeychain.loadOpenAIKey() else {
            throw TranscriptPolishError.unavailable
        }
        let body = try Self.makeRequestBody(
            model: Self.model,
            instructions: instructions,
            input: text,
            maxOutputTokens: TranscriptPolishPrompt.maxOutputTokens(for: text)
        )
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 4
        request.httpBody = body

        let responseData: Data
        let http: HTTPURLResponse
        if let transport {
            (http, responseData) = try transport(request, body)
        } else {
            let (data, response) = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        cont.resume(throwing: TranscriptPolishError.network("empty response"))
                        return
                    }
                    cont.resume(returning: (data, response))
                }
                self.task = task
                task.resume()
            }
            self.task = nil
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranscriptPolishError.network("invalid response")
            }
            http = httpResponse
            responseData = data
        }

        guard isCurrent() else { throw TranscriptPolishError.cancelled }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: responseData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw TranscriptPolishError.network("OpenAI \(http.statusCode): \(message.prefix(240))")
        }
        let polished = try Self.parseOutputText(responseData)
        guard !polished.isEmpty else { throw TranscriptPolishError.emptyResult }
        return polished
    }

    static func makeRequestBody(
        model: String,
        instructions: String,
        input: String,
        maxOutputTokens: Int = 128
    ) throws -> Data {
        let payload: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "store": false,
            "max_output_tokens": maxOutputTokens,
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Accepts either the SDK convenience `output_text` field or the nested
    /// `output[].content[].text` / `output_text` shapes from the Responses API.
    static func parseOutputText(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptPolishError.backend("invalid JSON")
        }
        if let direct = root["output_text"] as? String {
            return direct.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let output = root["output"] as? [[String: Any]] else {
            throw TranscriptPolishError.backend("missing output")
        }
        var pieces: [String] = []
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                if let text = part["text"] as? String {
                    pieces.append(text)
                }
            }
        }
        let joined = pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty {
            throw TranscriptPolishError.backend("empty output_text")
        }
        return joined
    }
}

// MARK: - Coordinator

final class TranscriptPolisher {
    /// Overall budget for polish; on expiry the raw transcript is delivered.
    /// Kept tight — nano + short prompt should usually finish under this.
    static let budgetSeconds: TimeInterval = 1.0

    /// The on-device Apple model is free and private but slower than cloud nano;
    /// give it more headroom so its result usually lands instead of timing out to raw.
    static let localBudgetSeconds: TimeInterval = 2.5

    /// Deadline for the current mode. Cloud stays tight; anything that may run the
    /// local model (local / automatic) gets the longer on-device budget.
    static func budget(for mode: TranscriptPolishMode) -> TimeInterval {
        switch mode {
        case .local, .automatic: return localBudgetSeconds
        case .cloud, .off: return budgetSeconds
        }
    }

    private let local: TranscriptPolishBackend
    private let cloud: TranscriptPolishBackend
    private let cloudCancellable: CloudTranscriptPolishBackend?
    private var localPrewarmable: LocalTranscriptPolishBackend? { local as? LocalTranscriptPolishBackend }
    private var generation = UUID()
    private var timeoutWorkItem: DispatchWorkItem?

    /// Injectable backends for tests. Production uses the defaults.
    init(
        local: TranscriptPolishBackend = LocalTranscriptPolishBackend(),
        cloud: TranscriptPolishBackend = CloudTranscriptPolishBackend()
    ) {
        self.local = local
        self.cloud = cloud
        self.cloudCancellable = cloud as? CloudTranscriptPolishBackend
    }

    var mode: TranscriptPolishMode {
        get { TranscriptPolishMode.current }
        set {
            TranscriptPolishMode.current = newValue
            if newValue != .off {
                prewarm()
            }
        }
    }

    var localAvailabilitySummary: String {
        (local as? LocalTranscriptPolishBackend)?.availabilitySummary
            ?? (local.isAvailable ? "可用" : "不可用")
    }

    var cloudAvailabilitySummary: String {
        (cloud as? CloudTranscriptPolishBackend)?.availabilitySummary
            ?? (cloud.isAvailable ? "可用" : "不可用")
    }

    var isLocalAvailable: Bool { local.isAvailable }
    var isCloudAvailable: Bool { cloud.isAvailable }

    /// Warm both backends so the first utterance isn't a cold start: TLS/HTTP for
    /// cloud, and the on-device model for local.
    func prewarm() {
        let mode = self.mode
        if mode == .cloud || mode == .automatic {
            cloudCancellable?.prewarm()
        }
        if mode == .local || mode == .automatic {
            localPrewarmable?.prewarm()
        }
    }

    /// Cancel any in-flight polish so a newer utterance cannot be overwritten.
    func cancel() {
        generation = UUID()
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        cloudCancellable?.cancelInFlight()
    }

    /// Always invokes `completion` on the main queue with either polished or raw text.
    func polish(_ raw: String, completion: @escaping (String) -> Void) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = self.mode
        if mode == .off || TranscriptPolishPrompt.shouldSkip(trimmed) {
            if mode != .off, !trimmed.isEmpty {
                rmDebug("✨ polish skip (clean/short) len=\(trimmed.count)")
            }
            DispatchQueue.main.async { completion(trimmed.isEmpty ? raw : trimmed) }
            return
        }

        let opID = UUID()
        generation = opID
        timeoutWorkItem?.cancel()
        let began = CFAbsoluteTimeGetCurrent()

        let deliver = { [weak self] (text: String) in
            DispatchQueue.main.async {
                guard let self, self.generation == opID else { return }
                self.timeoutWorkItem?.cancel()
                self.timeoutWorkItem = nil
                completion(text)
            }
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == opID else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
            rmDebug(String(format: "✨ polish timeout after %.0fms — using raw", ms))
            self.cloudCancellable?.cancelInFlight()
            self.generation = UUID()
            DispatchQueue.main.async { completion(trimmed) }
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.budget(for: mode), execute: timeout)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let isCurrent = { self.generation == opID }
            do {
                let polished = try await self.runPolish(
                    trimmed,
                    mode: mode,
                    generation: opID,
                    isCurrent: isCurrent
                )
                guard isCurrent() else { return }
                let sanitized = TranscriptPolishPrompt.sanitizeResult(polished, raw: trimmed)
                let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
                rmDebug(String(
                    format: "✨ polish ok mode=%@ in=%d out=%d %.0fms",
                    mode.rawValue,
                    trimmed.count,
                    sanitized.count,
                    ms
                ))
                deliver(sanitized)
            } catch {
                guard isCurrent() else { return }
                let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
                rmDebug(String(
                    format: "✨ polish fallback raw after %.0fms: %@",
                    ms,
                    error.localizedDescription
                ))
                deliver(trimmed)
            }
        }
    }

    private func runPolish(
        _ text: String,
        mode: TranscriptPolishMode,
        generation: UUID,
        isCurrent: @escaping () -> Bool
    ) async throws -> String {
        let instructions = TranscriptPolishPrompt.instructions
        switch mode {
        case .off:
            return text
        case .local:
            return try await local.polish(
                text,
                instructions: instructions,
                generation: generation,
                isCurrent: isCurrent
            )
        case .cloud:
            return try await cloud.polish(
                text,
                instructions: instructions,
                generation: generation,
                isCurrent: isCurrent
            )
        case .automatic:
            if local.isAvailable {
                do {
                    return try await local.polish(
                        text,
                        instructions: instructions,
                        generation: generation,
                        isCurrent: isCurrent
                    )
                } catch {
                    rmDebug("✨ local polish failed, trying cloud: \(error.localizedDescription)")
                }
            }
            if cloud.isAvailable {
                return try await cloud.polish(
                    text,
                    instructions: instructions,
                    generation: generation,
                    isCurrent: isCurrent
                )
            }
            throw TranscriptPolishError.unavailable
        }
    }
}
