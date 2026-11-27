// Mail42's extension (`runtime: extension`): the mail widget runs in its own process. Only the Work42 extension build compiles this
// file; the SwiftPM `Mail42MailWidget` target (the iPad's library) excludes it.
import SwiftUI
import Work42Extension
import Work42PluginKit

/// `nonisolated` is required: ExtensionKit makes this class off the main actor (the widget stays on it).
@main
nonisolated final class Mail42Extension: Work42PluginExtension {
    required init() {}

    @MainActor var widgets: [ExtensionWidgetFactory] {
        [
            ExtensionWidgetFactory("mail") { MailWidget() },
        ]
    }
}
