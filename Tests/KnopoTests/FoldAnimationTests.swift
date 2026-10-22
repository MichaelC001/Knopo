import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct FoldAnimationTests {
    @Test(arguments: [false, true], [false, true])
    func bothDirectionsAnimateAtTheEndAndBetweenRows(shared: Bool, atEnd: Bool) async throws {
        try await withOutline(shared: shared, childCount: 3, atEnd: atEnd, visible: true) {
            _, _, table, window in
            try await checkMotion(row: 1, table: table, window: window)
            try await checkMotion(row: 1, table: table, window: window)
        }
    }

    @Test func nestedSingleChildAnimatesInBothDirections() async throws {
        try await withOutline(childCount: 1, visible: true) { _, _, table, window in
            try await checkMotion(row: 2, table: table, window: window)
            try await checkMotion(row: 2, table: table, window: window)
        }
    }

    @Test(arguments: [Preferences.Animations.off, .system])
    func disabledFoldsSettleImmediately(mode: Preferences.Animations) async throws {
        try await withOutline(childCount: 3, visible: true, animations: mode) { _, _, table, window in
            let container = try #require(table.superview as? OutlineContainerView)
            for _ in 0..<2 {
                try fold(row: 1, in: table)
                window.layoutIfNeeded()
                #expect(!container.isAnimatingHeight)
                #expect(abs(container.frame.height - table.intrinsicContentSize.height) < 1)
            }
        }
    }

    private func checkMotion(row: Int, table: OutlineTableView, window: NSWindow) async throws {
        let container = try #require(table.superview as? OutlineContainerView)
        let parent = table.rowView(atRow: row, makeIfNecessary: true)
        let trailing = table.rowView(atRow: table.numberOfRows - 1, makeIfNecessary: true)
        let trailingText = trailing.map { descendants($0, of: RenderedTextView.self).map(\.string) }
        let start = container.frame.height
        let started = ContinuousClock.now
        try fold(row: row, in: table)
        window.layoutIfNeeded()
        let target = table.intrinsicContentSize.height
        try #require(abs(start - target) > 1)
        // The fold animates from the old height. Slow CI runners can skip every
        // frame in between, so mid-fold rows are checked only when a sample catches one.
        #expect(container.isAnimatingHeight)
        #expect(abs(container.frame.height - start) < 1)
        // A surviving last row must not be recycled for an inserted child.
        func checkTrailingRow() {
            guard trailingText == ["After"], let trailing else { return }
            #expect(table.rowView(atRow: table.numberOfRows - 1,
                                  makeIfNecessary: false) === trailing)
            #expect(abs(trailing.frame.minY
                        - table.rect(ofRow: table.numberOfRows - 1).minY) < 1)
        }
        checkTrailingRow()
        try await waitUntil {
            window.layoutIfNeeded()
            let height = container.frame.height
            if height > min(start, target) + 1, height < max(start, target) - 1 {
                checkTrailingRow()
            }
            return !container.isAnimatingHeight
        }
        // A cancel would end the 0.16 s fold early. A slow runner only ends it late.
        #expect(ContinuousClock.now - started >= .milliseconds(120))
        window.layoutIfNeeded()
        #expect(table.rowView(atRow: row, makeIfNecessary: false) === parent)
        #expect(abs(container.frame.height - target) < 1)
        #expect(abs(table.frame.height - target) < 1)
    }

    @Test func largeFoldKeepsTheEditorAndNestedFoldState() async throws {
        try await withOutline { app, controller, table, window in
            let before = app.document(for: "Folding").blocks[0]
            controller.focusBlock(before.id, selection: NSRange(location: 3, length: 2))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            let host = editor.superview
            let firstRow = table.rowView(atRow: 0, makeIfNecessary: true)

            // This subtree is large enough to trigger the normal full-reload cutoff.
            try fold(row: 1, in: table)
            #expect(table.numberOfRows == 3)
            #expect(app.document(for: "Folding").blocks[1].collapsed)
            #expect(table.rowView(atRow: 0, makeIfNecessary: true) === firstRow)
            #expect(editor.superview === host)
            #expect(window.firstResponder === editor)
            #expect(editor.selectedRange() == NSRange(location: 3, length: 2))

            try fold(row: 1, in: table)
            #expect(table.numberOfRows == 44)
            #expect(app.document(for: "Folding").blocks[1].children[0].collapsed)
            #expect(editor.superview === host)
            #expect(editor.selectedRange() == NSRange(location: 3, length: 2))
            try await settle(window)
            #expect(abs(table.frame.height - table.rect(ofRow: 43).maxY) < 1)
        }
    }

    @Test func repeatedFoldsCanBeFollowedImmediatelyByEditing() async throws {
        try await withOutline { app, controller, table, window in
            // Toggle faster than the animation duration, then edit immediately.
            for _ in 0..<6 {
                try fold(row: 1, in: table)
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(table.numberOfRows == 44)
            let parent = app.document(for: "Folding").blocks[1]
            controller.focusBlock(parent.id, selection: NSRange(location: 6, length: 0))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            editor.insertText(" edited", replacementRange: editor.selectedRange())
            try fold(row: 1, in: table)
            try await settle(window)
            #expect(table.numberOfRows == 3)
            #expect(app.document(for: "Folding").blocks[1].content == "Parent edited")
            #expect(window.firstResponder === editor)
            #expect(editor.string == "Parent edited")
            #expect(abs(table.frame.height - table.rect(ofRow: 2).maxY) < 1)
        }
    }

    @Test func editorBelowTheFoldKeepsItsCellAndCaret() async throws {
        try await withOutline(childCount: 3, visible: true) { app, controller, table, window in
            let after = try #require(app.document(for: "Folding").blocks.last)
            controller.focusBlock(after.id, selection: NSRange(location: 1, length: 2))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            try await settle(window)
            let host = editor.superview
            for _ in 0..<2 {
                try fold(row: 1, in: table)
                #expect(editor.superview === host)
                try await settle(window)
                #expect(editor.superview === host)
                #expect(window.firstResponder === editor)
                #expect(editor.string == "After")
                #expect(editor.selectedRange() == NSRange(location: 1, length: 2))
                #expect(table.row(for: editor) == table.numberOfRows - 1)
                let rowView = try #require(table.rowView(atRow: table.numberOfRows - 1,
                                                        makeIfNecessary: false))
                #expect(abs(rowView.frame.minY - table.rect(ofRow: table.numberOfRows - 1).minY) < 1)
            }
        }
    }

    @Test func foldingClearsSelectionBeforeRowIndexesChange() async throws {
        try await withOutline { app, controller, table, _ in
            let blocks = app.document(for: "Folding").blocks
            controller.selectViaClick(blocks[1].children[0].id, extend: false, toggle: false)
            try #require(controller.selectionMarkdown() != nil)
            try fold(row: 1, in: table)
            #expect(controller.selectionMarkdown() == nil)
            #expect(table.hasBlockSelection?() == false)
            #expect(app.document(for: "Folding").blocks.map(\.id) == blocks.map(\.id))
        }
    }

    @Test func foldingPreservesSelectionsOutsideTheSubtree() async throws {
        try await withOutline(childCount: 3) { app, controller, table, window in
            let blocks = app.document(for: "Folding").blocks
            controller.selectViaClick(blocks[0].id, extend: false, toggle: false)
            controller.selectViaClick(blocks[2].id, extend: false, toggle: true)
            for _ in 0..<2 {
                try fold(row: 1, in: table)
                try await settle(window)
                #expect(controller.selectionMarkdown() == "- Before\n- After\n")
                #expect(table.hasBlockSelection?() == true)
            }
        }
    }

    @Test func foldingAnEditedChildRestoresItsTextBeforeRemoval() async throws {
        try await withOutline { app, controller, table, window in
            let child = app.document(for: "Folding").blocks[1].children[0]
            controller.focusBlock(child.id, selection: NSRange(location: 6, length: 0))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            editor.insertText(" edited", replacementRange: editor.selectedRange())
            let cell = try #require(OutlineRowCell.enclosing(editor))
            try fold(row: 1, in: table)
            #expect(editor.superview == nil)
            #expect(window.firstResponder !== editor)
            let rendered = try #require(descendants(cell, of: RenderedTextView.self).first)
            #expect(!rendered.isHidden)
            #expect(rendered.string == "Nested edited")
            try await settle(window)
            #expect(table.numberOfRows == 3)
        }
    }

    @Test func sharedOutlineKeepsLargeFoldViewsBounded() async throws {
        try await withOutline(shared: true, childCount: 400) { _, _, table, window in
            try fold(row: 1, in: table)
            try fold(row: 1, in: table)
            try await settle(window)
            var liveRows = 0
            table.enumerateAvailableRowViews { _, _ in liveRows += 1 }
            #expect(table.numberOfRows == 404)
            #expect(liveRows < 100)
            #expect(abs(table.frame.height - table.rect(ofRow: 403).maxY) < 1)
        }
    }

    private func fold(row: Int, in table: OutlineTableView) throws {
        let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true)
                                as? OutlineRowCell)
        cell.callbacks.toggleFold()
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<12 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func withOutline(
        shared: Bool = false, childCount: Int = 40, atEnd: Bool = false, visible: Bool = false,
        animations: Preferences.Animations = .on,
        _ body: (AppState, OutlineEditorController, OutlineTableView, NSWindow) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-fold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Folding")
        let nested = Block(content: "Nested", children: [Block(content: "Hidden grandchild")],
                           collapsed: true)
        page.blocks = [Block(content: "Before"),
                       Block(content: "Parent", children: [nested]
                             + (0..<childCount).map { Block(content: "Child \($0)") }),
                       Block(content: "After")]
        if atEnd { page.blocks.removeLast() }
        store.updatePage(page)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        let preferences = Preferences(defaults: defaults, syncsRenderer: false, reduceMotion: { true })
        preferences.animations = animations
        let app = AppState(store: store, preferences: preferences)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: ScrollView {
            OutlineEditorView(pageName: page.name, inPane: shared)
                .environmentObject(app).environmentObject(nav)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        if visible {
            window.title = "Knopo Fold Animation Test"
            window.orderFront(nil)
        }
        defer { window.orderOut(nil) }
        defer { window.contentView = nil }
        try await settle(window)
        let table = try #require(descendants(host, of: OutlineTableView.self).first)
        let controller = try #require(table.delegate as? OutlineEditorController)
        defer { controller.endEditing() }
        try await body(app, controller, table, window)
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }
}
