import Foundation
import Testing
@testable import CliCore

func expectCLIError(_ needle: String, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected CLIError containing \(needle)")
    } catch let error as CLIError {
        #expect(error.localizedDescription.contains(needle))
    } catch {
        Issue.record("expected CLIError, got \(error)")
    }
}

func jsonArray(_ value: Any?) throws -> [[String: Any]] {
    let object = try jsonValue(value)
    guard let array = object as? [[String: Any]] else {
        throw CLIError.io("expected JSON array")
    }
    return array
}

func jsonObject(_ value: Any?) throws -> [String: Any] {
    guard let object = try jsonValue(value) as? [String: Any] else {
        throw CLIError.io("expected JSON object")
    }
    return object
}

private func jsonValue(_ value: Any?) throws -> Any {
    if let data = value as? Data {
        return try JSONSerialization.jsonObject(with: data)
    }
    if let value {
        return value
    }
    throw CLIError.io("expected JSON")
}

func int64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    return nil
}

func queryItems(_ raw: String) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for item in raw.split(separator: "&") {
        let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(parts[0])
        let value = parts.count == 2
            ? (String(parts[1]).removingPercentEncoding ?? String(parts[1]))
            : ""
        result[key, default: []].append(value)
    }
    return result
}
