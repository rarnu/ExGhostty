import AppKit
import Testing
@testable import Ghostty

struct SidebarBackgroundViewTests {
    @Test func isLayerBackedAfterInit() {
        let view = SidebarBackgroundView()
        #expect(view.wantsLayer == true)
        #expect(view.layer != nil)
        #expect(view.layer?.masksToBounds == true)
    }

    @Test func layerBackgroundColorMatchesInitialColor() {
        let color = NSColor.red
        let view = SidebarBackgroundView()
        view.backgroundColor = color
        #expect(view.layer?.backgroundColor == color.cgColor)
    }

    @Test func layerBackgroundColorUpdatesWhenPropertyChanges() {
        let view = SidebarBackgroundView()
        let initialColor = NSColor.blue
        let updatedColor = NSColor.green

        view.backgroundColor = initialColor
        #expect(view.layer?.backgroundColor == initialColor.cgColor)

        view.backgroundColor = updatedColor
        #expect(view.layer?.backgroundColor == updatedColor.cgColor)
    }
}
