import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct BlockReferenceRefreshTests {
    private let original = "### **This is a nice happy block**"
    private let updated = "### **This is a nice happy block** (update) "
        + String(repeating: "longer reference text ", count: 8)
    private let updatedPreview = "This is a nice happy block (update) "
        + String(repeating: "longer reference text ", count: 8)

    @Test(arguments: [false, true])
    func samePageReferenceRefreshesAfterSaving(leaveEditor: Bool) async throws {
        try await withOutline(samePage: true) { app, controller, window in
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            let host = editor.superview
            let oldHeight = controller.tableView.rect(ofRow: 1).height
            editor.insertText(updated, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            let selection = editor.selectedRange()
            if leaveEditor { controller.endEditing() }
            app.flushPendingSaves()
            try await settle(window)

            #expect(try referenceText(controller) == "Reference: " + updatedPreview)
            #expect(controller.tableView.rect(ofRow: 1).height > oldHeight)
            if !leaveEditor {
                #expect(window.firstResponder === editor)
                #expect(editor.superview === host)
                #expect(editor.selectedRange() == selection)
                #expect(editor.string == updated)
            }
        }
    }

    @Test func anotherPageReferenceRefreshesWithoutInterruptingComposition() async throws {
        try await withOutline(samePage: false) { app, controller, window in
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            editor.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: 0, length: 0))
            try #require(editor.hasMarkedText())
            let marked = editor.markedRange()
            let selection = editor.selectedRange()
            let content = editor.string
            let host = editor.superview

            var source = app.document(for: "Source")
            source.blocks[0].content = updated
            app.commit(source)
            app.flushPendingSaves()
            try await settle(window)

            #expect(try referenceText(controller) == "Reference: " + updatedPreview)
            #expect(window.firstResponder === editor)
            #expect(editor.superview === host)
            #expect(editor.string == content)
            #expect(editor.markedRange() == marked)
            #expect(editor.selectedRange() == selection)
        }
    }

    private func withOutline(
        samePage: Bool,
        _ body: (AppState, OutlineEditorController, NSWindow) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-block-ref-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var source = try store.createPage(named: "Source")
        source.blocks = [Block(content: original)]
        let reference = Block(content: "Reference: ((\(source.blocks[0].id.uuidString.lowercased())))")
        var shown = samePage ? source : try store.createPage(named: "References")
        if !samePage { shown.blocks = [Block(content: "Keep typing here")] }
        shown.blocks.append(reference)
        store.updatePage(source)
        store.updatePage(shown)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: ScrollView {
            OutlineEditorView(pageName: shown.name)
                .environmentObject(app).environmentObject(nav)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await settle(window)
        let table = try #require(descendants(host, of: OutlineTableView.self).first)
        let controller = try #require(table.delegate as? OutlineEditorController)
        controller.focusBlock(shown.blocks[0].id, selection: NSRange(location: 0, length: 0))
        defer { controller.endEditing() }
        try await settle(window)
        #expect(try referenceText(controller) == "Reference: This is a nice happy block")
        try await body(app, controller, window)
    }

    private func referenceText(_ controller: OutlineEditorController) throws -> String {
        let cell = try #require(controller.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true))
        return try #require(descendants(cell, of: RenderedTextView.self).first).string
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<8 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
