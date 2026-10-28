// Mail42Paths.swift — where Apple Mail keeps its files, which mail42 only ever READS.
//
// mail42 keeps no copy of the user's mail and no database of its own; the only files it writes are the ones the
// user asks for (a saved attachment, a `--out` file).

import Foundation

public enum Mail42Paths {

    /// Environment overrides, for tests and for pointing mail42 at a copy of a mail store. They exist because
    /// `$HOME` is NOT honoured (Foundation reads the home directory from the user database), so without them
    /// there is no way to run the CLI against a sandbox.
    public enum Override {
        /// Replaces `~/Library/Mail` (the folder holding Apple Mail's `V10`).
        public static let mailLibrary = "MAIL42_MAIL_LIBRARY"
        /// Replaces `~/Library/Accounts/Accounts4.sqlite` (where macOS records each account's address).
        public static let accountsDatabase = "MAIL42_ACCOUNTS_DB"
    }

    /// `~/Library/Accounts/Accounts4.sqlite`, or `$MAIL42_ACCOUNTS_DB` when set.
    public static var accountsDatabase: URL { accountsDatabase(environment: ProcessInfo.processInfo.environment) }

    /// `accountsDatabase` for an explicit environment, so the rule is testable.
    public static func accountsDatabase(environment: [String: String]) -> URL {
        if let path = environment[Override.accountsDatabase], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Accounts/Accounts4.sqlite")
    }

    /// `~/Library/Mail`, the parent of Apple Mail's versioned store, or `$MAIL42_MAIL_LIBRARY` when set.
    public static var appleMailLibrary: URL { appleMailLibrary(environment: ProcessInfo.processInfo.environment) }

    /// `appleMailLibrary` for an explicit environment, so the rule is testable.
    public static func appleMailLibrary(environment: [String: String]) -> URL {
        if let path = environment[Override.mailLibrary], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mail", isDirectory: true)
    }

    /// The highest `~/Library/Mail/V<n>` directory (Apple Mail's store: `V10` since macOS Ventura), or nil
    /// when it can't be listed (no Mail data, or Full Disk Access isn't granted).
    public static func appleMailRoot() -> URL? {
        appleMailRoot(in: appleMailLibrary)
    }

    /// `appleMailRoot()` against an explicit `Library/Mail` directory, so it can be tested.
    public static func appleMailRoot(in library: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: library.path) else { return nil }
        let versions: [(Int, String)] = names.compactMap { name in
            guard name.hasPrefix("V"), let n = Int(name.dropFirst()) else { return nil }
            return (n, name)
        }
        guard let highest = versions.max(by: { $0.0 < $1.0 }) else { return nil }
        return library.appendingPathComponent(highest.1, isDirectory: true)
    }
}
