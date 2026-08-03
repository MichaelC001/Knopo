import Testing
import Foundation
@testable import KnopoCore

/// The per-block ref cache, which must never serve refs for text a block no
/// longer has, and must not evict the rest of a page while one block is edited.
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
}
