import AppKit
import SwiftUI
import Testing
@testable import Knopo
@testable import KnopoCore

@MainActor
@Suite(.serialized) struct ReferencesSectionTests {
    private func hit(_ id: UUID, _ content: String = "") -> BacklinkHit {
        BacklinkHit(blockID: id, pageKey: "notes", pageDisplayName: "Notes", content: content)
    }

    @Test func rowsNestUnderAncestorRowsAndShareBreadcrumbs() {
        let root = BreadcrumbItem(id: UUID(), content: "Root")
        let portal = BreadcrumbItem(id: UUID(), content: "Portal")
        let (parent, child, sibling, later) = (UUID(), UUID(), UUID(), UUID())
        let parentItem = BreadcrumbItem(id: parent, content: "Parent")
        let rows = ResultRowLayout.layout(
            [hit(parent), hit(child), hit(sibling), hit(later)],
            ancestors: [
                parent: [root, portal],
                child: [root, portal, parentItem],
                sibling: [root, portal],
                later: [root],
            ])
        #expect(rows.map(\.depth) == [0, 1, 0, 0])
        // The child sits under its parent row with no path left to show.
        #expect(rows[0].breadcrumb == [root, portal])
        #expect(rows[1].breadcrumb.isEmpty)
        // A sibling with the same path does not repeat it, even after a nested row.
        #expect(rows[2].breadcrumb.isEmpty)
        #expect(rows[3].breadcrumb == [root])
    }

    @Test(arguments: [CGFloat(0.8), 1, 1.5])
    func plainResultRowsKeepTheirOriginalAlignment(zoom: CGFloat) async throws {
        let previous = BlockRenderer.zoom
        defer { BlockRenderer.zoom = previous }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-result-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var doc = try store.createPage(named: "Notes")
        doc.blocks = [Block(content: "Breadcrumb", children: [Block(content: "Body [[Target]]")])]
        store.updatePage(doc)
        try store.savePage(named: "Notes")
        let hits = try store.cache.backlinks(of: "target")
        let app = AppState(store: store)
        defer { app.shutdown() }
        BlockRenderer.zoom = zoom
        let host = NSHostingView(rootView: BlockResultList(groups: [(key: "Notes", value: hits)], editable: false)
            .environmentObject(app).environmentObject(Navigator(app: app))
            .frame(width: 600, alignment: .topLeading))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await waitUntil {
            window.layoutIfNeeded()
            return self.descendants(host, of: RenderedTextView.self).count == 1
        }
        let text = try #require(descendants(host, of: RenderedTextView.self).first)
        // SwiftUI rounds the hosted AppKit view to a pixel boundary.
        let expectedTextX = BlockResultList.levelIndent + ResultRowLayout.bulletSize / 2
            + OutlineMarkerLayout.bulletCenterOffset + ResultRowLayout.markerInset
        #expect(abs(text.convert(text.bounds, to: host).minX - expectedTextX) <= 0.5)
        let gutter = ResultRowLayout.gutterWidth(slot: 0)
        let leading = BlockResultList.levelIndent - ResultRowLayout.dotInset
        let dotLeft = leading + gutter - ResultRowLayout.markerInset
            - OutlineMarkerLayout.bulletCenterOffset - ResultRowLayout.bulletSize / 2
        let breadcrumbLeft = leading + ResultRowLayout.dotInset
        // Keep the hit area generous and align the dot with its breadcrumb and page title.
        #expect(gutter >= 18 * zoom)
        #expect(abs(dotLeft - breadcrumbLeft) < 0.01)
        #expect(abs(dotLeft - BlockResultList.levelIndent) < 0.01)
    }

    @Test(arguments: [false, true])
    func rowsUseTheOutlineTextViewAndOpenLinks(showBrackets: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-references-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        _ = try store.createPage(named: "Target")
        var source = try store.createPage(named: "Source")
        source.blocks = [
            Block(content: "### Heading with [[Target]] and [[Other]]"),
            Block(content: "Plain [[Target]]"),
        ]
        store.updatePage(source)
        try store.savePage(named: "Source")
        try #require(try store.cache.backlinks(of: PageName.key("Target")).count == 2)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let previousBrackets = BlockRenderer.bracketsEnabled
        BlockRenderer.bracketsEnabled = showBrackets
        defer { BlockRenderer.bracketsEnabled = previousBrackets }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: ReferencesSection(pageName: "Target")
            .environmentObject(app).environmentObject(nav)
            .frame(width: 600, alignment: .topLeading))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await waitUntil {
            window.layoutIfNeeded()
            return descendants(host, of: RenderedTextView.self).count == 2
        }

