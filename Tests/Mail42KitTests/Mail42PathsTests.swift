import Foundation
import Testing
@testable import Mail42Kit

@Suite struct Mail42PathsTests {

    @Test func environmentOverridesRedirectBothLocations() {
        let env = ["MAIL42_MAIL_LIBRARY": "/tmp/sandbox-mail", "MAIL42_ACCOUNTS_DB": "/tmp/sandbox-accounts.sqlite"]
        #expect(Mail42Paths.appleMailLibrary(environment: env).path == "/tmp/sandbox-mail")
        #expect(Mail42Paths.accountsDatabase(environment: env).path == "/tmp/sandbox-accounts.sqlite")
    }

    @Test func emptyOrMissingOverridesFallBackToTheHomeDirectory() {
        for env in [[:], ["MAIL42_MAIL_LIBRARY": "", "MAIL42_ACCOUNTS_DB": ""]] as [[String: String]] {
            #expect(Mail42Paths.appleMailLibrary(environment: env).path.hasSuffix("/Library/Mail"))
            #expect(Mail42Paths.accountsDatabase(environment: env).path.hasSuffix("/Library/Accounts/Accounts4.sqlite"))
        }
    }

    @Test func appleMailRootPicksTheHighestVersionDirectory() throws {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("mail42-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }
        for name in ["V9", "V10", "V2", "MailData", "Vx", "v11"] {
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        #expect(Mail42Paths.appleMailRoot(in: library)?.lastPathComponent == "V10")
    }

    @Test func appleMailRootIsNilWhenThereIsNoStore() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mail42-missing-\(UUID().uuidString)")
        #expect(Mail42Paths.appleMailRoot(in: missing) == nil)
    }
}
