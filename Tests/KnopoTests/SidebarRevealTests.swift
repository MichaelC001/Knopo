import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct SidebarRevealTests {
    @Test func openingAPaneRevealsItsTop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-sidebar-reveal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        for name in ["Alpha", "Beta", "Gamma"] {
            var page = try store.createPage(named: name)
            page.blocks = (0..<60).map { Block(content: "\(name) block \($0)") }
            store.updatePage(page)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.rightPanes = [RightPane(target: .page(name: "Alpha")),
                          RightPane(target: .page(name: "Beta"))]
        let host = NSHostingView(rootView: RightSidebar().environmentObject(app).environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() async throws {
            for _ in 0..<8 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, T.self) }
        }
        try await settle()
        let scroll = try #require(descendants(host, NSScrollView.self).first)
        func scrollAway() async throws {
            let document = try #require(scroll.documentView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - 700))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle()
            #expect(scroll.contentView.bounds.minY > 700)
        }
        // New, existing, already first, and collapsed panes must all be revealed.
        for name in ["Gamma", "alpha", "Alpha", "Beta"] {
            if name == "Beta" {
                let index = try #require(nav.rightPanes.firstIndex { $0.target == .page(name: name) })
                nav.toggleRightPaneCollapsed(at: index)
                try await settle()
            }
            try await scrollAway()
            nav.openInRightSidebar(.page(name: name))
            try await settle()
            #expect(abs(scroll.contentView.bounds.minY + scroll.contentInsets.top) < 0.5,
                    "Opened \(name) should preserve the sidebar's top padding")
        }

        // Result links retain their more specific destination inside the pane.
        let block = try #require(app.document(for: "Gamma").blocks.last)
        nav.navigateToBlock(pageName: "Gamma", blockID: block.id, content: block.content, inSidebar: true)
        try await settle()
        let table = try #require(descendants(host, OutlineTableView.self).first {
            ($0.delegate as? OutlineEditorController)?.pageName == "Gamma"
        })
        #expect(table.visibleRect.intersects(table.rect(ofRow: 59)))
        #expect(scroll.contentView.bounds.minY > 700)

        // The next result owns the shared scroll view while earlier layouts settle.
        let nextBlock = try #require(app.document(for: "Alpha").blocks.last)
        nav.navigateToBlock(pageName: "Alpha", blockID: nextBlock.id,
                            content: nextBlock.content, inSidebar: true)
        try await settle()
        let nextTable = try #require(descendants(host, OutlineTableView.self).first {
            ($0.delegate as? OutlineEditorController)?.pageName == "Alpha"
        })
        #expect(nextTable.visibleRect.intersects(nextTable.rect(ofRow: 59)))
        table.needsLayout = true
        table.layoutSubtreeIfNeeded()
        try await settle()
        #expect(nextTable.visibleRect.intersects(nextTable.rect(ofRow: 59)))

        nav.openInRightSidebar(.page(name: "Gamma"))
        try await settle()
        #expect(abs(scroll.contentView.bounds.minY + scroll.contentInsets.top) < 0.5)

        // A stale result still opens a useful page when its block is gone.
        try await scrollAway()
        nav.navigateToBlock(pageName: "Beta", blockID: UUID(),
                            content: "Deleted block", inSidebar: true)
        try await settle()
        #expect(nav.rightPanes.first?.target == .page(name: "Beta"))
        #expect(abs(scroll.contentView.bounds.minY + scroll.contentInsets.top) < 0.5)
    }
}
