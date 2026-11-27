// ServeDirectoryTests.swift — where `mail42 serve` listens (WOR-889): mail42's app group, so Work42's sandboxed widget can connect.

import Foundation
import Testing
@testable import mail42

@Suite("Where the daemon listens")
struct ServeDirectoryTests {

    @Test("by default the folder is mail42's app-group container, not a home folder")
    func defaultsToTheGroupContainer() {
        let directory = ServeDaemon.directory(environment: [:])
        #expect(ServeDaemon.groupIdentifier == "74RFQFPVQ9.com.work42.mail42")
        #expect(directory.lastPathComponent == "74RFQFPVQ9.com.work42.mail42")
        #expect(directory.deletingLastPathComponent().lastPathComponent == "Group Containers")
        #expect(directory.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Group Containers/"))
        #expect(!directory.path.contains("/.work42/"))
    }

    @Test("MAIL42_SERVE_DIR still names a separate daemon's folder, and an empty one is ignored")
    func environmentOverrides() {
        #expect(ServeDaemon.directory(environment: ["MAIL42_SERVE_DIR": "/tmp/m42-x"]).path == "/tmp/m42-x")
        #expect(ServeDaemon.directory(environment: ["MAIL42_SERVE_DIR": ""]).lastPathComponent == "74RFQFPVQ9.com.work42.mail42")
    }

    @Test("the folder before 0.4.0 stays known, for the command line to find an old daemon that is still running")
    func legacyFolder() {
        #expect(ServeDaemon.legacyDirectory.path == FileManager.default.homeDirectoryForCurrentUser.path + "/.work42/mail42")
    }

    @Test("the socket path in the group folder fits a Unix socket address for a long user name")
    func socketPathFits() {
        // `sun_path` holds 104 bytes. Everything after the home folder is 65 bytes, so a home folder of up to 38 bytes fits (a user
        // name of up to 31 characters under /Users); a longer one makes the daemon say the socket path is too long.
        let home = "/Users/" + String(repeating: "a", count: 20)
        let path = "\(home)/Library/Group Containers/\(ServeDaemon.groupIdentifier)/serve.sock"
        #expect(path.utf8.count <= ServeSocket.maxPathLength)
    }
}
