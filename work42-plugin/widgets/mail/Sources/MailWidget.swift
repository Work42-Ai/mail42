// MailWidget.swift — Mail42: a mail client over Apple Mail, inside Work42.
//
// Everything comes from the `mail42` CLI, which reads Apple Mail live and asks Mail itself to act. Two controls sit in
// the tab-bar row (the inbox switcher and New); everything that acts on a message is in the widget header (see
// MailHeader), on a row's right-click, or on the keyboard. The tile itself is a conversation list beside the reader.
// Links only Work42PluginKit + Work42UI.

import Observation
import SwiftUI
import Work42UI
import Work42PluginKit

@MainActor
@Observable
final class MailWidget: Work42Widget, Work42WidgetCustomHeader {

    // The id stays `mail` so a tile placed before the rename keeps working.
    let id = "mail"
    let title = "Mail42"
    let icon = "envelope"
    var minSize: WidgetMinSize { WidgetMinSize(width: 640, height: 360) }
    var contentPadding: Double { 0 }
    var linkIntents: [WidgetLinkIntentSpec] {
        // The "mail42 needs setup" label links here; the host reveals the widget before `perform`.
        [
            WidgetLinkIntentSpec(matchers: [.regex(#"^mail42://widget/mail$"#)], perform: { _ in }),
            // A link to one message, from chat, an agent's reply or a doc: reveal the tile and open that message.
            WidgetLinkIntentSpec(matchers: [.regex(#"^mail42://message/"#)], perform: { [model] url in await model.openLink(url) }),
        ]
    }

    @ObservationIgnored let model = MailModel.shared

    var intents: [WidgetIntentSpec] {
        [
            // The inbox switcher: All Inboxes, Flagged, each account's Inbox, and the Unread Only switch. Its label is
            // the view you are in with its unread count.
            WidgetIntentSpec(
                name: "inbox", title: "Inbox", icon: "tray.2",
                keywords: ["mailbox", "folder", "account", "unread", "filter"],
                placement: [.palette, .actionArea],
                actionAreaStyle: .menu(
                    options: { [model] in
                        model.mailboxMenu.map {
                            WidgetIntentMenuOption(id: $0.id, title: $0.title, icon: $0.icon, isSelected: $0.selected)
                        }
                    },
                    onSelect: { [model] id in model.chooseMailbox(menuID: id) }),
                isEnabled: nil,
                actionAreaTitle: { [model] in model.switcherTitle },
                perform: {}),
            WidgetIntentSpec(
                name: "new", title: "New Message", icon: "square.and.pencil",
                keywords: ["compose", "write", "email"],
                placement: [.palette, .actionArea],
                actionAreaStyle: .labeled,
                perform: { [model] in await model.perform(.newMessage) }),
        ]
    }

    func activate(services: SessionServices) {
        // The model is shared by every Mail tile, and it works only while one is on screen: each tile attaches when it
        // appears and detaches when it goes (MailBody), so closing one never stops the model for another. Activating
        // only tells it whose services a link or a header button can use.
        model.adopt(services: services)
    }

    func deactivate() {
        // The reader's web view (and its web-content process) belongs to this instance; the host runs this inside the
        // instance's cache scope, so the key below reaches this instance's surface and no other.
        BrowserSurfaceCache.shared.teardown(key: MailReaderSurface.cacheKey)
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(MailBody(model: model, services: services))
    }

    func makeHeaderView() -> AnyView {
        AnyView(MailHeader(model: model))
    }

}


/// A new instance of the widget, for hosts that show it without the plugin loader (the `Mail42Widgets` library).
public func mail42MakeWidget() -> any Work42Widget { MailWidget() }

// MARK: - Entry points

// The dylib entry points the plugin loader calls. The library build links the widget into the iPad app, which
// has no loader, so it leaves them out (two `work42_widget_*` symbols would clash with the next widget's).
#if !MAIL42_WIDGETS_LIBRARY
@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated { result = WidgetEntryPoint.register(MailWidget()) }
    return result
}
#endif
