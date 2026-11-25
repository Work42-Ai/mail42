// ServeClient.swift — the command line's side of the daemon: use it when it is there, work alone when it isn't.
//
// Before a verb runs in this process, the CLI looks for the daemon's socket. If a daemon of this version answers
// within 200 ms the verb goes to it, and the answer (the same bytes, the same exit status) is printed here. In every
// other case (no socket, a stale socket, a daemon that is busy past the timeout, a different version) the verb runs
// in-process exactly as it always did. The CLI never starts the daemon: the widget and the Work42 app do.
//
// A run that points mail42 at a sandbox (`MAIL42_MAIL_LIBRARY`, `MAIL42_ACCOUNTS_DB`: tests, a copy of a mail store)
// never goes to a daemon, which would answer from the real mail, unless the run also names the sandbox's own daemon
// (`MAIL42_SERVE_DIR`).

import Darwin
import Foundation

enum ServeClient {

    /// Verbs that never need mail and so never need the daemon.
    private static let local: Set<String> = ["serve", "version", "--version", "-v", "help", "--help", "-h", ""]

    static func shouldForward(command: String, environment: [String: String]) -> Bool {
        if local.contains(command) || environment["MAIL42_NO_SERVE"] == "1" { return false }
        let sandboxed = ["MAIL42_MAIL_LIBRARY", "MAIL42_ACCOUNTS_DB"].contains { !(environment[$0] ?? "").isEmpty }
        if sandboxed && (environment["MAIL42_SERVE_DIR"] ?? "").isEmpty { return false }
        return true
    }

    /// The daemon's answer to `command args…`, or nil to run it in this process.
    static func forward(
        command: String, args: [String], version: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> VerbResult? {
        guard shouldForward(command: command, environment: environment) else { return nil }
        // The daemon's folder, then (unless a run named its own with `MAIL42_SERVE_DIR`) the one before 0.4.0 used, for an old
        // daemon that is still running.
        var folders = [ServeDaemon.directory(environment: environment)]
        if (environment["MAIL42_SERVE_DIR"] ?? "").isEmpty { folders.append(ServeDaemon.legacyDirectory) }
        guard let fd = folders.lazy.compactMap({
            ServeSocket.connect(path: $0.appendingPathComponent("serve.sock").path, timeoutMs: 200)
        }).first else { return nil }
        defer { close(fd) }

        var buffer = Data()
        guard ServeSocket.writeAll(fd, ServeSocket.line(["hello": ["version": version]])),
              let greeting = ServeSocket.readLine(fd, buffer: &buffer, timeoutMs: 2000),
              let hello = (ServeSocket.object(greeting)?["hello"]) as? [String: Any],
              hello["ok"] as? Bool == true
        else { return nil }

        let id = 1
        let isAction = ServeDaemon.isAction(verb: command, args: args)
        guard ServeSocket.writeAll(fd, ServeSocket.line(["id": id, "verb": command, "args": args])),
              let line = ServeSocket.readLine(fd, buffer: &buffer, limit: 1 << 30),
              let reply = ServeSocket.object(line), reply["id"] as? Int == id,
              let status = reply["status"] as? Int
        else {
            // The daemon went away before it answered. A read can simply be asked again here. An action may already
            // have reached Mail, so asking again could do it twice: say so instead.
            return isAction ? stopped(json: args.contains("--json")) : nil
        }
        let stdout = Data(base64Encoded: reply["stdout"] as? String ?? "") ?? Data()
        return VerbResult(stdout: stdout, stderr: reply["stderr"] as? String ?? "", status: Int32(status))
    }

    private static func stopped(json: Bool) -> VerbResult {
        let message = "the mail42 service stopped before it answered; check Mail, then run the command again"
        if json {
            let body = ["error": ["code": "service_stopped", "message": message]]
            let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return VerbResult(stdout: data + Data("\n".utf8), stderr: "", status: 1)
        }
        return VerbResult(stdout: Data(), stderr: "mail42: \(message) (service_stopped)\n", status: 1)
    }
}
