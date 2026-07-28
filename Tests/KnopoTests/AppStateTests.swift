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
}
