import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// Where opening an outline puts the caret (SPEC §5.4). A journal day is somewhere
/// you go to write, so today's opens ready to type; pages you opened to read stay
/// as they are.
@MainActor
@Suite struct WritingFocusTests {

    private let today = JournalDate.today()
    private let block = UUID()

    /// Today's journal is a writing surface: with content already there, opening it
    /// adds a trailing block to type in.
    @Test func todaysJournalWithContentAppendsABlock() {
        #expect(OutlineEditorController.writingFocus(
            forPage: today.pageName, isEmptyTail: false, tailBlockID: block,
            rowCount: 3, today: today) == .appendTrailing)
    }

    /// …but never stacks another one when the tail is already empty, or every
    /// visit would leave one more blank block behind.
    @Test func todaysJournalReusesAnEmptyTail() {
        #expect(OutlineEditorController.writingFocus(
            forPage: today.pageName, isEmptyTail: true, tailBlockID: block,
            rowCount: 3, today: today) == .focus(block))
        #expect(OutlineEditorController.writingFocus(
            forPage: today.pageName, isEmptyTail: true, tailBlockID: block,
            rowCount: 1, today: today) == .focus(block))
    }

    /// A past day is opened to read. Appending a caret there would dirty an old
    /// file and steal focus from what you came to look at.
    @Test func pastJournalDaysStayQuiet() {
        let past = today.adding(days: -9)
        #expect(OutlineEditorController.writingFocus(
            forPage: past.pageName, isEmptyTail: false, tailBlockID: block,
            rowCount: 4, today: today) == .none)
        // Even an empty tail on a past day is left alone — unless the day is
        // *entirely* empty, which is the blank-page case every page gets.
        #expect(OutlineEditorController.writingFocus(
            forPage: past.pageName, isEmptyTail: true, tailBlockID: block,
            rowCount: 4, today: today) == .none)
        #expect(OutlineEditorController.writingFocus(
            forPage: past.pageName, isEmptyTail: true, tailBlockID: block,
            rowCount: 1, today: today) == .focus(block))
    }

    /// An ordinary page keeps the narrow rule: ready to write only when there is
    /// nothing to read — one empty block, as a merely-linked page looks.
    @Test func ordinaryPagesOnlyWhenBlank() {
        #expect(OutlineEditorController.writingFocus(
            forPage: "Marina", isEmptyTail: true, tailBlockID: block,
            rowCount: 1, today: today) == .focus(block))
        #expect(OutlineEditorController.writingFocus(
            forPage: "Marina", isEmptyTail: true, tailBlockID: block,
            rowCount: 5, today: today) == .none)
        #expect(OutlineEditorController.writingFocus(
            forPage: "Marina", isEmptyTail: false, tailBlockID: block,
            rowCount: 5, today: today) == .none)
    }

    /// Auto-focusing a page's sole empty block must not write anything: no second
    /// block, no content, and no file created just because the page was shown.
    @Test func focusingAnEmptyPageWritesNothing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-hint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let app = AppState(store: store)
        defer { app.shutdown() }

        // A page with no file yet: the store synthesises one empty block, which is
        // the state the outline auto-focuses.
        let doc = app.document(for: "Fresh Page")
        #expect(doc.blocks.count == 1)
        #expect(doc.blocks[0].content.isEmpty)
        #expect(!doc.fileExists)

        // Focusing is not an edit, so a flush has nothing to commit and the page
        // stays absent from disk (SPEC §10: today's file is written on first content).
        app.flushPendingSaves()
        let pageFile = store.pagesDir.appendingPathComponent("Fresh Page.md")
        #expect(!FileManager.default.fileExists(atPath: pageFile.path))
        #expect(app.document(for: "Fresh Page").blocks.count == 1)
    }
}
