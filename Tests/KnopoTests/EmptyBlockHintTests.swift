import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// The hint shown in the one empty block of an otherwise-empty page (SPEC §5.4).
/// The hint stays out of text storage and is exposed as an accessibility placeholder.
@MainActor
@Suite struct EmptyBlockHintTests {

    @Test func hintUpdatesAccessibilityWithoutChangingTheText() {
        let view = BlockEditorTextView.create()
        view.setContent("")
        view.emptyHint = BlockRenderer.emptyBlockHint
        #expect(view.string == "")
        #expect(view.textStorage?.length == 0)
        #expect(view.accessibilityPlaceholderValue() == BlockRenderer.emptyBlockHint)

        view.emptyHint = nil
        #expect(view.accessibilityPlaceholderValue() == nil)
    }

    @Test func emptyTextKit2InsertionIndicatorUsesThePinnedBlockLineHeight() {
        let view = BlockEditorTextView.create()
        view.setContent("")
        let indicator = NSTextInsertionIndicator(frame: NSRect(
            x: 0, y: OutlineRowCell.contentInsetV, width: 0, height: 21))
        view.addSubview(indicator)
        view.layout()

        #expect(indicator.frame.origin == NSPoint(x: 0, y: OutlineRowCell.contentInsetV))
        #expect(indicator.frame.width == 0)
        #expect(indicator.frame.height == BlockRenderer.lineHeight(forSource: ""))

        view.setContent("real text")
        indicator.frame.size.height = 21
        view.layout()
        #expect(indicator.frame.height == 21)
    }

    /// The hint belongs to the block you are typing in, so an *unfocused* empty
    /// block shows no prose at all — unfocused, and with the empty leaf's bullet
    /// hidden, it read as page content rather than as somewhere to type. The
    /// bullet carries that job instead, per `hidesBullet`.
    @Test func anUnfocusedEmptyBlockShowsItsBulletRatherThanTheHint() {
        // A page's only block: bullet shown, so an empty page isn't blank.
        #expect(!OutlineEditorController.hidesBullet(
            content: "", hasChildren: false, isFocused: false, isOnlyRow: true))
        // An empty block among others keeps hiding its dot (SPEC §5.2)…
        #expect(OutlineEditorController.hidesBullet(
            content: "", hasChildren: false, isFocused: false, isOnlyRow: false))
        // …unless it is the one being typed in.
        #expect(!OutlineEditorController.hidesBullet(
            content: "", hasChildren: false, isFocused: true, isOnlyRow: false))
        // A parent, or any block with text, is never hidden.
        #expect(!OutlineEditorController.hidesBullet(
            content: "", hasChildren: true, isFocused: false, isOnlyRow: false))
        #expect(!OutlineEditorController.hidesBullet(
            content: "text", hasChildren: false, isFocused: false, isOnlyRow: false))
    }

    /// The hint stands in for text that isn't there, so it has to sit on exactly
    /// the baseline that text would use. It is *drawn*, not laid out, so nothing
    /// but this test keeps the two on the same line — and both view classes must
    /// agree, or the hint would jump when the block takes focus.
    @Test func hintDrawsOnTheBaselineTheBlocksOwnTextWouldUse() throws {
        func baseline(of view: NSTextView) throws -> CGFloat {
            let layout = try #require(view.textLayoutManager)
            layout.ensureLayout(for: layout.documentRange)
            let fragment = try #require(
                layout.textLayoutFragment(for: layout.documentRange.location))
            let line = try #require(fragment.textLineFragments.first)
            return fragment.layoutFragmentFrame.minY
                + line.typographicBounds.minY + line.glyphOrigin.y
        }
        let text = "Start typing"
        let editor = BlockEditorTextView.create()
        editor.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
        editor.setContent(text)
        let rendered = RenderedTextView.create()
        rendered.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
        rendered.textStorage?.setAttributedString(
            BlockRenderer.render(
                content: text,
                context: BlockRenderer.Context(journalDateFormat: .default)))

        #expect(try baseline(of: editor) == BlockRenderer.firstBaselineOffset())
        #expect(try baseline(of: rendered) == BlockRenderer.firstBaselineOffset())
    }
}
