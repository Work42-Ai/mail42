// AutomationPermission.swift — may mail42 control Mail? Apple's own check, instead of guessing from a timeout.
//
// macOS lets one app send Apple Events to another only after the person allows it (Privacy & Security ›
// Automation). `AEDeterminePermissionToAutomateTarget` answers without sending anything: with `askUser: false` it
// reports the current state at once; with `askUser: true` it shows macOS's prompt and waits for the answer.

import ApplicationServices
import Foundation

public enum AutomationPermission {

    public enum State: Equatable, Sendable {
        /// mail42 may control Mail.
        case granted
        /// The person said no (or switched it off in System Settings).
        case denied
        /// Never decided: the prompt hasn't been answered yet.
        case notDetermined
        /// Mail isn't running, so macOS can't say.
        case mailNotRunning
        /// Any other macOS status.
        case other(Int)
    }

    public static let mailBundleID = "com.apple.mail"

    /// - Parameter askUser: when true and the answer isn't decided yet, macOS shows its prompt and this call waits
    ///   for the person to answer.
    public static func state(askUser: Bool) -> State {
        let target = NSAppleEventDescriptor(bundleIdentifier: mailBundleID)
        guard let address = target.aeDesc else { return .other(-1) }
        let status = AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, askUser)
        return map(Int(status))
    }

    static func map(_ status: Int) -> State {
        switch status {
        case 0: return .granted
        case -1743: return .denied
        case -1744: return .notDetermined
        case -600: return .mailNotRunning
        default: return .other(status)
        }
    }
}
