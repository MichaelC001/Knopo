import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct SidebarFoldAnimationTests {
    @Test func cardFoldsMoveFollowingCardsAndRespectReduceMotion() async throws {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-sidebar-fold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        for name in ["Alpha", "Beta"] {
            var page = try store.createPage(named: name)
            page.blocks = (0..<3).map { Block(content: "\(name) block \($0)") }
            store.updatePage(page)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.rightPanes = [RightPane(target: .page(name: "Alpha")),
                          RightPane(target: .page(name: "Beta"))]
        let host = NSHostingView(rootView: RightSidebar()
            .environmentObject(app).environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.title = "Knopo Sidebar Fold Animation Test"
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle(window)

        let following = try #require(tables(host).first {
            ($0.delegate as? OutlineEditorController)?.pageName == "Beta"
        })
        let controller = try #require(following.delegate as? OutlineEditorController)
        controller.focusBlock(app.document(for: "Beta").blocks[0].id,
                              selection: NSRange(location: 2, length: 3))
        let editor = try #require(window.firstResponder as? BlockEditorTextView)
        defer { controller.endEditing() }
        try await settle(window)
        let expandedY = following.convert(.zero, to: host).y
        var collapsedY: CGFloat?
        for collapsed in [true, false] {
            let startY = following.convert(.zero, to: host).y
            try clickHeader(in: window, host: host)
            #expect(nav.rightPanes[0].collapsed == collapsed)
            var positions: [CGFloat] = []
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(20))
                window.layoutIfNeeded()
                positions.append(following.convert(.zero, to: host).y)
            }
            let endY = try #require(positions.last)
            #expect(abs(startY - endY) > 50)
            let intermediate = positions.filter {
                $0 > min(startY, endY) + 1 && $0 < max(startY, endY) - 1
            }
            #expect(intermediate.isEmpty == reduceMotion)
            #expect(tables(host).count == (collapsed ? 1 : 2))
            #expect(window.firstResponder === editor)
            #expect(editor.selectedRange() == NSRange(location: 2, length: 3))
            if collapsed { collapsedY = endY }
            else {
                #expect(abs(endY - expandedY) < 1)
                #expect(abs(endY - (collapsedY ?? endY)) > 50)
            }
        }

        // Reversing a transition must not leave duplicate or clipped editors.
        for step in 0..<4 {
            window.layoutIfNeeded()
            try clickHeader(in: window, host: host)
            #expect(nav.rightPanes[0].collapsed == (step % 2 == 0), "Rapid click \(step)")
            try await Task.sleep(for: .milliseconds(30))
        }
        try await settle(window)
        #expect(!nav.rightPanes[0].collapsed)
        #expect(tables(host).count == 2)
        #expect(abs(following.convert(.zero, to: host).y - expandedY) < 1)
        #expect(window.firstResponder === editor)

        let folding = try #require(tables(host).first { $0 !== following })
        let foldingController = try #require(folding.delegate as? OutlineEditorController)
        foldingController.focusBlock(app.document(for: "Alpha").blocks[0].id,
                                     selection: NSRange(location: 13, length: 0))
        let foldingEditor = try #require(window.firstResponder as? BlockEditorTextView)
        foldingEditor.insertText(" edited", replacementRange: foldingEditor.selectedRange())
        try await settle(window)
        for collapsed in [true, false] {
            try clickHeader(in: window, host: host)
            #expect(nav.rightPanes[0].collapsed == collapsed)
            try await Task.sleep(for: .milliseconds(30))
            window.layoutIfNeeded()
            #expect(tables(host).filter {
                ($0.delegate as? OutlineEditorController)?.pageName == "Alpha"
            }.count <= 1)
        }
        try await settle(window)
        #expect(app.document(for: "Alpha").blocks[0].content == "Alpha block 0 edited")
        #expect(tables(host).count == 2)
        if let focused = window.firstResponder as? BlockEditorTextView {
            #expect(focused.isDescendant(of: host))
        }
        try clickHeader(in: window, host: host)
        try await settle(window)
        #expect(tables(host).count == 1)
        #expect(window.firstResponder !== foldingEditor)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<12 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func tables(_ view: NSView) -> [OutlineTableView] {
        ((view as? OutlineTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables)
    }

    private func clickHeader(in window: NSWindow, host: NSView) throws {
        let point = host.convert(NSPoint(x: 80, y: 28), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }
}
