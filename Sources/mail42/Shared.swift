// Shared.swift — small helpers shared across the mail42 CLI verbs.
//
// Manual arg dispatch, no ArgumentParser. stdout carries verb output (JSON with `--json`, else human text);
// every diagnostic goes to stderr. JSON is encoded with sorted keys and ISO-8601 dates, as meet42 does.
//
// Exit codes: 0 ok · 1 failed or not granted (Full Disk Access, unsupported Apple Mail schema) ·
//             2 usage, store, not-found or bad-query error.

import Foundation
import Mail42Kit

enum CLI {

    // MARK: - stderr diagnostics

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    /// Prints a plain message to stderr and exits.
    static func fail(_ message: String, code: Int32 = 1) -> Never {
        warn(message)
        exit(code)
    }

    /// Prints an error and exits. With `--json` the error is `{"error":{"code","message"}}` on stdout so
    /// agents can parse it; otherwise it is plain text on stderr.
    static func fail(code errorCode: String, message: String, exit exitCode: Int32, json: Bool) -> Never {
        if json {
            let payload = ErrorEnvelope(error: ErrorBody(code: errorCode, message: message))
            if let data = try? jsonEncoder().encode(payload), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            exit(exitCode)
        }
        fail("mail42: \(message) (\(errorCode))", code: exitCode)
    }

    private struct ErrorEnvelope: Encodable { let error: ErrorBody }
    private struct ErrorBody: Encodable { let code: String; let message: String }

    /// Exit code for a failure: 1 when mail42 can't read Apple Mail (no Full Disk Access, no Mail data, an
    /// index this version doesn't understand), 2 for everything else (store, usage, not found, bad query).
    static func exitCode(for error: Mail42Error) -> Int32 {
        switch error {
        case .fdaDenied, .noMailData, .schemaUnsupported: return 1
        default: return 2
        }
    }

    /// Prints any error the way every verb should and exits.
    static func fail(error: Error, json: Bool) -> Never {
        if let error = error as? Mail42Error {
            fail(code: error.code, message: error.localizedDescription, exit: exitCode(for: error), json: json)
        }
        fail(code: "error", message: error.localizedDescription, exit: 2, json: json)
    }

    // MARK: - Arg parsing

    static func argValue(_ args: [String], _ name: String) -> String? {
        guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    static func wantsJSON(_ args: [String]) -> Bool { args.contains("--json") }

    /// First non-flag argument (positional), so `--json` may appear before or after it.
    static func firstPositional(_ args: [String]) -> String? {
        args.first { !$0.hasPrefix("-") }
    }

    /// All non-flag arguments, in order.
    static func positionals(_ args: [String]) -> [String] {
        args.filter { !$0.hasPrefix("-") }
    }

    // MARK: - JSON

    static func jsonEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func emitJSON<T: Encodable>(_ value: T) {
        do {
            let data = try jsonEncoder().encode(value)
            print(String(data: data, encoding: .utf8) ?? "null")
        } catch {
            fail("mail42: JSON encoding failed: \(error)", code: 2)
        }
    }
}
