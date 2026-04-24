import Foundation

public struct DiagnosticsCheck: Codable, Equatable, Identifiable {
    public let name: String
    public let passed: Bool
    public let detail: String

    public var id: String { name }

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

public struct DiagnosticsReport: Codable, Equatable {
    public let checks: [DiagnosticsCheck]
    public let runAt: Date
    public let durationSeconds: Double

    public init(checks: [DiagnosticsCheck], runAt: Date, durationSeconds: Double) {
        self.checks = checks
        self.runAt = runAt
        self.durationSeconds = durationSeconds
    }

    public var allPassed: Bool { checks.allSatisfy(\.passed) }
    public var passedCount: Int { checks.filter(\.passed).count }
    public var failedCount: Int { checks.count - passedCount }

    public var summary: String {
        allPassed
            ? "\(passedCount)/\(checks.count) passed"
            : "\(failedCount) failed, \(passedCount) passed"
    }
}
