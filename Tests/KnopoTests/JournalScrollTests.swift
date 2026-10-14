import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct JournalScrollTests {
    @Test(arguments: [NSScroller.Style.legacy, .overlay])
    func initialWidthAccountsForScrollbar(style: NSScroller.Style) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 450))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = style
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 20_000))
        scroll.tile()
        #expect(JournalView.outlineWidth(in: scroll.frame.size, scrollerStyle: style)
            == scroll.contentSize.width - 40)
    }

    private func tables(in view: NSView) -> [OutlineTableView] {
        ((view as? OutlineTableView).map { [$0] } ?? [])
            + view.subviews.flatMap { tables(in: $0) }
    }

    private final class ResizeWindow: NSWindow {
        var resizing = false
        override var inLiveResize: Bool { resizing || super.inLiveResize }
    }

    @Test func liveResizeDoesNotRefreshQueriesUntilDataChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-journal-query-resize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var source = try store.createPage(named: "Resize source")
        source.blocks = [Block(content: "Before resize #resize")]
        store.updatePage(source)
        try store.savePage(named: source.name)
        let day = JournalDate.today().adding(days: -1).pageName
        var journal = store.page(named: day)
        journal.blocks = [Block(content: "{{query #resize}}")]
        store.updatePage(journal)
        try store.savePage(named: day)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: JournalView()
            .environmentObject(app).environmentObject(nav))
        let window = ResizeWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() async throws {
            for _ in 0..<10 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func renderedText(in view: NSView) -> String {
            ((view as? RenderedTextView)?.string ?? "")
                + view.subviews.map { renderedText(in: $0) }.joined()
        }
        try await settle()
        let table = try #require(tables(in: host).first {
            ($0.delegate as? OutlineEditorController)?.pageName == day
        })
        #expect(renderedText(in: table).contains("Before resize"))

        // Change the query's answer without publishing a data update. A width
        // update alone must not rerun it during live resize.
        source.blocks[0].content = "After resize #resize"
        let stamp = GraphStore.stamp(of: store.fileURL(forPageNamed: source.name))
        try store.cache.indexPage(source, stamp: stamp)
        window.resizing = true
        for width: CGFloat in [680, 660, 640] {
            window.setContentSize(NSSize(width: width, height: 450))
            try await settle()
            #expect(renderedText(in: table).contains("Before resize"))
            #expect(!renderedText(in: table).contains("After resize"))
        }
        // A data change still refreshes results, even when the width also changes.
        app.dataVersion += 1
        window.setContentSize(NSSize(width: 620, height: 450))
        try await settle()
        #expect(renderedText(in: table).contains("After resize"))
        window.resizing = false
        table.onLiveResizeEnd?()
        try await settle()
    }

    @Test func fastUpwardScrollingReturnsToNewerDays() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-journal-scroll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let today = JournalDate.today()
        for offset in 0..<730 {
            var doc = store.page(named: today.adding(days: -offset).pageName)
            doc.blocks = (0..<(4 + offset % 13)).map { index in
                Block(content: "Entry \(offset), block \(index). "
                    + String(repeating: "Daily notes with variable line wrapping. ",
                             count: (offset + index) % 9))
            }
            store.updatePage(doc)
            try store.savePage(named: doc.name)
        }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: JournalView()
            .environmentObject(app).environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        let scroll = try #require(tables(in: host).first?.enclosingScrollView)
        let document = try #require(scroll.documentView)

        func settle(_ frames: Int = 10) async throws {
            for _ in 0..<frames {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func scrollBy(_ distance: CGFloat) async throws {
            let y = max(0, scroll.documentVisibleRect.minY + distance)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(1)
        }
        func newestVisibleDay() throws -> String {
            // Use document coordinates. An offscreen table's visibleRect can
            // remain nonempty while SwiftUI keeps its editor attached.
            let visible = tables(in: host).filter {
                $0.convert($0.bounds, to: document).intersects(scroll.documentVisibleRect)
            }
            let days = visible.compactMap {
                ($0.delegate as? OutlineEditorController)?.pageName
            }
            return try #require(days.max())
        }

        // Let today's automatic caret reveal expire before moving the feed.
        try await settle(50)
        window.makeFirstResponder(nil)
        for width: CGFloat in [700, 480] {
            window.setContentSize(NSSize(width: width, height: 450))
            try await settle()
            for table in tables(in: host) {
                let controller = try #require(table.delegate as? OutlineEditorController)
                #expect(controller.initialLayoutWidth == scroll.contentSize.width - 40)
                // Offscreen tables keep their old frame until SwiftUI places them again.
                if table.convert(table.bounds, to: document).intersects(scroll.documentVisibleRect) {
                    #expect(table.bounds.width == scroll.contentSize.width - 40)
                }
            }
            for _ in 0..<80 { try await scrollBy(100) }
            try await settle()
            var previous = try newestVisibleDay()
            #expect(previous < today.adding(days: -5).pageName)

            // Each burst requests 900 points toward newer days. A lazy height
            // correction must not move the reader to an older day instead.
            for _ in 0..<10 {
                for _ in 0..<6 { try await scrollBy(-150) }
                try await settle()
                let current = try newestVisibleDay()
                #expect(current >= previous,
                        "Upward scroll moved from \(previous) to \(current) at width \(width)")
                previous = current
                #expect(tables(in: host).count < 32, "The journal must keep loading days lazily")
            }
            #expect(previous == today.pageName)
            #expect(scroll.documentVisibleRect.minY < 1)
        }
    }
}
