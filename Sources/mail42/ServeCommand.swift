// ServeCommand.swift — `mail42 serve` and `mail42 serve --detach`.
//
//   mail42 serve            run the daemon in the foreground until it goes idle or is stopped (a person debugging)
//   mail42 serve --detach   start the daemon in the background and return at once (what the widget and the Work42 app run)
//
// The daemon is `ServeDaemon`; the protocol is docs/serve-protocol.md.

import Darwin
import Foundation
import Mail42AppleMail

enum ServeCommand {

    /// Keeps the signal sources alive for the life of the process.
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    static func run(args: [String], version: String) -> Never {
        if args.contains("--detach") { detach() }

        // The daemon reads Apple Mail's files and drives Mail, so it must be mail42's own permission principal (the
        // one the user granted Full Disk Access and Automation to), whoever started it.
        Mail42Daemon.reexecIfNeeded(arguments: ["serve"])

        let daemon = ServeDaemon(.live(version: version))
        do {
            try daemon.start()
        } catch ServeError.alreadyRunning {
            exit(0)                                     // another daemon has the lock: it is the one that serves
        } catch {
            FileHandle.standardError.write(Data("mail42: serve: \(error)\n".utf8))
            exit(1)
        }
        daemon.onStop = { exit(0) }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { daemon.stop(reason: "signal \(number)") }
            source.resume()
            signalSources.append(source)
        }
        dispatchMain()                                  // the main thread now serves the action queue
    }

    /// Starts `mail42 serve` as a separate, detached process and returns. The new process finds out for itself whether
    /// a daemon already exists (it takes the lock or exits), so starting one twice is harmless.
    private static func detach() -> Never {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Mail42Daemon.currentExecutablePath())
        process.arguments = ["serve"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("mail42: couldn't start the service: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
