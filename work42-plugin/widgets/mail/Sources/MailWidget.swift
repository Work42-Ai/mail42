// MailWidget.swift — mail42's Mail widget (WOR-443): a lightweight, read-only reader over Apple Mail.
//
// Everything comes from the `mail42` CLI, which reads Apple Mail live. The tab-bar row carries the controls (mailbox
// menu, Unread, Open in Mail); the tile itself is a message list beside the rendered message. Links only Work42PluginKit + Work42UI.

import AppKit
import Observation
import SwiftUI
import Work42UI
import Work42PluginKit

@MainActor
@Observable
final class MailWidget: Work42Widget, Work42WidgetCustomHeader {

    let id = "mail"
    let title = "Mail"
    let icon = "envelope"
    var minSize: WidgetMinSize { WidgetMinSize(width: 520, height: 320) }
    var contentPadding: Double { 0 }
    var linkIntents: [WidgetLinkIntentSpec] {
        // The "mail42 needs setup" label links here; the host reveals the widget before `perform`.
        [WidgetLinkIntentSpec(matchers: [.regex(#"^mail42://widget/mail$"#)], perform: { _ in })]
    }

    @ObservationIgnored let model = MailModel()

    var intents: [WidgetIntentSpec] {
        [
            WidgetIntentSpec(
                name: "mailbox", title: "Mailbox", icon: "tray.2",
                keywords: ["inbox", "folder", "account"],
                placement: [.palette, .actionArea],
                actionAreaStyle: .menu(
                    options: { [model] in
                        model.mailboxMenu.map { WidgetIntentMenuOption(id: $0.id, title: $0.title, isSelected: $0.selected) }
                    },
                    onSelect: { [model] id in model.chooseMailbox(menuID: id) }),
                perform: {}),
            WidgetIntentSpec(
                name: "unread", title: "Unread Only", icon: "envelope.badge",
                keywords: ["filter"],
                placement: [.palette, .actionArea],
                actionAreaStyle: .icon,
                isConfirmed: { [model] in model.unreadOnly },
                performWithServices: { [model] _ in model.toggleUnread() }),
            WidgetIntentSpec(
                name: "open-in-mail", title: "Open in Mail", icon: "arrow.up.forward.app",
                keywords: ["reply", "archive", "mail.app"],
                placement: [.palette, .actionArea],
                actionAreaStyle: .labeled,
                isEnabled: { [model] in model.selectedID != nil },
                perform: { [model] in await model.openSelectedInMail() }),
        ]
    }

    func activate(services: SessionServices) {
        model.start(services: services)
    }

    func deactivate() {
        model.stop()
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(MailBody(model: model, services: services))
    }

    func makeHeaderView() -> AnyView {
        AnyView(MailHeader(model: model))
    }

}

private struct MailHeader: View {
    let model: MailModel

    var body: some View {
        HStack(spacing: DT.s8) {
            Text(model.title)
                .font(.system(size: DT.f12, weight: .medium))
                .foregroundStyle(.primary)
            Text(model.detail)
                .font(.system(size: DT.f10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: DT.s8)
        }
    }
}

// MARK: - Entry points

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated { result = WidgetEntryPoint.register(MailWidget()) }
    return result
}
