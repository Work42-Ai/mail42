// Output.swift — where a verb's stdout and stderr go, and how a verb ends.
//
// A verb used to print with `print` and end the process with `exit`. A verb that has to be run many times by one
// process (`mail42 serve`) can do neither, so it now writes to the `OutputSink` of the run it belongs to and ends
// by returning, or by throwing `VerbExit` (see `CLI.fail`). The CLI hands that sink's bytes to the real stdout and
// stderr and exits with the status; the daemon sends them back to the client. Both go through `VerbRunner.run`,
// so the output is the same either way.
//
// With no sink installed (nothing in the mail42 executable runs a verb that way) the text goes straight to the
// real stdout and stderr, as it always did.

import Foundation

/// How a verb ended other than by returning: with this exit status. `CLI.fail` and `CLI.usageError` throw it.
struct VerbExit: Error, Equatable {
    let status: Int32
}

/// The stdout and stderr of one verb run.
final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ text: String) { lock.lock(); out.append(Data(text.utf8)); lock.unlock() }
    func appendErr(_ text: String) { lock.lock(); err.append(Data(text.utf8)); lock.unlock() }

    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}

enum Output {

    /// The sink of the verb being run on this thread (set by `VerbRunner.run`). Nil outside a run.
    @TaskLocal static var sink: OutputSink?

    static func write(_ text: String) {
        if let sink { sink.appendOut(text) } else { Swift.print(text, terminator: "") }
    }

    static func writeError(_ text: String) {
        if let sink { sink.appendErr(text) } else { FileHandle.standardError.write(Data(text.utf8)) }
    }
}

/// Shadows the standard `print` for the whole mail42 executable (a declaration in the module wins over the
/// standard library's), so the verbs keep their `print(…)` lines and still write to their run's sink.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    Output.write(items.map { "\($0)" }.joined(separator: separator) + terminator)
}
