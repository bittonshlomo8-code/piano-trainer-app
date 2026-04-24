import Foundation

public enum ModelRunnerError: Error, LocalizedError {
    case audioLoadFailed(String)
    case processingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .audioLoadFailed(let m):  return "Audio load failed: \(m)"
        case .processingFailed(let m): return "Processing failed: \(m)"
        }
    }
}
