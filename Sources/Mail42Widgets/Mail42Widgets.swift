// Mail42Widgets.swift — mail42's Mail widget, hosted without the plugin loader.
//
// On the Mac the plugin loader builds the widget from its own Sources folder and Work42 hosts it. Anything else that
// shows it (the Work42 iPad app) links this library instead: one SwiftPM target built from the SAME files, and this
// file maps a widget id to its view. The widget reaches the Mac only through `SessionServices` (shell, platform), so on
// an iPad every `mail42` command is answered by the paired Mac, which holds the Full Disk Access grant.
//
// What stays on the Mac, on purpose: the action-area intents (the inbox switcher, New Message). The Mac hosts and runs
// them, and the iPad already shows and triggers the Mac's intents. This library only draws the widget's content.

import SwiftUI
import Work42PluginKit

import Mail42MailWidget

public enum Mail42Widget {

    /// Every widget id this plugin has.
    public static let allIDs = ["mail"]

    /// The widget ids this library draws on the current platform (all of them).
    public static var hostedIDs: [String] { allIDs }

    /// The plugin's own id for a widget id as a layout names it: `mail`, `widget:mail`, `mail42-mail` (the name a widget
    /// gets when another plugin already has `mail`) and `widget:mail42-mail-2` all give `mail`. Nil when it is not one
    /// of these widgets.
    public static func normalizedID(_ id: String) -> String? {
        var name = id
        if name.hasPrefix("widget:") { name.removeFirst("widget:".count) }
        if name.hasPrefix("mail42-") { name.removeFirst("mail42-".count) }
        if allIDs.contains(name) { return name }
        // A numbered duplicate, `mail-2`.
        if let dash = name.lastIndex(of: "-"), Int(name[name.index(after: dash)...]) != nil {
            let base = String(name[..<dash])
            if allIDs.contains(base) { return base }
        }
        return nil
    }

    /// A new instance of the widget, or nil when `id` is not one of these widgets.
    @MainActor
    public static func makeWidget(id: String) -> (any Work42Widget)? {
        switch normalizedID(id) {
        case "mail": Mail42MailWidget.mail42MakeWidget()
        default: nil
        }
    }

    /// The widget's content view for `id`, or nil when this library does not draw it.
    @MainActor
    public static func rootView(id: String, services: SessionServices) -> AnyView? {
        guard let name = normalizedID(id), let widget = makeWidget(id: name) else { return nil }
        return AnyView(MountedWidget(widget: widget, services: services))
    }
}

/// Keeps one widget instance for as long as its view is on screen. The Mail view starts and stops its own model
/// (`MailBody` calls `start` when it appears), so the widget's `activate` is not needed here.
private struct MountedWidget: View {
    @State private var widget: any Work42Widget
    let services: SessionServices

    init(widget: any Work42Widget, services: SessionServices) {
        _widget = State(initialValue: widget)
        self.services = services
    }

    var body: some View {
        widget.makeView(services: services)
    }
}
