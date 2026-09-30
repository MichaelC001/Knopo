import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

/// Space on selected blocks previews their images and PDFs, as in Finder.
@MainActor
@Suite struct QuickLookSelectionTests {
    private func graph() throws -> (root: URL, store: GraphStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-quicklook-\(UUID().uuidString)")
        let store = try GraphStore(root: root)
        try FileManager.default.createDirectory(at: store.assetsDir, withIntermediateDirectories: true)
        return (root, store)
    }

    private func writePNG(_ url: URL) throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func writePDF(_ url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
    }

    private func render(_ content: String, assets: URL) -> NSAttributedString {
        BlockRenderer.render(
            content: content,
            context: BlockRenderer.Context(resolveBlockRef: { _ in nil }, assetsDir: assets))
    }

    @Test func filesComeInOrderWithoutRepeats() throws {
        let (root, store) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = store.assetsDir
        try writePNG(assets.appendingPathComponent("a.png"))
        try writePDF(assets.appendingPathComponent("doc.pdf"))
        let files = OutlineEditorController.previewFiles(in: [
            render("![a](../assets/a.png) text ![d](doc.pdf)", assets: assets),
            // Adjacent copies share an attribute run. A repeat is listed once.
            render("![x](a.png)![y](a.png)", assets: assets),
            render("no images here", assets: assets),
        ])
        #expect(files.map(\.lastPathComponent) == ["a.png", "doc.pdf"])
    }

    @Test func missingFilesAndEmbeddedImagesAreLeftOut() throws {
        let (root, store) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = store.assetsDir
        try writePNG(assets.appendingPathComponent("own.png"))
        try writePNG(assets.appendingPathComponent("embedded.png"))
        let host = NSMutableAttributedString(attributedString: render(
            "![o](own.png) ![gone](gone.png)", assets: assets))
        // An embed's transcluded text is marked as its region.
        let embedded = NSMutableAttributedString(attributedString: render(
            "![e](embedded.png)", assets: assets))
        embedded.addAttribute(.embedRegion, value: true,
                              range: NSRange(location: 0, length: embedded.length))
        host.append(embedded)
        let files = OutlineEditorController.previewFiles(in: [host])
        #expect(files.map(\.lastPathComponent) == ["own.png"])
    }

    /// The page in an offscreen window, so the outline builds its rows.
    private func rig(_ store: GraphStore, page: String) async throws
        -> (app: AppState, window: NSWindow, controller: OutlineEditorController) {
        let app = AppState(store: store)
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: PageScreen(pageName: page)
            .environmentObject(app).environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<10 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        let table = try #require(descendants(host, of: OutlineTableView.self).first)
        let controller = try #require(table.delegate as? OutlineEditorController)
        return (app, window, controller)
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? [])
            + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func pressSpace(in table: NSTableView) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        table.keyDown(with: event)
    }

    @Test func spaceOnSelectedBlocksPreviewsTheirFiles() async throws {
        let (root, store) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePNG(store.assetsDir.appendingPathComponent("a.png"))
        try writePDF(store.assetsDir.appendingPathComponent("doc.pdf"))
        var doc = store.page(named: "Reading")
        doc.blocks = [
            Block(content: "Plain text"),
            Block(content: "![a](../assets/a.png)"),
            Block(content: "![d](../assets/doc.pdf) and ![a](../assets/a.png)"),
        ]
        store.updatePage(doc)
        try store.savePage(named: "Reading")
        let (app, _, controller) = try await rig(store, page: "Reading")
        defer { app.shutdown() }
        var shown: [URL]?
        controller.toggleQuickLook = { files, _ in shown = files }
        let ids = app.document(for: "Reading").blocks.map(\.id)

        // Blocks 2 and 3: the PNG once, then the PDF.
        controller.selectViaClick(ids[1], extend: false, toggle: false)
        controller.selectViaClick(ids[2], extend: true, toggle: false)
        try pressSpace(in: controller.tableView)
        #expect(shown?.map(\.lastPathComponent) == ["a.png", "doc.pdf"])

        // A block with nothing to preview leaves Space alone.
        shown = nil
        controller.selectViaClick(ids[0], extend: false, toggle: false)
        try pressSpace(in: controller.tableView)
        #expect(shown == nil)
    }
}
