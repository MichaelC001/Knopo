import AppKit
import Foundation
import Testing
@testable import Knopo
import KnopoCore

/// Saves are debounced, so something has to persist them when the app is on its
/// way out. Nothing did: `shutdown()` had no callers, and there was no
/// termination hook — quitting inside the debounce window dropped the edit.
@MainActor
@Suite struct PersistenceHooksTests {

    private func graph() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-hooks-\(UUID().uuidString)")
    }

    @Test func flushAllPersistsEveryOpenGraph() throws {
        let root = graph()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = GraphManager()
        let app = try manager.acquire(root)

        var doc = try app.store.createPage(named: "Notes")
        doc.blocks[0].content = "typed but not yet saved"
        app.commit(doc)   // debounced; nothing on disk yet

        manager.flushAll()

        let saved = try String(
            contentsOf: app.store.fileURL(forPageNamed: "Notes"), encoding: .utf8)
        #expect(saved.contains("typed but not yet saved"))
    }

    /// The wiring, not just the method: deactivating the app has to trigger it.
    @Test func deactivatingTheAppFlushes() async throws {
        let root = graph()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = GraphManager()
        let app = try manager.acquire(root)

        var doc = try app.store.createPage(named: "Notes")
        doc.blocks[0].content = "flushed on deactivate"
        app.commit(doc)

        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 200_000_000)

        let saved = try String(
            contentsOf: app.store.fileURL(forPageNamed: "Notes"), encoding: .utf8)
        #expect(saved.contains("flushed on deactivate"))
    }

    /// The debounce is pushed back by every keystroke, so on its own it could
    /// defer a save for as long as someone keeps typing. The ceiling is what
    /// bounds that, and it must not be pushed back.
    @Test func steadyEditingIsSavedByTheCeiling() async throws {
        let root = graph()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        // Debounce far longer than the run: only the ceiling can fire.
        let app = AppState(store: store, saveDebounce: 60, saveCeiling: 0.3)
        defer { app.shutdown() }

        var doc = try store.createPage(named: "Notes")
        let url = store.fileURL(forPageNamed: "Notes")
        // Keep committing, as typing does, for longer than the ceiling.
        for keystroke in 0..<12 {
            doc.blocks[0].content = "typing \(keystroke)"
            app.commit(doc)
            try await Task.sleep(nanoseconds: 60_000_000)
        }

        // Written at all, with a 60 s debounce that cannot have elapsed: only the
        // ceiling can have done it. Which keystroke landed depends on where the
        // ceiling fell, so that is deliberately not asserted.
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved.contains("typing"))
    }

    /// …and a page that goes quiet is written on the debounce, not held to the
    /// ceiling.
    @Test func aPauseInTypingSavesOnTheDebounce() async throws {
        let root = graph()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let app = AppState(store: store, saveDebounce: 0.1, saveCeiling: 30)
        defer { app.shutdown() }

        var doc = try store.createPage(named: "Notes")
        doc.blocks[0].content = "settled after a pause"
        app.commit(doc)
        try await Task.sleep(nanoseconds: 400_000_000)

        let saved = try String(
            contentsOf: store.fileURL(forPageNamed: "Notes"), encoding: .utf8)
        #expect(saved.contains("settled after a pause"))
    }
}
