// Mail42WidgetsTests.swift — the library that hosts the Mail widget without the plugin loader.

import Foundation
import Testing
import Work42PluginKit
@testable import Mail42MailWidget
@testable import Mail42Widgets

@Suite("Mail42Widgets")
@MainActor
struct Mail42WidgetsTests {

    @Test("a layout's widget id maps to the plugin's own id")
    func normalizesIDs() {
        #expect(Mail42Widget.normalizedID("mail") == "mail")
        #expect(Mail42Widget.normalizedID("widget:mail") == "mail")
        #expect(Mail42Widget.normalizedID("mail42-mail") == "mail")      // the name it gets when `mail` is taken
        #expect(Mail42Widget.normalizedID("widget:mail42-mail-2") == "mail")
        #expect(Mail42Widget.normalizedID("mail-3") == "mail")
        #expect(Mail42Widget.normalizedID("calendar") == nil)
        #expect(Mail42Widget.normalizedID("mailer") == nil)
        #expect(Mail42Widget.normalizedID("") == nil)
    }

    @Test("the widget keeps the id and title a tile placed before the rename relies on")
    func widgetIdentity() throws {
        let widget = try #require(Mail42Widget.makeWidget(id: "mail"))
        #expect(widget.id == "mail")
        #expect(widget.title == "Mail42")
        #expect(Mail42Widget.makeWidget(id: "calendar") == nil)
        #expect(Mail42Widget.hostedIDs == Mail42Widget.allIDs)
    }
}
