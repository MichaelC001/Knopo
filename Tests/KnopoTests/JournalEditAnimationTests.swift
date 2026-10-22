import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct JournalEditAnimationTests {
    @Test(arguments: [Preferences.Animations.on, .off, .system], [0, 1])
    func followingDaysMoveWithInsertionsAndDeletions(mode: Preferences.Animations, dayOffset: Int) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-journal-edit-animation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let today = JournalDate.today()
        for offset in 0...2 {
            var page = store.page(named: today.adding(days: -offset).pageName)
            page.blocks = [Block(content: "Before"), Block(content: "After")]
            store.updatePage(page)
            try store.savePage(named: page.name)
        }
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        let preferences = Preferences(defaults: defaults, syncsRenderer: false, reduceMotion: { true })
        preferences.animations = mode
        let app = AppState(store: store, preferences: preferences)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: JournalView()
            .environmentObject(app).environmentObject(nav))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Knopo Journal Edit Animation Test"
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle(window)
        let outlines = tables(in: host)
        let editedDay = today.adding(days: -dayOffset).pageName
        let followingDay = today.adding(days: -dayOffset - 1).pageName
        let table = try #require(outlines.first {
            ($0.delegate as? OutlineEditorController)?.pageName == editedDay
        })
        let following = try #require(outlines.first {
            ($0.delegate as? OutlineEditorController)?.pageName == followingDay
        })
        let container = try #require(table.superview as? OutlineContainerView)
        let controller = try #require(table.delegate as? OutlineEditorController)
        defer { controller.endEditing() }
        let document = try #require(table.enclosingScrollView?.documentView)
        controller.focusBlock(app.document(for: editedDay).blocks[0].id,
                              selection: NSRange(location: 3, length: 0))
        try await settle(window)
        let editor = try #require(window.firstResponder as? BlockEditorTextView)
        let originalContents = app.document(for: editedDay).blocks.map(\.content)
        func followingY() -> CGFloat { following.convert(.zero, to: document).y }
        for deleting in [false, true] {
            let startHeight = container.frame.height
            let startY = followingY()
            if deleting { controller.editorMergeWithPrevious() }
            else { controller.editorSplit(atUTF16Offset: 3) }
            let targetHeight = table.intrinsicContentSize.height
            let delta = targetHeight - startHeight
            try #require(abs(delta) > 1)
            #expect(deleting ? delta < 0 : delta > 0)
            window.layoutIfNeeded()
            #expect(window.firstResponder === editor)
            #expect(container.isAnimatingHeight == (mode == .on))
            #expect(container.clipsToBounds)
            if mode == .on {
                // The next day must start at its old position, not jump to the end.
                #expect(abs(container.frame.height - startHeight) < 1)
                #expect(abs(followingY() - startY) < 1)
            }
            try await waitUntil {
                window.layoutIfNeeded()
                // The whole following day tracks the outline's changing height.
                #expect(abs((followingY() - startY) - (container.frame.height - startHeight)) < 1)
                return !container.isAnimatingHeight
            }
            window.layoutIfNeeded()
            #expect(abs(container.frame.height - targetHeight) < 1)
            #expect(abs(followingY() - startY - delta) < 1)
            #expect(container.clipsToBounds)
            try await settle(window)
        }
        #expect(app.document(for: editedDay).blocks.map(\.content) == originalContents)

        if mode == .on {
            controller.editorSplit(atUTF16Offset: 3)
            #expect(container.isAnimatingHeight)
            controller.editorSplit(atUTF16Offset: 0)
            window.layoutIfNeeded()
            #expect(!container.isAnimatingHeight)
            #expect(abs(container.frame.height - table.intrinsicContentSize.height) < 1)
            try await settle(window)
        }

        // Tab expands a collapsed parent. Its newly revealed children must not
        // draw over the next day before the outline has grown to fit them.
        controller.endEditing()
        let moved = Block(content: "Move under parent")
        var page = app.document(for: editedDay)
        page.blocks = [Block(content: "Parent", children: (0..<6).map {
            Block(content: "Hidden child \($0)")
        }, collapsed: true), moved]
        app.commit(page)
        app.dataVersion += 1
        try await settle(window)
        controller.focusBlock(moved.id, selection: NSRange(location: 0, length: 0))
        try await settle(window)
        let startHeight = container.frame.height
        let startY = followingY()
        controller.editorIndent()
        window.layoutIfNeeded()
        #expect(table.intrinsicContentSize.height > startHeight)
        #expect(container.isAnimatingHeight == (mode == .on))
        #expect(container.clipsToBounds)
        try await waitUntil {
            window.layoutIfNeeded()
            #expect(container.clipsToBounds)
            #expect(abs((followingY() - startY) - (container.frame.height - startHeight)) < 1)
            return !container.isAnimatingHeight
        }
        #expect(app.document(for: editedDay).blocks[0].children.last?.id == moved.id)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<12 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func tables(in view: NSView) -> [OutlineTableView] {
        ((view as? OutlineTableView).map { [$0] } ?? [])
            + view.subviews.flatMap { tables(in: $0) }
    }
}
