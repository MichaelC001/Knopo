import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// The column carried across a `↑`/`↓` block hop. The editor needs real layout to
/// answer where the caret is, so these run it in an offscreen window (never
/// ordered front) rather than mocking the geometry.
@MainActor
@Suite struct CaretColumnTests {

    private func editor(_ text: String, width: CGFloat = 220) -> BlockEditorTextView {
        let view = BlockEditorTextView.create()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        view.textContainer?.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        view.setContent(text)
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Wrapped over several visual lines at this width, so "first line" and "last
    /// line" are distinct places to land.
    private let wrapped = "alpha bravo charlie delta echo foxtrot golf hotel india"

    @Test func caretXTracksTheCaret() throws {
        let view = editor(wrapped)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let atStart = try #require(view.caretX)
        view.setSelectedRange(NSRange(location: 4, length: 0))
        let laterOnTheLine = try #require(view.caretX)
        #expect(laterOnTheLine > atStart)
    }

    /// Landing on the first line at a given column puts the caret at that column,
    /// not at offset 0 — which is what `↓` into this block used to do.
    @Test func placingOnTheFirstLineHitsTheColumn() throws {
        let view = editor(wrapped)
        view.setSelectedRange(NSRange(location: 4, length: 0))
        let goal = try #require(view.caretX)

        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.placeCaret(atGoalX: goal, onFirstLine: true)
        #expect(view.selectedRange().location > 0)
        let landed = try #require(view.caretX)
        #expect(abs(landed - goal) < 6) // within a character's width of the column
    }

    /// And `↑` into a block lands on its *last* line at the same column, rather
    /// than at the very end of the text.
    @Test func placingOnTheLastLineHitsTheColumn() throws {
        let view = editor(wrapped)
        let end = (wrapped as NSString).length
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let goal = try #require(view.caretX)

        view.placeCaret(atGoalX: goal, onFirstLine: false)
        let landed = view.selectedRange().location
        #expect(landed < end) // not flung to the end of the text
        #expect(abs(try #require(view.caretX) - goal) < 6)
        // …and it really is on the last visual line: same line rect as the end.
        func lineMidY(_ offset: Int) -> CGFloat {
            view.firstRect(forCharacterRange: NSRange(location: offset, length: 0),
                           actualRange: nil).midY
        }
        #expect(abs(lineMidY(landed) - lineMidY(end)) < 2)
    }

    /// An empty block has nowhere to aim: the caret goes to its only position.
    @Test func emptyBlockPlacesAtZero() {
        let view = editor("")
        view.placeCaret(atGoalX: 120, onFirstLine: true)
        #expect(view.selectedRange().location == 0)
    }

    /// A goal column past the end of the target line clamps to that line's end
    /// instead of overshooting into the next one.
    @Test func columnPastTheLineEndClampsToIt() throws {
        let view = editor("short")
        view.placeCaret(atGoalX: 5_000, onFirstLine: true)
        #expect(view.selectedRange().location == ("short" as NSString).length)
    }
}
