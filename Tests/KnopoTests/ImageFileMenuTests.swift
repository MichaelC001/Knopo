import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// A click on an image edits its block, so the block menu is how you get to the
/// file: Quick Look, Open in Default App, Reveal in Finder. Pages get Reveal in
/// Finder in their page menu.
@MainActor
@Suite struct ImageFileMenuTests {
    private func graph() throws -> (root: URL, store: GraphStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-image-menu-\(UUID().uuidString)")
        let store = try GraphStore(root: root)
        try FileManager.default.createDirectory(at: store.assetsDir, withIntermediateDirectories: true)
        return (root, store)
    }

    private func writePNG(_ url: URL, width: Int, height: Int) throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// Text, then an image on the next line, laid out in a view.
    private func view(
        assets: URL, content: String = "Before the image\n![shot](../assets/shot.png)"
    ) -> RenderedTextView {
        let view = RenderedTextView.create()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        view.textStorage?.setAttributedString(BlockRenderer.render(
            content: content,
            context: BlockRenderer.Context(resolveBlockRef: { _ in nil }, assetsDir: assets)))
        view.layoutSubtreeIfNeeded()
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        return view
    }

    @Test func rightClickOnImageFindsItsFile() throws {
        let (root, store) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = store.assetsDir.appendingPathComponent("shot.png")
        try writePNG(file, width: 100, height: 60)
        // Every hit names the file, and the hits cover the image's 100x60 area
        // below the text line, nothing else.
        let hits = try scanHits(view(assets: store.assetsDir), expecting: file)
        #expect(abs(hits.width - 100) <= 4 && abs(hits.height - 60) <= 4)
        // The text line comes first, so the image starts below it.
        #expect(hits.minY > 10)
    }

    /// Two copies of one file side by side share an attribute run. Both keep
    /// the menu, not just the first.
    @Test func adjacentCopiesOfOneImageBothFindTheFile() throws {
        let (root, store) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = store.assetsDir.appendingPathComponent("shot.png")
        try writePNG(file, width: 100, height: 60)
        let view = view(assets: store.assetsDir,
                        content: "![a](../assets/shot.png)![b](../assets/shot.png)")
        let hits = try scanHits(view, expecting: file)
        #expect(abs(hits.width - 200) <= 4 && abs(hits.height - 60) <= 4)
    }

    /// Scans the view in 2 pt steps and returns the bounds of the points that
    /// hit an image. Every hit must name `file`.
    private func scanHits(_ view: RenderedTextView, expecting file: URL) throws -> NSRect {
        var hits: [NSPoint] = []
        for y in stride(from: 0.0, through: 200.0, by: 2) {
            for x in stride(from: 0.0, through: 400.0, by: 2) {
                let point = NSPoint(x: x, y: y)
                guard let url = view.imageFile(at: point) else { continue }
                #expect(url.standardizedFileURL == file.standardizedFileURL)
                hits.append(point)
            }
        }
        let xs = hits.map(\.x), ys = hits.map(\.y)
        let minX = try #require(xs.min()), minY = try #require(ys.min())
        return NSRect(x: minX, y: minY,
                      width: (xs.max() ?? minX) - minX, height: (ys.max() ?? minY) - minY)
    }

    @Test func imageMenuItemsCarryTheFile() throws {
        let (root, store) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(store: store)
        defer { app.shutdown() }
        let controller = OutlineEditorController(app: app, nav: Navigator(app: app))
        let file = store.assetsDir.appendingPathComponent("book.pdf")
        let menu = NSMenu()
        controller.addImageFileItems(file, to: menu)
        #expect(menu.items.map(\.title) == ["Quick Look", "Open in Default App", "Reveal in Finder"])
        #expect(menu.items.allSatisfy { $0.representedObject as? URL == file && $0.target === controller })
    }

    @Test func pageFileIsNilForAStub() throws {
        let (root, store) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        var doc = store.page(named: "Saved")
        doc.blocks = [Block(content: "hello")]
        store.updatePage(doc)
        try store.savePage(named: "Saved")
        let app = AppState(store: store)
        defer { app.shutdown() }
        #expect(PageActions.file(of: "Saved", app: app)?.lastPathComponent == "Saved.md")
        #expect(PageActions.file(of: "Only Linked", app: app) == nil)
    }

    /// A Logseq journal file is `2026_06_10.md`. Referenced by its ISO name it is
    /// still found, because the loaded page carries the file's own name.
    @Test func journalFileResolvesFromISOName() throws {
        let (root, store) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: store.journalsDir, withIntermediateDirectories: true)
        try "- entry\n".write(to: store.journalsDir.appendingPathComponent("2026_06_10.md"),
                              atomically: true, encoding: .utf8)
        let reopened = try GraphStore(root: root)
        let app = AppState(store: reopened)
        defer { app.shutdown() }
        #expect(PageActions.file(of: "2026-06-10", app: app)?.lastPathComponent == "2026_06_10.md")
    }
}