        let views = descendants(host, of: RenderedTextView.self)
        let expected = showBrackets
            ? ["Heading with [[Target]] and [[Other]]", "Plain [[Target]]"]
            : ["Heading with Target and Other", "Plain Target"]
        #expect(views.map(\.string) == expected)
        let heading = try #require(views.first)
        // A heading row is bold at body size, not heading size.
        let font = try #require(heading.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == BlockRenderer.baseFontSize)
        #expect(heading.frame.height < BlockRenderer.headingFont(level: 3).pointSize * 2)

        let other = (heading.string as NSString).range(of: "Other")
        let url = try #require(heading.textStorage?.attribute(.link, at: other.location, effectiveRange: nil) as? URL)
        heading.onLinkClick(url, false)
        #expect(nav.current == .page(name: "Other"))

        let plain = try #require(views.last)
        try clickText(plain, in: window, modifiers: .shift)
        #expect(nav.rightPanes.first?.target == .page(name: "Source"))
    }

    @Test func imageResizeInARowWritesToTheSourceBlock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-references-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try GraphStore(root: root)
        _ = try seed.createPage(named: "Target")
        var source = try seed.createPage(named: "Source")
        source.blocks = [Block(content: "![pic](../assets/pic.png) for [[Target]]")]
        seed.updatePage(source)
        try seed.savePage(named: "Source")
        // A matching file adopts indexed IDs on reopening. Exercise the fallback
        // too, with a live block whose volatile ID has since been replaced.
        let store = try GraphStore(root: root)
        let hit = try #require(try store.cache.backlinks(of: PageName.key("Target")).first)
        var reopened = try store.page(named: "Source")
        #expect(reopened.blocks[0].id == hit.blockID)
        reopened.blocks[0] = Block(content: reopened.blocks[0].content)
        store.updatePage(reopened)
        try #require(store.page(named: "Source").blocks[0].id != hit.blockID)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: ReferencesSection(pageName: "Target")
            .environmentObject(app).environmentObject(nav)
            .frame(width: 600, alignment: .topLeading))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await waitUntil {
            window.layoutIfNeeded()
            return !descendants(host, of: RenderedTextView.self).isEmpty
        }

        let view = try #require(descendants(host, of: RenderedTextView.self).first)
        #expect(view.allowsImageResize)
        view.onImageResize(0, 120)
        let resized = InlineParser.settingImageWidth(
            "![pic](../assets/pic.png) for [[Target]]", imageIndex: 0, width: 120)
        #expect(app.document(for: "Source").blocks[0].content == resized)

        // In-place edits resolve the same stale id.
        #expect(BlockResultList.updateSourceBlock(app, hit.blockID, undoLabel: "Edit Reference") {
            $0 + " edited"
        })
        #expect(app.document(for: "Source").blocks[0].content == (resized ?? "") + " edited")
    }

    @Test func tagViewRowsAreReadOnlyAndOpenTheirBlock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-tag-view-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var source = try store.createPage(named: "Source")
        source.blocks = [Block(content: "### Plain words ![pic](../assets/pic.png) #idea")]
        store.updatePage(source)
        try store.savePage(named: "Source")
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: TagViewScreen(tag: "idea")
            .environmentObject(app).environmentObject(nav)
            .frame(width: 600, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await waitUntil {
            window.layoutIfNeeded()
            return !descendants(host, of: RenderedTextView.self).isEmpty
        }

        let view = try #require(descendants(host, of: RenderedTextView.self).first)
        #expect(!view.allowsImageResize)
        let font = try #require(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == BlockRenderer.baseFontSize)
        // A plain click on text opens the block. Cmd-click opens it in the sidebar.
        try clickText(view, in: window)
        #expect(nav.current == .page(name: "Source"))
        #expect(nav.highlightTarget?.content == source.blocks[0].content)
        nav.navigate(to: .journalHome)
        try clickText(view, in: window, modifiers: .command)
        #expect(nav.current == .journalHome)
        #expect(nav.rightPanes.first?.target == .page(name: "Source"))
    }

    /// Sends a real mouse-down to the start of the text, so the click takes the
    /// text view's own modifier routing.
    private func clickText(
        _ view: RenderedTextView, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []
    ) throws {
        let point = NSPoint(x: 2, y: view.textContainerInset.height + 6)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: view.convert(point, to: nil),
            modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }
}
