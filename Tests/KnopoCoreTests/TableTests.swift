import Testing
import Foundation
@testable import KnopoCore

/// GFM pipe tables (SPEC §5.2): one multi-line block, classified from the
/// header + delimiter signature, with cells carrying raw inline Markdown.
@Suite struct TableTests {

    private func table(_ content: String) -> (header: [String],
                                              alignments: [TableAlignment],
                                              rows: [[String]])? {
        guard case .table(let header, let alignments, let rows) = BlockKind.classify(content) else {
            return nil
        }
        return (header, alignments, rows)
    }

    @Test func classifiesHeaderDelimiterAndRows() throws {
        let parsed = try #require(table("""
            | Name | Qty |
            | --- | --- |
            | Apples | 3 |
            | Pears | 12 |
            """))
        expectEqual(parsed.header, ["Name", "Qty"])
        expectEqual(parsed.rows, [["Apples", "3"], ["Pears", "12"]])
    }

    @Test func readsAlignmentsFromTheDelimiterRow() throws {
        let parsed = try #require(table("""
            | a | b | c | d |
            |:---|:---:|---:|---|
            | 1 | 2 | 3 | 4 |
            """))
        expectEqual(parsed.alignments, [.left, .center, .right, .left])
    }

    /// The delimiter row is what makes a table a table — a pipe in prose, or
    /// pipe-shaped lines without it, must stay a paragraph.
    @Test func requiresADelimiterRow() {
        expectTrue(table("| a | b |\n| c | d |") == nil)
        expectTrue(table("| just one line |") == nil)
        expectTrue(table("costs | benefits\n--- | ---") == nil) // no leading pipe
        // A delimiter whose width disagrees with the header isn't one (GFM).
        expectTrue(table("| a | b |\n| --- |") == nil)
        // Dashes only: `| - . - |` is not a delimiter row.
        expectTrue(table("| a |\n| -.- |") == nil)
    }

    /// Ragged rows are padded (missing cells) and truncated (extra ones) to the
    /// header's width, so the grid stays rectangular.
    @Test func padsAndTruncatesRaggedRows() throws {
        let parsed = try #require(table("""
            | a | b | c |
            | --- | --- | --- |
            | 1 |
            | 1 | 2 | 3 | 4 |
            """))
        expectEqual(parsed.rows, [["1", "", ""], ["1", "2", "3"]])
    }

    @Test func headerOnlyTableHasNoRows() throws {
        let parsed = try #require(table("| a | b |\n| --- | --- |"))
        expectEqual(parsed.header, ["a", "b"])
        expectTrue(parsed.rows.isEmpty)
    }

    /// `\|` is a literal pipe in a cell (unescaped for display), and a `|`
    /// inside a code span doesn't split the row.
    @Test func splitsCellsHonoringEscapesAndCodeSpans() throws {
        let parsed = try #require(table("""
            | syntax | meaning |
            | --- | --- |
            | `a \\| b` | alternation |
            | a \\| b | a pipe |
            """))
        expectEqual(parsed.rows[0], ["`a | b`", "alternation"])
        expectEqual(parsed.rows[1], ["a | b", "a pipe"])
    }

    /// Other escapes belong to the inline parser and must survive the split
    /// intact — unescaping them here would render `\*not bold\*` as emphasis.
    @Test func leavesOtherEscapesForTheInlineParser() throws {
        let parsed = try #require(table("| a |\n| --- |\n| \\*keep\\* |"))
        expectEqual(parsed.rows[0], ["\\*keep\\*"])
    }

    @Test func cellsKeepInlineMarkdown() throws {
        let parsed = try #require(table("""
            | page | tag |
            | --- | --- |
            | [[Marina]] | #boat **bold** |
            """))
        expectEqual(parsed.rows[0], ["[[Marina]]", "#boat **bold**"])
    }

    /// Enter inside a table adds a row rather than splitting the block; only on
    /// a trailing blank line (Enter pressed twice) does it split.
    @Test func caretInsideTableTracksTheTableLines() {
        let content = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        expectTrue(BlockKind.caretInsideTable(content, utf16Caret: 0))
        expectTrue(BlockKind.caretInsideTable(content, utf16Caret: 8))   // end of header
        expectTrue(BlockKind.caretInsideTable(content, utf16Caret: (content as NSString).length))
        // A trailing blank line is past the table: Enter there splits the block.
        let trailing = content + "\n"
        expectTrue(!BlockKind.caretInsideTable(trailing, utf16Caret: (trailing as NSString).length))
        // Not a table at all.
        expectTrue(!BlockKind.caretInsideTable("plain text", utf16Caret: 0))
    }

    /// Cells feed the ordinary inline pipeline, so refs and tags inside them
    /// index like any other content (nothing table-aware in `RefExtractor`).
    @Test func refsAndTagsInsideCellsAreExtracted() {
        let refs = RefExtractor.extract(from: """
            | page | tag |
            | --- | --- |
            | [[Marina]] | #boat |
            """)
        expectTrue(refs.pageRefs.contains("Marina"))
        expectTrue(refs.tags.contains("boat"))
    }

    /// `table-width::` is edit-only (SPEC §5.2): it stays out of the *rendered*
    /// body, but unlike a hidden property it is typed and edited as text — so it
    /// must appear in the focused editor's source and survive editing there.
    @Test func tableWidthPropertyIsEditableText() {
        expectTrue(Block.editOnlyPropertyKeys.contains("table-width"))
        expectTrue(!Block.hiddenPropertyKeys.contains("table-width"))

        var block = Block(content: "| a |\n| --- |\n| 1 |")
        block.properties = [BlockProperty(key: "table-width", value: "min")]
        expectTrue(block.editableSource.hasSuffix("table-width:: min"))

        // Edited back out of the source, it's still a property (not stray content).
        block.setEditableSource(block.editableSource)
        expectEqual(block.properties.first?.key, "table-width")
        expectEqual(block.content, "| a |\n| --- |\n| 1 |")
        guard case .table = BlockKind.classify(block.content) else {
            Issue.record("the property line must not end up in the table's content")
            return
        }
    }

    /// A table is plain multi-line block content — no new file syntax — so the
    /// byte-stable round trip (SPEC §4.2) covers it for free.
    @Test func tableBlockRoundTripsByteStable() {
        let source = """
            - | Name | Qty |
              | --- | ---: |
              | Apples | 3 |
            - after
            """
        let parsed = PageParser.parse(source)
        expectEqual(parsed.blocks.count, 2)
        guard case .table = BlockKind.classify(parsed.blocks[0].content) else {
            Issue.record("first block should classify as a table")
            return
        }
        expectEqual(
            PageSerializer.serialize(preamble: parsed.preamble, blocks: parsed.blocks),
            source
        )
    }
}
