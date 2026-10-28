// MailBackground.swift — keeps mail42's index fresh while Work42 runs.
//
// One agent per session that has the Mail widget in its layout. Every ~2 minutes it runs `mail42 sync`, unless
// someone else just did (the trace says so) or another sync holds the lock, so several sessions never pile up.
// When Full Disk Access isn't granted it backs off to every ten minutes instead of failing every two.

import Foundation
import Observation
import Work42PluginKit

@MainActor
@Observable
final class MailSyncAgent: WidgetBackgroundAgent {

    /// The agent contributes no header chips.
    var headerLabels: [WidgetHeaderLabel] { [] }

    @ObservationIgnored private var task: Task<Void, Never>?

    private static let interval: Duration = .seconds(120)
    private static let deniedInterval: Duration = .seconds(600)
    private static let freshness: TimeInterval = 90

    func start(services: WidgetBackgroundServices) {
        task?.cancel()
        task = Task { [weak self] in
            // Let the widget's own first load go first.
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                let outcome = await MailSyncRunner.runOnce(skipIfFresherThan: Self.freshness)
                if case .synced = outcome { await services.activity.ping() }
                let wait: Duration
                switch outcome {
                case .denied, .notInstalled: wait = Self.deniedInterval
                default: wait = Self.interval
                }
                try? await Task.sleep(for: wait)
                if self == nil { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
