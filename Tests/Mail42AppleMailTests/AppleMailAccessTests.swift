import Foundation
import Testing
import Mail42TestSupport
@testable import Mail42AppleMail

@Suite struct AppleMailAccessTests {

    @Test func grantedWhenTheEnvelopeIndexIsReadable() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        #expect(AppleMailAccess.fullDiskAccess(library: fixture.library) == .granted)
    }

    @Test func noMailDataWhenThereIsNoLibraryOrNoVersionFolder() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-none-\(UUID().uuidString)")
        #expect(AppleMailAccess.fullDiskAccess(library: missing) == .noMailData)

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(AppleMailAccess.fullDiskAccess(library: empty) == .noMailData)
    }

    @Test func noMailDataWhenTheVersionFolderHasNoIndex() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-noindex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("V10/MailData"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: library) }
        #expect(AppleMailAccess.fullDiskAccess(library: library) == .noMailData)
    }

    @Test func deniedWhenTheLibraryCannotBeListed() throws {
        // macOS reports a missing Full Disk Access grant as EPERM/EACCES on ~/Library/Mail; an unreadable
        // directory produces the same errno, so it stands in for the TCC refusal.
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.library.path) }
        guard getuid() != 0 else { return }     // root can read anything; nothing to assert
        #expect(AppleMailAccess.fullDiskAccess(library: fixture.library) == .denied)
    }

    @Test func deniedWhenTheIndexFileItselfIsUnreadable() throws {
        let fixture = try EnvelopeIndexBuilder()
        defer { fixture.cleanup() }
        let index = fixture.envelopeIndexURL
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: index.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: index.path) }
        guard getuid() != 0 else { return }
        #expect(AppleMailAccess.fullDiskAccess(library: fixture.library) == .denied)
    }

    @Test func stateRawValuesAreTheStableJSONNames() {
        #expect(FDAState.granted.rawValue == "granted")
        #expect(FDAState.denied.rawValue == "denied")
        #expect(FDAState.noMailData.rawValue == "no_mail_data")
    }
}
