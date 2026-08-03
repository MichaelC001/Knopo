import Testing
import Foundation
@testable import KnopoCore

/// Indexing internals that are easy to get subtly wrong: the per-block ref cache
/// (which must never serve refs for text a block no longer has) and the WAL
/// fallback (which must yield a working index on a filesystem that refuses WAL).
@Suite struct CacheDBIndexTests {

    private func page(_ name: String, blocks: [Block]) -> PageDocument {
        PageDocument(name: name, blocks: blocks, isJournal: false, fileExists: true)
    }

    /// The ref cache is keyed by block id, so a block that keeps its id while its
    /// text changes must be re-parsed — otherwise its old refs, tags and
    /// properties would outlive the edit in the index.
    @Test func editingABlockInPlaceReindexesItsRefsAndTags() throws {
        let cache = try CacheDB() // in-memory
        let id = UUID()
        try cache.indexPage(page("Notes", blocks: [
            Block(id: id, content: "links to [[Alpha]] and #one"),
        ]), stamp: nil)
        expectEqual(try cache.backlinks(of: PageName.key("Alpha")).count, 1)

        // Same block id, different text.
        try cache.indexPage(page("Notes", blocks: [
            Block(id: id, content: "links to [[Beta]] and #two"),
        ]), stamp: nil)

        expectTrue(try cache.backlinks(of: PageName.key("Alpha")).isEmpty)
        expectEqual(try cache.backlinks(of: PageName.key("Beta")).count, 1)
        expectTrue(try cache.blocks(taggedWith: "one").isEmpty)
        expectEqual(try cache.blocks(taggedWith: "two").count, 1)
    }

    /// Repeatedly reindexing an edited page must not evict the rest of the page
    /// from the ref cache — the failure mode of a content-keyed cache, where each
    /// keystroke added an entry and pushed the stable blocks out. Correctness is
    /// what is observable here: every block's refs stay right across many saves.
    @Test func manyEditsToOneBlockKeepTheRestOfThePageIndexed() throws {
        let cache = try CacheDB()
        let ids = (0..<50).map { _ in UUID() }
        var blocks = ids.enumerated().map { index, id in
            Block(id: id, content: "block \(index) refs [[Target\(index)]]")
        }
        for keystroke in 0..<200 {
            blocks[0] = Block(id: ids[0], content: "typing \(keystroke) refs [[Target0]]")
            try cache.indexPage(page("Notes", blocks: blocks), stamp: nil)
        }
        for index in 0..<50 {
            expectEqual(try cache.backlinks(of: PageName.key("Target\(index)")).count, 1)
        }
    }

    /// A filesystem without shared memory (SMB, NFS) cannot do WAL, and GRDB
    /// throws rather than degrading. The fallback must still give a working index.
    @Test func indexWorksWithoutWAL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-nowal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.db")

        let fallback = try CacheDB(url: url, allowWAL: false)
        expectFalse(fallback.usesWAL)
        try fallback.indexPage(page("Notes", blocks: [Block(content: "sees [[Alpha]]")]),
                               stamp: nil)
        expectEqual(try fallback.backlinks(of: PageName.key("Alpha")).count, 1)
        expectEqual(try fallback.searchBlocks("Alpha", limit: 5).count, 1)
    }

    /// …and on a local filesystem the pool is what we get, since that is what
    /// keeps a UI read from waiting out a background reindex.
    @Test func localFilesystemOpensAsAWALPool() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-wal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try CacheDB(url: root.appendingPathComponent("cache.db"))
        expectTrue(cache.usesWAL)
    }
}
