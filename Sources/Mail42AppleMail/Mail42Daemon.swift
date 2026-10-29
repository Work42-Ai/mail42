// Mail42Daemon.swift — the permission-identity re-launch helper for mail42's verbs that read Apple Mail
// (`permissions`, `sync`, and the read verbs that open .emlx files).
//
// Ported from meet42's Meet42Daemon.swift. macOS attributes a privacy request (here Full Disk Access) to the
// *responsible process*, which a child inherits from its parent. Launched from Terminal or from Work42, mail42
// would therefore be checked against Terminal's or Work42's Full Disk Access, not its own. The fix is to
// re-exec in place with the "disclaim responsibility" spawn attribute, so mail42 is its own principal: the
// grant the user gives to mail42.app in System Settings is the one that applies, whoever launched it.
//
//   1. First call (no `--reexec` in the process's own argv): `setsid()` to leave the parent's session, then
//      re-exec this binary in place (`POSIX_SPAWN_SETEXEC`, same pid) with `--reexec` appended, the
//      `MAIL42_REEXEC=1` marker set, and responsibility disclaimed.
//   2. Second call (in the re-exec'd process): `reexecIfNeeded` returns at once and the verb runs.
//
// The phase is read from `CommandLine.arguments` and the environment, NOT from the verb arguments passed to
// `reexecIfNeeded`: `main.swift` strips `--reexec` before dispatching, so checking the passed list would never
// see it and would re-exec forever (this happened once; `shouldReexec` and its tests pin the rule).
//
// Switches: MAIL42_NO_DISCLAIM=1 falls back to a plain execve; MAIL42_NO_REEXEC=1 skips the re-exec entirely
// (used by tests, which cannot be re-executed).
//
// Not build-verifiable: the re-key only has an effect when the binary is signed with a persistent Developer ID
// and carries the embedded Info.plist (scripts/build-mail42.sh). Under an ad-hoc `swift build` signature the
// re-exec runs but the grant does not persist across rebuilds, so validate on a real signed build.

import Darwin
import Foundation

/// libSystem's `responsibility_spawnattrs_setdisclaim` (private header, exported by libSystem). Marks a spawn so
/// the new process is its own responsible process for privacy (TCC) purposes.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func mail42_responsibility_spawnattrs_setdisclaim(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32
) -> Int32

public enum Mail42Daemon {

    /// Whether the current argv is already the re-exec phase.
    public static func isReexec(_ args: [String]) -> Bool {
        args.contains("--reexec")
    }

    /// Whether this process should re-exec itself now. Pure, so it is testable.
    ///
    /// The phase is a property of the **process's own** argv and environment, never of the verb arguments a
    /// caller passes in: `main.swift` strips `--reexec` before dispatching a verb, so a verb that asked
    /// "is `--reexec` in my arguments?" would never see it and would re-exec forever. The `MAIL42_REEXEC`
    /// environment marker, set on the re-exec, is a second guard against that class of loop.
    public static func shouldReexec(processArguments: [String], environment: [String: String]) -> Bool {
        !isReexec(processArguments)
            && environment["MAIL42_REEXEC"] != "1"
            && environment["MAIL42_NO_REEXEC"] != "1"
    }

    /// Re-exec this process as mail42's own permission principal. `arguments` is the argv after the program
    /// name (the verb and its flags, without `--reexec`). On the first call this does not return (it execs); in
    /// the re-exec'd process it returns immediately so the caller runs its verb.
    ///
    /// Call it first thing in any verb that reads `~/Library/Mail`.
    public static func reexecIfNeeded(arguments: [String]) {
        var env = ProcessInfo.processInfo.environment
        guard shouldReexec(processArguments: CommandLine.arguments, environment: env) else { return }

        // Leave the parent's session so a long verb outlives the spawning shell, then re-exec in place.
        _ = setsid()

        env["MAIL42_REEXEC"] = "1"
        let exePath = currentExecutablePath()
        let cArgs = ([exePath] + arguments + ["--reexec"]).map { strdup($0) }
        defer { cArgs.forEach { free($0) } }
        var argvPtrs: [UnsafeMutablePointer<CChar>?] = cArgs + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") }
        defer { cEnv.forEach { free($0) } }
        var envPtrs: [UnsafeMutablePointer<CChar>?] = cEnv + [nil]

        // 1. Re-exec as mail42's OWN permission principal (see `execDisclaimed`). Does not return on success.
        if env["MAIL42_NO_DISCLAIM"] != "1" {
            argvPtrs.withUnsafeMutableBufferPointer { argvBuf in
                envPtrs.withUnsafeMutableBufferPointer { envBuf in
                    execDisclaimed(exePath, argvBuf.baseAddress, envBuf.baseAddress)
                }
            }
            FileHandle.standardError.write(Data(
                "[mail42:daemon] disclaimed re-exec failed (\(String(cString: strerror(errno)))) — falling back to a plain execve\n".utf8
            ))
        }
        // 2. Plain execve. macOS then attributes permissions to whatever launched us.
        _ = argvPtrs.withUnsafeMutableBufferPointer { argvBuf in
            envPtrs.withUnsafeMutableBufferPointer { envBuf in
                execve(exePath, argvBuf.baseAddress, envBuf.baseAddress)
            }
        }
        // execve only returns on failure: run anyway (the grant may then be Terminal's, not ours).
        FileHandle.standardError.write(Data(
            "[mail42:daemon] execve failed (\(String(cString: strerror(errno)))) — continuing without re-exec\n".utf8
        ))
    }

    /// `arguments` without the internal `--reexec` marker.
    public static func strippingReexec(_ arguments: [String]) -> [String] {
        arguments.filter { $0 != "--reexec" }
    }

    /// Replaces this process with `path`, in place (same pid, same open files) like `execve`, but with the
    /// "disclaim responsibility" spawn attribute set, so the new image is its own responsible process for
    /// privacy (TCC) purposes. `POSIX_SPAWN_SETEXEC` keeps the "this process becomes the new image" behaviour.
    /// The function only returns when the exec failed (`errno` is set).
    private static func execDisclaimed(
        _ path: String,
        _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
        _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>?
    ) {
        var attr: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attr) == 0 else { return }
        defer { posix_spawnattr_destroy(&attr) }
        guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC)) == 0 else { return }
        guard mail42_responsibility_spawnattrs_setdisclaim(&attr, 1) == 0 else { return }
        var pid: pid_t = 0
        // With POSIX_SPAWN_SETEXEC this does not return on success.
        let rc = posix_spawn(
            &pid, path, nil, &attr,
            argv.map { UnsafeMutablePointer(mutating: $0) },
            envp.map { UnsafeMutablePointer(mutating: $0) }
        )
        errno = rc
    }

    /// Absolute path to the running executable (for the self re-exec).
    public static func currentExecutablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else {
            return CommandLine.arguments.first ?? "mail42"
        }
        let raw = buf.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) } ?? ""
        }
        return (raw as NSString).resolvingSymlinksInPath
    }
}
