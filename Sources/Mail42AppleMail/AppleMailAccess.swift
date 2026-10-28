// AppleMailAccess.swift — can mail42 read Apple Mail's store right now?
//
// macOS has no API that reports the Full Disk Access grant, so the only honest signal is trying to read.
// `~/Library/Mail` is TCC-protected: without the grant, listing it fails with EPERM (not ENOENT), so EPERM /
// EACCES means "denied" and ENOENT means Mail genuinely has no data. Anything else (EMFILE, EIO…) is reported
// as `noMailData`, never as a denial: sending the user to grant access for a transient error would mislead.

import Darwin
import Foundation
import Mail42Kit

public enum FDAState: String, Sendable, Equatable {
    case granted
    case denied
    case noMailData = "no_mail_data"
}

public enum AppleMailAccess {

    /// The Envelope Index inside a versioned mail root (`~/Library/Mail/V10`).
    public static func envelopeIndexURL(mailRoot: URL) -> URL {
        mailRoot.appendingPathComponent("MailData", isDirectory: true).appendingPathComponent("Envelope Index")
    }

    /// Full Disk Access state for the real `~/Library/Mail`.
    public static func fullDiskAccess() -> FDAState {
        fullDiskAccess(library: Mail42Paths.appleMailLibrary)
    }

    /// The same against an explicit `Library/Mail` directory (tests).
    public static func fullDiskAccess(library: URL) -> FDAState {
        guard let dir = opendir(library.path) else {
            switch errno {
            case EPERM, EACCES: return .denied
            default: return .noMailData
            }
        }
        closedir(dir)

        guard let root = Mail42Paths.appleMailRoot(in: library) else { return .noMailData }
        switch FDAStatus.probe(path: envelopeIndexURL(mailRoot: root).path) {
        case .granted: return .granted
        case .denied: return .denied
        case .noMailData, .undetermined: return .noMailData
        }
    }
}
