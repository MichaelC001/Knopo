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
        view.emptyHint = OutlineEditorController.emptyPageHint
        view.setContent("")
        #expect(BlockEditorTextView.measureHeight(for: "", width: width) == plain)
        #expect(view.string.isEmpty) // the hint never entered the storage
    }

    @Test func hintIsNotPartOfTheText() {
        let view = BlockEditorTextView.create()
        view.emptyHint = OutlineEditorController.emptyPageHint
        view.setContent("")
        #expect(view.string == "")
        #expect(view.textStorage?.length == 0)
        // …and it is exposed to assistive tech instead of being invisible.
        #expect(view.accessibilityPlaceholderValue() as? String
            == OutlineEditorController.emptyPageHint)
    }

    /// Clearing the hint (the editor moves to a normal block) must not leave the
    /// previous block's hint behind.
    @Test func hintClearsWhenTheEditorMovesOn() {
        let view = BlockEditorTextView.create()
        view.emptyHint = OutlineEditorController.emptyPageHint
        view.emptyHint = nil
        #expect(view.accessibilityPlaceholderValue() == nil)
    }
}
