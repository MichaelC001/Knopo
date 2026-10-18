import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// What a `[[page]]` hover preview shows (SPEC §6.1).
@MainActor
@Suite struct HoverPreviewTests {

    @Test(arguments: [false, true])
    func hoverPreviewsFollowAnimationPreference(chip: Bool) throws {
        let name = "knopo-preview-motion-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults, syncsRenderer: false, reduceMotion: { true })
        let cell = OutlineRowCell(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        let window = NSWindow(contentRect: cell.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(cell)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let content: NSAttributedString
        if chip {
            let attachment = NSTextAttachment()
            attachment.image = NSImage(size: NSSize(width: 40, height: 20))
            content = NSAttributedString(attachment: attachment)
        } else {
            content = NSAttributedString(string: "Preview content")
        }
        cell.callbacks.pagePreview = { _ in content }
        cell.callbacks.animationsEnabled = { preferences.animationsEnabled }
        cell.showRendered(NSAttributedString(string: "Page link"))
        cell.layoutSubtreeIfNeeded()
        func findRenderedView(_ view: NSView) -> RenderedTextView? {
            if let rendered = view as? RenderedTextView { return rendered }
            for child in view.subviews {
                if let rendered = findRenderedView(child) { return rendered }
            }
            return nil
        }
        let rendered = try #require(findRenderedView(cell))
        defer { rendered.onHoverEnded() }
        for mode in Preferences.Animations.allCases {
            preferences.animations = mode
            rendered.onHoverRef(.page("Preview"), .zero)
            let popover = try #require(cell.previewPopover)
            #expect(popover.isShown)
            #expect(popover.animates == (mode == .on))
            preferences.animations = .off
            rendered.onHoverEnded()
            #expect(!popover.animates)
            #expect(cell.previewPopover == nil)
        }
    }

    private func controller(_ store: GraphStore) -> (OutlineEditorController, AppState) {
        let app = AppState(store: store)
        return (OutlineEditorController(app: app, nav: Navigator(app: app)), app)
    }

    private func store() throws -> GraphStore {
        try GraphStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-preview-\(UUID().uuidString)"))
    }

    /// The pointer is on the link that names the page, so the preview doesn't
    /// repeat it.
    @Test func previewLeavesOutThePageTitle() throws {
        let store = try store()
        var doc = store.page(named: "Roadmap")
        doc.blocks = [Block(content: "first block"), Block(content: "second block")]
        store.updatePage(doc)
        try store.savePage(named: "Roadmap")
        let (controller, app) = controller(store)
        defer { app.shutdown() }
        let preview = try #require(controller.previewAttributedString(forPage: "Roadmap"))
        #expect(!preview.string.contains("Roadmap"))
        #expect(preview.string.contains("first block"))
        #expect(preview.string.contains("second block"))
    }

    /// A page with nothing in it would show a blank popover, so it shows a chip.
    @Test func aPageWithNothingInItShowsAChip() throws {
        let store = try store()
        let (controller, app) = controller(store)
        defer { app.shutdown() }
        let preview = try #require(controller.previewAttributedString(forPage: "Nowhere"))
        var attachments = 0
        preview.enumerateAttribute(.attachment, in: NSRange(location: 0, length: preview.length)) {
            value, _, _ in if value != nil { attachments += 1 }
        }
        #expect(attachments == 1)
        #expect(preview.string.trimmingCharacters(in: .whitespacesAndNewlines).count <= 1)
    }

    /// A tag's blocks come from anywhere, so each line names its page.
    @Test func tagPreviewNamesThePageOfEachBlock() throws {
        let store = try store()
        var doc = store.page(named: "Roadmap")
        doc.blocks = [Block(content: "ship it #followup")]
        store.updatePage(doc)
        try store.savePage(named: "Roadmap")
        let (controller, app) = controller(store)
        defer { app.shutdown() }
        let preview = try #require(controller.previewAttributedString(forTag: "followup"))
        #expect(preview.string.contains("Roadmap"))
        #expect(preview.string.contains("ship it"))
    }

    /// Blank blocks are not lines worth showing.
    @Test func emptyBlocksDoNotBecomeBulletedBlanks() throws {
        let store = try store()
        var doc = store.page(named: "Sparse")
        doc.blocks = [Block(content: ""), Block(content: "kept"), Block(content: "")]
        store.updatePage(doc)
        try store.savePage(named: "Sparse")
        let (controller, app) = controller(store)
        defer { app.shutdown() }
        let preview = try #require(controller.previewAttributedString(forPage: "Sparse"))
        #expect(preview.string.split(separator: "\n").count == 1)
        #expect(preview.string.contains("kept"))
    }
}
