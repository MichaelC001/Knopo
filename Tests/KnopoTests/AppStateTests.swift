import Foundation
import Testing
@testable import Knopo
import KnopoCore

@Suite struct AppStateTests {
    /// Typing `[[Mar` should surface real content pages (Marina, Mars) ahead of
    /// demoted matches — journal days and file-less reference stubs (e.g. a
    /// `[[Mar 1st, 2026]]` reference left by an unconverted Logseq import) — which
    /// otherwise flood the list.
    @MainActor
    @Test func pageAutocompleteRanksRealPagesAboveStubs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-pagenames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try GraphStore(root: root)
        func makePage(_ name: String, _ content: String) throws {
            var doc = try store.createPage(named: name)
            doc.blocks[0].content = content
            store.updatePage(doc)
            try store.savePage(named: name)
        }
        // Two real, created pages, plus a note that only *references* a
        // date-titled page — making "Mar 1st, 2026" a stub (no file).
        try makePage("Marina", "coastal notes")
        try makePage("Mars", "planet notes")
        try makePage("Log", "watched on [[Mar 1st, 2026]]")

        let app = AppState(store: store)
        defer { app.shutdown() }

        let names = app.pageNames(matching: "Mar")
        let marina = try #require(names.firstIndex(of: "Marina"))
        let mars = try #require(names.firstIndex(of: "Mars"))
        let stub = try #require(names.firstIndex(of: "Mar 1st, 2026"))
        #expect(marina < stub)
        #expect(mars < stub)
    }

    /// Keystrokes coalesce into one undo entry per edit session (SPEC §13), and
    /// that entry doesn't exist until the session closes — so undo has to close
    /// the open session *before* it pops, or it steps past the edit you just made.
    /// (Pressing ⌘Z right after deleting a word used to do nothing at all.)
    @MainActor
    @Test func undoClosesThePendingEditSessionBeforePopping() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-undo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var doc = try store.createPage(named: "Notes")
        doc.blocks[0].content = "alpha bravo"
        store.updatePage(doc)
        try store.savePage(named: "Notes")

        let app = AppState(store: store)
        defer { app.shutdown() }
        let before = app.document(for: "Notes")

        // Typing/deleting inside the focused block: committed, but deliberately
        // *not* an undo entry yet.
        var edited = before
        edited.blocks[0].content = "alpha"
        app.commit(edited)
        #expect(app.document(for: "Notes").blocks[0].content == "alpha")

        // The focused outline registers this; it turns the open session into an
        // entry. Undo must run it first — otherwise the stack is still empty.
        // Modelled on the real hook: it pushes only when the content actually
        // moved, and re-baselines afterwards (an unconditional push would clear
        // the redo stack and break redo).
        var sessionBefore = before
        var closes = 0
        app.closePendingEdit = { [weak app] in
            guard let app else { return }
            let current = app.document(for: "Notes")
            guard current.blocks[0].content != sessionBefore.blocks[0].content else { return }
            closes += 1
            app.commit(current, undoLabel: "Edit Block", before: sessionBefore)
            sessionBefore = current
        }

        app.undo()
        #expect(closes == 1)
        #expect(app.document(for: "Notes").blocks[0].content == "alpha bravo")

        // What the controller's re-baseline does once the undo has landed.
        sessionBefore = app.document(for: "Notes")
        app.redo()
        #expect(closes == 1) // nothing new to close, so redo isn't discarded
        #expect(app.document(for: "Notes").blocks[0].content == "alpha")
    }

    /// An app left open over midnight must roll the journal feed over by itself:
    /// nothing on disk changes at the boundary, so without the day watch the feed
    /// keeps offering the finished day as today. Afterwards the new day heads the
    /// feed and the day that just ended stays below it.
    @MainActor
    @Test func dayRolloverRefreshesTheJournalFeed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-rollover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try GraphStore(root: root)
        let app = AppState(store: store)
        defer { app.shutdown() }

        // The day about to end, with content — so it stays in the feed as history.
        var doc = try store.createPage(named: "2026-06-11")
        doc.blocks[0].content = "standup notes"
        store.updatePage(doc)
        try store.savePage(named: "2026-06-11")
        #expect(app.journalDays(today: "2026-06-11").first == "2026-06-11")

        let before = app.dataVersion
        let justPastMidnight = try #require(DateComponents(
            calendar: .current, year: 2026, month: 6, day: 12, hour: 0, minute: 0, second: 1
        ).date)
        app.checkDayRollover(now: justPastMidnight)
        #expect(app.dataVersion > before) // journal home refetches its day list

        // Re-checking the same day is a no-op — the backstop notifications fire
        // far more often than the day changes and must not re-render the feed.
        let settled = app.dataVersion
        app.checkDayRollover(now: justPastMidnight)
        #expect(app.dataVersion == settled)

        let days = app.journalDays(today: "2026-06-12")
        #expect(days.first == "2026-06-12")
        #expect(days.contains("2026-06-11"))
    }

    /// The rollover check is armed off calendar arithmetic, not a fixed 24 h step,
    /// so it lands on the real local midnight across DST shifts.
    @MainActor
    @Test func rolloverIsArmedForTheNextLocalMidnight() throws {
        let cal = Calendar.current
        let noon = try #require(DateComponents(
            calendar: cal, year: 2026, month: 6, day: 11, hour: 12
        ).date)
        let fires = noon.addingTimeInterval(AppState.secondsUntilNextDay(from: noon))
        #expect(cal.startOfDay(for: fires) == fires)
        let day = cal.dateComponents([.year, .month, .day], from: fires)
        #expect(day.year == 2026 && day.month == 6 && day.day == 12)
    }
}
