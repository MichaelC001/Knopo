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

    // MARK: - Incremental reindexing

    private func property(_ cache: CacheDB, _ key: String, _ value: String) throws
        -> (hits: [BacklinkHit], total: Int) {
        try cache.runQuery(.property(key: key, value: value), limit: 50)
    }

    private func block(_ content: String, id: UUID = UUID(),
                       collapsed: Bool = false,
                       properties: [BlockProperty] = []) -> Block {
        Block(id: id, content: content, collapsed: collapsed, properties: properties)
    }

    /// Editing one block's text must rewrite that block only — the whole point of
    /// the incremental path, since the full rebuild writes every row for the page.
    @Test func aContentEditRewritesOnlyThatBlock() throws {
        let cache = try CacheDB()
        let ids = (0..<20).map { _ in UUID() }
        var blocks = ids.enumerated().map { index, id in
            block("block \(index) refs [[Target\(index)]] #tag\(index)", id: id)
        }
        try cache.indexPage(page("Notes", blocks: blocks), stamp: nil)
        let afterFirst = cache.indexStats
        expectEqual(afterFirst.full, 1)
        expectEqual(afterFirst.incremental, 0)

        blocks[7] = block("block 7 now refs [[Moved]] #moved", id: ids[7])
        try cache.indexPage(page("Notes", blocks: blocks), stamp: nil)

        let afterEdit = cache.indexStats
        expectEqual(afterEdit.incremental, 1)
        expectEqual(afterEdit.full, 1)
        expectEqual(afterEdit.blocksRewritten - afterFirst.blocksRewritten, 1)

        // …and the edited block's facets are right, old ones gone.
        expectTrue(try cache.backlinks(of: PageName.key("Target7")).isEmpty)
        expectEqual(try cache.backlinks(of: PageName.key("Moved")).count, 1)
        expectTrue(try cache.blocks(taggedWith: "tag7").isEmpty)
        expectEqual(try cache.blocks(taggedWith: "moved").count, 1)
        expectEqual(try cache.searchBlocks("Moved", limit: 5).count, 1)
        expectTrue(try cache.searchBlocks("Target7", limit: 5).isEmpty)
        // Neighbours untouched and still correct.
        expectEqual(try cache.backlinks(of: PageName.key("Target6")).count, 1)
        expectEqual(try cache.blocks(taggedWith: "tag8").count, 1)
    }

    /// Anything that moves blocks around rebuilds the page: positions and depths
    /// come from the walk, so a partial update could not keep them consistent.
    @Test func structuralChangesRebuildThePage() throws {
        let cache = try CacheDB()
        let first = UUID(), second = UUID()
        try cache.indexPage(page("Notes", blocks: [
            block("first refs [[A]]", id: first), block("second refs [[B]]", id: second),
        ]), stamp: nil)

        // Nesting the second block under the first is structural.
        try cache.indexPage(page("Notes", blocks: [
            Block(id: first, content: "first refs [[A]]",
                  children: [block("second refs [[B]]", id: second)]),
        ]), stamp: nil)

        expectEqual(cache.indexStats.full, 2)
        expectEqual(cache.indexStats.incremental, 0)
        // Both blocks still resolve after the rebuild, at their new nesting.
        expectEqual(try cache.backlinks(of: PageName.key("A")).count, 1)
        expectEqual(try cache.backlinks(of: PageName.key("B")).count, 1)
        expectEqual(try cache.searchBlocks("second", limit: 5).count, 1)
    }

    /// Fold state and block properties live in rows too, so a change to either
    /// has to count as a change to that block.
    @Test func foldStateAndPropertiesAreReindexed() throws {
        let cache = try CacheDB()
        let id = UUID()
        try cache.indexPage(page("Notes", blocks: [
            block("parent", id: id, properties: [BlockProperty(key: "status", value: "open")]),
        ]), stamp: nil)
        expectEqual(try property(cache, "status", "open").total, 1)

        try cache.indexPage(page("Notes", blocks: [
            block("parent", id: id, collapsed: true,
                  properties: [BlockProperty(key: "status", value: "done")]),
        ]), stamp: nil)

        expectEqual(cache.indexStats.incremental, 1)
        expectEqual(try property(cache, "status", "open").total, 0)
        expectEqual(try property(cache, "status", "done").total, 1)
    }

    /// A page falls out of the skeleton cache once enough other pages are
    /// indexed; it must then rebuild correctly rather than trust a stale plan.
    @Test func aPageEvictedFromTheSkeletonCacheRebuilds() throws {
        let cache = try CacheDB()
        let id = UUID()
        try cache.indexPage(page("Notes", blocks: [block("keeps [[A]]", id: id)]), stamp: nil)
        for index in 0..<12 {
            try cache.indexPage(page("Other\(index)", blocks: [block("filler")]), stamp: nil)
        }
        try cache.indexPage(page("Notes", blocks: [block("now [[B]]", id: id)]), stamp: nil)

        expectTrue(try cache.backlinks(of: PageName.key("A")).isEmpty)
        expectEqual(try cache.backlinks(of: PageName.key("B")).count, 1)
    }

    /// Editing a block's prose leaves its refs, tags and properties alone, and
    /// those rows carry several index b-trees each — so they are skipped. The
    /// risk is a digest that misses an input and leaves them stale, so: text
    /// changes and searches follow it, while the untouched refs still resolve.
    @Test func aProseEditKeepsFacetRowsAndStillUpdatesSearch() throws {
        let cache = try CacheDB()
        let id = UUID()
        try cache.indexPage(page("Notes", blocks: [
            block("draft one refs [[Steady]] #steady", id: id),
        ]), stamp: nil)

        try cache.indexPage(page("Notes", blocks: [
            block("draft two refs [[Steady]] #steady", id: id),
        ]), stamp: nil)

        expectEqual(cache.indexStats.incremental, 1)
        // Facets untouched but still exactly one of each — not dropped, not doubled.
        expectEqual(try cache.backlinks(of: PageName.key("Steady")).count, 1)
        expectEqual(try cache.blocks(taggedWith: "steady").count, 1)
        // …and the text really did change.
        expectEqual(try cache.searchBlocks("two", limit: 5).count, 1)
        expectTrue(try cache.searchBlocks("one", limit: 5).isEmpty)
    }
}
