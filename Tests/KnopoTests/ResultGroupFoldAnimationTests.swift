import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct ResultGroupFoldAnimationTests {
    @Test func tagPageGroupsSlideAndCanReverseMidFold() async throws {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        try await withTagPage { window, host in
            let following = try #require(textViews(host).first { $0.string.hasPrefix("Beta block 0") })
            let expandedY = following.convert(.zero, to: host).y
            for collapsed in [true, false] {
                let startY = following.convert(.zero, to: host).y
                try clickChevron(in: window, host: host)
                var positions: [CGFloat] = []
                for _ in 0..<12 {
                    try await Task.sleep(for: .milliseconds(20))
                    window.layoutIfNeeded()
                    positions.append(following.convert(.zero, to: host).y)
                }
                let endY = try #require(positions.last)
                #expect(abs(startY - endY) > 40)
                let intermediate = positions.filter {
                    $0 > min(startY, endY) + 1 && $0 < max(startY, endY) - 1
                }
                #expect(intermediate.isEmpty == reduceMotion)
                // SwiftUI may retain cached text views inside a zero-size container.
                #expect(textViews(host).filter {
                    $0.string.hasPrefix("Alpha") && !$0.visibleRect.isEmpty
                }.count == (collapsed ? 0 : 3))
                if !collapsed { #expect(abs(endY - expandedY) < 1) }
            }
            for _ in 0..<4 {
                try clickChevron(in: window, host: host)
                try await Task.sleep(for: .milliseconds(30))
                window.layoutIfNeeded()
            }
            try await settle(window)
            #expect(textViews(host).count == 6)
            #expect(abs(following.convert(.zero, to: host).y - expandedY) < 1)
        }
    }

    @Test func largeTagGroupsKeepOffscreenRowsLazy() async throws {
        try await withTagPage(firstGroupCount: 2_000) { window, host in
            #expect(!textViews(host).isEmpty)
            #expect(textViews(host).count < 100)
            try clickChevron(in: window, host: host)
            try await settle(window)
            let visible = textViews(host).filter { !$0.visibleRect.isEmpty }
            #expect(visible.count == 3)
            #expect(visible.allSatisfy { $0.string.hasPrefix("Beta") })
            try clickChevron(in: window, host: host)
            try await settle(window)
            #expect(textViews(host).count < 150)
            #expect(textViews(host).contains {
                $0.string.hasPrefix("Alpha block 0") && !$0.visibleRect.isEmpty
            })
        }
    }

    private func withTagPage(
        firstGroupCount: Int = 3,
        _ body: (NSWindow, NSView) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-tag-fold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        for name in ["Alpha", "Beta"] {
            var page = try store.createPage(named: name)
            let count = name == "Alpha" ? firstGroupCount : 3
            page.blocks = (0..<count).map { Block(content: "\(name) block \($0) #idea") }
            store.updatePage(page)
            try store.savePage(named: name)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: TagViewScreen(tag: "idea", inPane: true)
            .environmentObject(app).environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Knopo Tag Fold Animation Test"
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle(window)
        try await body(window, host)
    }

    private func clickChevron(in window: NSWindow, host: NSView) throws {
        let point = host.convert(NSPoint(x: 27, y: 27), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private func textViews(_ view: NSView) -> [RenderedTextView] {
        ((view as? RenderedTextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<12 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
