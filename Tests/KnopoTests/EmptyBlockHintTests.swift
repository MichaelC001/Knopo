import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// The hint shown in the one empty block of an otherwise-empty page (SPEC §5.4).
/// It is *drawn*, never inserted — so the invariant worth testing is that nothing
/// which reads the text can see it: not the height measurement, not find, not the
/// document, not the file on disk.
@MainActor
@Suite struct EmptyBlockHintTests {

    /// A hint must not change what the row measures to, or focusing an empty block
    /// would resize its row.
    @Test func hintDoesNotAffectMeasuredHeight() {
        let width: CGFloat = 400
        let plain = BlockEditorTextView.measureHeight(for: "", width: width)
        // The measuring path is a separate hidden view, but assert against a real
        // view carrying a hint too, so a future shared-instance refactor trips here.
        let view = BlockEditorTextView.create()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        view.emptyHint = BlockRenderer.emptyBlockHint
        view.setContent("")
        #expect(BlockEditorTextView.measureHeight(for: "", width: width) == plain)
        #expect(view.string.isEmpty) // the hint never entered the storage
    }

    @Test func hintIsNotPartOfTheText() {
        let view = BlockEditorTextView.create()
        view.emptyHint = BlockRenderer.emptyBlockHint
        view.setContent("")
        #expect(view.string == "")
        #expect(view.textStorage?.length == 0)
        // …and it is exposed to assistive tech instead of being invisible.
        #expect(view.accessibilityPlaceholderValue() as? String
            == BlockRenderer.emptyBlockHint)
    }

    /// The rendered row shows the same hint when the block isn't focused — that's
    /// what a right-sidebar pane, and an outline that couldn't take focus, fall
    /// back to. One string, one look, focused or not.
    @Test func theRenderedRowCarriesTheSameHint() {
        let view = RenderedTextView.create()
        view.emptyHint = BlockRenderer.emptyBlockHint
        #expect(view.emptyHint == BlockRenderer.emptyBlockHint)
        // Still nothing in the text: the hint is drawn, never inserted.
        #expect(view.textStorage?.length == 0)
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
            BlockRenderer.render(content: text, context: BlockRenderer.Context()))

        #expect(try baseline(of: editor) == BlockRenderer.firstBaselineOffset())
        #expect(try baseline(of: rendered) == BlockRenderer.firstBaselineOffset())
    }

    /// Clearing the hint (the editor moves to a normal block) must not leave the
    /// previous block's hint behind.
    @Test func hintClearsWhenTheEditorMovesOn() {
        let view = BlockEditorTextView.create()
        view.emptyHint = BlockRenderer.emptyBlockHint
        view.emptyHint = nil
        #expect(view.accessibilityPlaceholderValue() == nil)
    }
}
