import AppKit
import Testing
@testable import Knopo

@MainActor
@Suite struct ToolbarFrostTests {
    @Test func frostLeavesBottomAccessoriesTheirOwnMaterial() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let content = NSView()
        window.contentView = content
        defer { window.contentView = nil }
        let view = ToolbarFrostView(frame: NSRect(x: 0, y: 0, width: 600, height: 52))
        content.addSubview(view)
        let material = try #require(view.subviews.first)

        func layout() {
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
        }

        layout()
        #expect(material.frame == view.bounds)

        let tabs = NSTitlebarAccessoryViewController()
        tabs.automaticallyAdjustsSize = false
        tabs.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 36))
        window.addTitlebarAccessoryViewController(tabs)
        view.setFrameSize(NSSize(width: 600, height: 88))
        layout()
        #expect(material.frame == NSRect(x: 0, y: 36, width: 600, height: 52))

        tabs.view.setFrameSize(NSSize(width: 600, height: 28))
        view.setFrameSize(NSSize(width: 800, height: 80))
        layout()
        #expect(material.frame == NSRect(x: 0, y: 28, width: 800, height: 52))

        tabs.isHidden = true
        view.setFrameSize(NSSize(width: 800, height: 52))
        layout()
        #expect(material.frame == view.bounds)

        tabs.isHidden = false
        view.setFrameSize(NSSize(width: 800, height: 0))
        layout()
        #expect(material.frame.height == 0)
    }
}
