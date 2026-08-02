import AppKit
import Foundation
import Testing
@testable import Knopo
import KnopoCore

/// Where a large page's editing time goes. Not an assertion — it prints a table,
/// and is skipped unless `KNOPO_BENCH` is set, so the ordinary suite stays quiet:
///
///     KNOPO_BENCH=1 ./scripts/test.sh -c release --filter EditCostBenchmark
///
/// Run it in *release*: half the index cost is Swift (`RefExtractor`), which a
/// debug build inflates several-fold. Worth re-running on any macOS version that
/// feels slower — the TextKit rows (render/measure) are framework-bound, and are
/// the numbers that move between OS releases.
@MainActor
@Suite struct EditCostBenchmark {

    @discardableResult
    private func time(_ label: String, _ body: () -> Void) -> Double {
        let start = Date()
        body()
        let ms = Date().timeIntervalSince(start) * 1000
        print(String(format: "  %-34@ %8.2f ms", label as NSString, ms))
        return ms
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNOPO_BENCH"] != nil))
    func costByPageSize() throws {
        for count in [200, 1_000, 3_000] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("knopo-bench-\(count)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try GraphStore(root: root)
            let name = "Bench"
            var doc = try store.createPage(named: name)
            doc.blocks = (0..<count).map {
                Block(content: "Block \($0) — some text with a [[Link]] and a #tag in it")
            }
            store.updatePage(doc)
            try store.savePage(named: name)

            print("\n=== \(count) blocks ===")
            let app = AppState(store: store)
            defer { app.shutdown() }

            // Per keystroke.
            time("keystroke: doc + edit + commit") {
                var edited = app.document(for: name)
                guard let path = edited.blocks.path(to: edited.blocks[0].id) else { return }
                edited.blocks.update(at: path) { $0.content += "x" }
                app.commit(edited)
            }
            // Once per pause in typing (the 300 ms save debounce), on the main thread.
            let serialize = time("serialize whole page") {
                _ = PageSerializer.serialize(preamble: doc.preamble, blocks: doc.blocks)
            }
            let save = time("savePage (serialize+write+index)") {
                try? store.savePage(named: name)
            }
            print(String(format: "  %-34@ %8.2f ms",
                         "  …of which: write + index" as NSString, save - serialize))
            let blocks = doc.blocks
            time("  …of which: RefExtractor") {
                for block in blocks { _ = RefExtractor.extract(from: block.content) }
            }
            // Once per full rebuild: opening the page, and every width change.
            time("render every block") {
                for block in blocks {
                    _ = BlockRenderer.render(content: block.content,
                                             context: BlockRenderer.Context())
                }
            }
            let rendered = blocks.map {
                BlockRenderer.render(content: $0.content, context: BlockRenderer.Context())
            }
            time("measure every row height") {
                for attributed in rendered {
                    _ = OutlineRowCell.height(for: attributed, contentWidth: 700)
                }
            }
        }
    }
}
