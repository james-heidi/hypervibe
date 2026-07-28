import Foundation

/// Minimal stand-in so TranscriptPolisher tests can compile TranscriptionKeychain
/// without pulling OpenAI/Parakeet engine sources.
enum TranscriptionEngineError: LocalizedError {
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .backend(let message): return message
        }
    }
}
