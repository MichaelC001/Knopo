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
}
