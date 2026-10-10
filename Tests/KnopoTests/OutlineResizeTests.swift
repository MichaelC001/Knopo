import AppKit
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct OutlineResizeTests {
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    @MainActor private final class Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-resize-\(UUID().uuidString)")
        let app: AppState
        let controller: OutlineEditorController
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 500))
        let document = DocumentView()
        let window: NSWindow
        let blockID: UUID
        let offset: CGFloat

        init(shared: Bool) throws {
            let store = try GraphStore(root: root)
            var page = try store.createPage(named: "Resize")
            page.blocks = (0..<400).map { Block(content: "Block \($0)") }
            store.updatePage(page)
            try store.savePage(named: page.name)
            blockID = page.blocks[0].id
            app = AppState(store: store)
            controller = OutlineEditorController(app: app, nav: Navigator(app: app))
            controller.inPane = shared
            controller.applyPaneRole()
            offset = shared ? 2_000 : 0
            controller.tableView.frame.size.width = 420
            controller.present(pageName: page.name, zoom: nil)
            scroll.documentView = document
            document.addSubview(controller.tableView)
            window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.contentView = scroll
            layout()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        }

        func layout() {
            let table = controller.tableView
            table.frame = NSRect(x: 0, y: offset, width: scroll.contentSize.width,
                                 height: table.intrinsicContentSize.height)
            document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width,
                                    height: table.frame.maxY + 100)
            window.layoutIfNeeded()
            table.layoutSubtreeIfNeeded()
            table.viewWillDraw()
        }

        func settle() async throws {
            for _ in 0..<5 {
                layout()
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func focus() throws -> BlockEditorTextView {
            controller.focusBlock(blockID, selection: NSRange(location: 3, length: 0))
            return try #require(window.firstResponder as? BlockEditorTextView)
        }

        func close() {
            controller.endEditing()
            app.shutdown()
            window.contentView = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test(arguments: [false, true])
    func resizeDoesNotRevealAnOffscreenEditor(shared: Bool) async throws {
        let rig = try Rig(shared: shared)
        defer { rig.close() }
        try await rig.settle()
        let editor = try rig.focus()
        try await rig.settle()
        let cell = editor.superview
        rig.scroll.contentView.scroll(to: NSPoint(x: 0, y: rig.offset + 5_000))
        try await rig.settle()
        #expect(editor.window === rig.window)
        #expect(rig.window.firstResponder === editor)
        #expect(editor.superview === cell)
        var liveRows = 0
        rig.controller.tableView.enumerateAvailableRowViews { _, _ in liveRows += 1 }
        #expect(liveRows < 100)
        let position = rig.scroll.documentVisibleRect.origin
        rig.window.setContentSize(NSSize(width: 500, height: 500))
        try await rig.settle()
        #expect(abs(rig.scroll.documentVisibleRect.minY - position.y) < 1)
        #expect(editor.superview === cell)
        #expect(rig.window.firstResponder === editor)
        rig.scroll.contentView.scroll(to: NSPoint(x: 0, y: rig.offset))
        try await rig.settle()
        #expect(editor.superview === cell)
        #expect(editor.string == "Block 0")
    }

    @Test(arguments: [false, true])
    func resizePreservesMarkedTextAndItsHost(shared: Bool) async throws {
        let rig = try Rig(shared: shared)
        defer { rig.close() }
        try await rig.settle()
        let editor = try rig.focus()
        try await rig.settle()
        editor.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 3, length: 0))
        try #require(editor.hasMarkedText())
        let marked = editor.markedRange()
        let selection = editor.selectedRange()
        let content = editor.string
        let cell = editor.superview
        rig.window.setContentSize(NSSize(width: 280, height: 500))
        try await rig.settle()
        #expect(editor.hasMarkedText())
        #expect(editor.markedRange() == marked)
        #expect(editor.selectedRange() == selection)
        #expect(editor.string == content)
        #expect(editor.superview === cell)
        #expect(rig.window.firstResponder === editor)
    }

    @Test func fontChangesKeepSharedRowsBounded() throws {
        let rig = try Rig(shared: true)
        defer { rig.close() }
        let editor = try rig.focus()
        let selection = editor.selectedRange()
        let oldZoom = BlockRenderer.zoom
        defer { BlockRenderer.zoom = oldZoom }
        // No suspension while a global rendering preference is changed.
        for zoom in [CGFloat(1.2), 0.9] {
            BlockRenderer.zoom = zoom
            rig.controller.present(pageName: "Resize", zoom: nil)
            rig.layout()
            var liveRows = 0
            rig.controller.tableView.enumerateAvailableRowViews { _, _ in liveRows += 1 }
            #expect(liveRows < 100)
            #expect(rig.window.firstResponder === editor)
            #expect(editor.selectedRange() == selection)
            #expect(editor.string == "Block 0")
        }
    }

    @Test(arguments: [false, true])
    func widthChangesKeepOrdinaryCellsAndRepositionAutocomplete(shared: Bool) async throws {
        let rig = try Rig(shared: shared)
        defer { rig.close() }
        try await rig.settle()
        let table = rig.controller.tableView
        let cell = try #require(table.view(atColumn: 0, row: 2, makeIfNecessary: false))
        rig.window.setContentSize(NSSize(width: 500, height: 500))
        try await rig.settle()
        #expect(table.view(atColumn: 0, row: 2, makeIfNecessary: false) === cell)

        let editor = try rig.focus()
        try await rig.settle()
        editor.insertText(String(repeating: "long words ", count: 20) + "[[",
                          replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await rig.settle()
        let autocomplete = try #require(editor.autocomplete)
        try #require(autocomplete.isActive)
        let panel = try #require(rig.window.childWindows?.first)
        let before = panel.frame
        let host = editor.superview
        rig.window.setContentSize(NSSize(width: 280, height: 500))
        try await rig.settle()
        #expect(autocomplete.isActive)
        #expect(rig.window.childWindows?.first === panel)
        #expect(panel.frame != before)
        #expect(editor.superview === host)
        #expect(rig.window.firstResponder === editor)
    }
}
