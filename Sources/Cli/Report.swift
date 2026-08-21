import Foundation

enum CheckStatus: Sendable {
    case ok
    case warn
    case fail
}

struct CheckResult: Sendable {
    var status: CheckStatus
    var title: String
    var detail: String?
}

enum Report {
    static func print(_ results: [CheckResult]) {
        for result in results {
            let mark: String
            switch result.status {
            case .ok: mark = "ok  "
            case .warn: mark = "warn"
            case .fail: mark = "fail"
            }
            if let detail = result.detail, !detail.isEmpty {
                Swift.print("  [\(mark)] \(result.title) — \(detail)")
            } else {
                Swift.print("  [\(mark)] \(result.title)")
            }
        }
    }

    static func exitCode(for results: [CheckResult]) -> Int32 {
        results.contains(where: { $0.status == .fail }) ? 1 : 0
    }
}
