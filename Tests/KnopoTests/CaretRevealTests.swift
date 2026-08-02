import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// Keeping the caret on screen (SPEC §5.4). The editor is one block tall inside a
/// scrolling outline, so AppKit's own caret scrolling never fires — the caret is
/// always "visible" within the text view's own bounds. These run a real scroll
/// view in an offscreen window, since the behaviour *is* the geometry.
@MainActor
@Suite struct CaretRevealTests {

    /// Table rows run top-down, so the stand-in document view must be flipped
    /// like the outline's — otherwise "below the fold" is off by a whole page.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private struct Rig {
        let scroll: NSScrollView
        let editor: BlockEditorTextView
        let window: NSWindow
    }

    /// An editor placed `offset` points down a tall document, in a short clip.
    private func rig(offset: CGFloat, text: String = "a block to put the caret in") -> Rig {
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 220, height: 2_000))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 200))
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(scroll)

        let editor = BlockEditorTextView.create()
        editor.frame = NSRect(x: 0, y: offset, width: 220, height: 40)
        document.addSubview(editor)
        editor.setContent(text)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        if let layout = editor.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        window.layoutIfNeeded()
        editor.layoutSubtreeIfNeeded()
        return Rig(scroll: scroll, editor: editor, window: window)
    }

    @Test func caretBelowTheFoldScrollsIntoView() {
        let rig = rig(offset: 1_500)
        #expect(!rig.scroll.documentVisibleRect.intersects(rig.editor.frame))
        rig.editor.revealCaret()
        #expect(rig.scroll.documentVisibleRect.contains(rig.editor.frame))
    }

    @Test func caretAboveTheFoldScrollsIntoView() {
        let rig = rig(offset: 40)
        rig.scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_200))
        rig.scroll.reflectScrolledClipView(rig.scroll.contentView)
        #expect(!rig.scroll.documentVisibleRect.intersects(rig.editor.frame))
        rig.editor.revealCaret()
        #expect(rig.scroll.documentVisibleRect.contains(rig.editor.frame))
    }

    /// Revealing a caret that is already comfortably in view must not scroll —
    /// otherwise every keystroke would nudge the page.
    @Test func caretAlreadyInViewLeavesTheScrollAlone() {
        let rig = rig(offset: 80)
        let before = rig.scroll.documentVisibleRect.origin
        rig.editor.revealCaret()
        #expect(rig.scroll.documentVisibleRect.origin == before)
    }
}
