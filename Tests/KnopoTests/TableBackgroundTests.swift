import AppKit
import Testing
@testable import Knopo

@MainActor
@Suite struct TableBackgroundTests {
    @Test(arguments: [CGFloat(420), 800], [CGFloat(0.6), 1, 2.6])
    func colorFillContainsEveryGridCorner(rowWidth: CGFloat, zoom: CGFloat) throws {
        let oldZoom = BlockRenderer.zoom, oldDensity = BlockRenderer.density
        defer { BlockRenderer.zoom = oldZoom; BlockRenderer.density = oldDensity }
        BlockRenderer.zoom = zoom
        BlockRenderer.density = BlockRenderer.minDensity
        for mode in BlockRenderer.TableWidth.allCases {
            try checkColorFill(rowWidth: rowWidth, mode: mode)
        }
    }

    private func checkColorFill(rowWidth: CGFloat, mode: BlockRenderer.TableWidth) throws {
        let source = "| ID | Project |\n| ---: | --- |\n| 101 | Website Redesign |"
        let width = OutlineRowCell.contentWidth(forDepth: 0, rowWidth: rowWidth)
        let rendered = BlockRenderer.render(content: source, context: .init(
            journalDateFormat: .default, contentWidth: width, tableWidth: mode))
        let cell = OutlineRowCell(frame: NSRect(
            x: 0, y: 0, width: rowWidth,
            height: OutlineRowCell.height(for: rendered, contentWidth: width)))
        cell.configure(depth: 0, hasChildren: false, collapsed: false,
                       isQuote: false, isCode: false, isEmbed: false, isEmptyLeaf: false,
                       selected: false, lineHeight: BlockRenderer.lineHeight(forSource: source),
                       blockColor: .systemPurple, callbacks: OutlineRowCallbacks())
        cell.showRendered(rendered)
        cell.layoutSubtreeIfNeeded()

        func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            (view as? T) ?? view.subviews.compactMap { descendant(type, in: $0) }.first
        }
        let text = try #require(descendant(RenderedTextView.self, in: cell))
        let color = try #require(descendant(ColorBoxView.self, in: cell))
        let layout = try #require(text.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        var rows: [CGRect] = []
        layout.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            rows.append(fragment.layoutFragmentFrame)
            return true
        }
        let first = try #require(rows.first)
        let last = try #require(rows.last)
        let geometry = try #require(rendered.attribute(
            BlockRenderer.tableKey, at: 0, effectiveRange: nil) as? BlockRenderer.TableGeometry)
        let left = try #require(geometry.columnEdges.first) + text.textContainerOrigin.x
        let right = try #require(geometry.columnEdges.last) + text.textContainerOrigin.x + 1
        let top = first.minY + text.textContainerOrigin.y - BlockRenderer.tableRowPad
        let bottom = last.maxY + text.textContainerOrigin.y + BlockRenderer.tableRowPad + 1
        let fill = NSBezierPath(roundedRect: color.bounds, xRadius: 6, yRadius: 6)
        for x in [left, right] {
            for y in [top, bottom] {
                #expect(fill.contains(color.convert(NSPoint(x: x, y: y), from: text)))
            }
        }
        let fillInRow = cell.convert(color.bounds, from: color)
        #expect(fillInRow.minY >= 0)
        #expect(fillInRow.maxY <= cell.bounds.maxY)
        #expect(fillInRow.minX >= 0)
        #expect(fillInRow.maxX <= cell.bounds.maxX)

        // Reusing the cell for prose must restore the ordinary background inset.
        cell.showRendered(BlockRenderer.render(content: "Plain text", context: .init()))
        cell.layoutSubtreeIfNeeded()
        #expect(color.frame.minX == 0)
        #expect(color.frame.minY == OutlineRowCell.contentInsetV - 2)
        #expect(text.textContainerInset.height == OutlineRowCell.contentInsetV)
    }
}
