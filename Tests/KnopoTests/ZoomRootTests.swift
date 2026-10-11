import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

/// A zoomed outline shows its root block as the first row. Zooming into a
/// childless block used to show an empty outline instead.
@MainActor
@Suite struct ZoomRootTests {
    @Test func zoomShowsTheRootAndKeepsEditsInside() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-zoom-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Notes")
        page.blocks = [Block(content: "Before"), Block(content: "Leaf"), Block(content: "After")]
        store.updatePage(page)
        let leaf = page.blocks[1].id
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: ScrollView {
            OutlineEditorView(pageName: "Notes", zoom: leaf)
                .environmentObject(app).environmentObject(nav)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() async throws {
            for _ in 0..<8 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func blocks() -> [Block] { app.document(for: "Notes").blocks }
        try await settle()
        let table = try #require(descendants(host, of: OutlineTableView.self).first)
        let controller = try #require(table.delegate as? OutlineEditorController)

        // The childless block is the outline: no empty placeholder is added.
        #expect(table.numberOfRows == 1)
        #expect(blocks()[1].children.isEmpty)

        // Enter at the end of the root adds its first child, in view.
        controller.focusBlock(leaf, selection: NSRange(location: 4, length: 0))
        controller.editorSplit(atUTF16Offset: 4)
        try await settle()
        #expect(blocks().map(\.content) == ["Before", "Leaf", "After"])
        #expect(blocks()[1].children.count == 1)
        #expect(table.numberOfRows == 2)

        // Outdenting that child would move it out of the view: refused.
        let child = blocks()[1].children[0].id
        controller.focusBlock(child, selection: NSRange(location: 0, length: 0))
        controller.editorOutdent()
        #expect(blocks()[1].children.map(\.id) == [child])
        // Indenting the root would move it: refused.
        controller.focusBlock(leaf, selection: NSRange(location: 0, length: 0))
        controller.editorIndent()
        #expect(blocks().map(\.id)[1] == leaf)
        controller.endEditing()
    }

    @Test func pasteIntoTheRootStaysInside() async throws {
        try await withZoom(on: [Block(content: "Before"), Block(content: ""), Block(content: "After")],
                           root: 1) { app, controller, rootID in
            @MainActor func blocks() -> [Block] { app.document(for: "Notes").blocks }
            // An empty root takes the first pasted block and keeps its id.
            controller.focusBlock(rootID, selection: NSRange(location: 0, length: 0))
            controller.editorPasteBlocks(
                "- one\n  status:: active\n  background-color:: red\n  - one child\n- two")
            #expect(blocks().map(\.content) == ["Before", "one", "After"])
            #expect(blocks()[1].id == rootID)
            #expect(blocks()[1].properties == [BlockProperty(key: "status", value: "active"),
                                               BlockProperty(key: "background-color", value: "red")])
            #expect(blocks()[1].children.map(\.content) == ["one child", "two"])

            // A non-empty root gets the blocks as its first children.
            controller.focusBlock(rootID, selection: NSRange(location: 3, length: 0))
            controller.editorPasteBlocks("- three\n- four")
            #expect(blocks().map(\.content) == ["Before", "one", "After"])
            #expect(blocks()[1].children.map(\.content) == ["three", "four", "one child", "two"])
            controller.endEditing()
        }
    }

    @Test func copyAndCutWithACollapsedRootSelected() async throws {
        var parent = Block(content: "Parent", children: [Block(content: "A"), Block(content: "B")])
        parent.collapsed = true
        try await withZoom(on: [parent, Block(content: "After")], root: 0) { app, controller, rootID in
            #expect(controller.selectAllBlocks())
            // Each child once: the root shows them as rows, not as a folded subtree.
            #expect(controller.selectionMarkdown() == "- Parent\n  - A\n  - B\n")
            // Cut removes the selected children and keeps the root, so the
            // clipboard leaves the root out. A private pasteboard spares the real one.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("knopo-test-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            controller.cutSelection(to: pasteboard)
            #expect(pasteboard.string(forType: .string) == "- A\n- B\n")
            let blocks = app.document(for: "Notes").blocks
            #expect(blocks.map(\.content) == ["Parent", "After"])
            #expect(blocks[0].id == rootID)
            #expect(blocks[0].children.isEmpty)
        }
    }

    private func withZoom(
        on pageBlocks: [Block], root rootIndex: Int,
        _ body: @MainActor (AppState, OutlineEditorController, UUID) async throws -> Void
    ) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-zoom-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GraphStore(root: dir)
        var page = try store.createPage(named: "Notes")
        page.blocks = pageBlocks
        store.updatePage(page)
        let rootID = page.blocks[rootIndex].id
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: ScrollView {
            OutlineEditorView(pageName: "Notes", zoom: rootID)
                .environmentObject(app).environmentObject(nav)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<8 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let table = try #require(descendants(host, of: OutlineTableView.self).first)
        let controller = try #require(table.delegate as? OutlineEditorController)
        try await body(app, controller, rootID)
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }
}
