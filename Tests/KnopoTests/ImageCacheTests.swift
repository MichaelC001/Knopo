import AppKit
import Testing
@testable import Knopo
import KnopoCore

/// Rendered images come from one shared cache (issue #3). Each render used to
/// load its own copy, and a PDF's copy held the whole document.
@MainActor
@Suite struct ImageCacheTests {
    private func assetsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-images-\(UUID().uuidString)/assets")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePNG(_ url: URL, width: Int, height: Int) throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// A PDF of `pages` pages, each `size` points.
    private func writePDF(_ url: URL, pages: Int, size: CGSize) throws {
        var box = CGRect(origin: .zero, size: size)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func renderedImages(_ markdown: String, assets: URL) -> [NSImage] {
        let rendered = BlockRenderer.render(
            content: markdown,
            context: BlockRenderer.Context(resolveBlockRef: { _ in nil }, assetsDir: assets))
        var images: [NSImage] = []
        rendered.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if let image = (value as? NSTextAttachment)?.image { images.append(image) }
        }
        return images
    }

    @Test func rendersShareOneImagePerFile() throws {
        let assets = try assetsDir()
        try writePNG(assets.appendingPathComponent("photo.png"), width: 40, height: 30)
        // Both relative forms name the same file.
        let first = renderedImages("![a](photo.png)", assets: assets)
        let second = renderedImages("![b](../assets/photo.png)", assets: assets)
        #expect(first.count == 1 && second.count == 1)
        #expect(first.first === second.first)
    }

    @Test func pdfShowsFirstPageAsBitmap() throws {
        let assets = try assetsDir()
        try writePDF(assets.appendingPathComponent("book.pdf"), pages: 3,
                     size: CGSize(width: 300, height: 400))
        let image = try #require(renderedImages("![book](../assets/book.pdf)", assets: assets).first)
        // Same natural size as before, so layout and resizing are unchanged.
        #expect(image.size == NSSize(width: 300, height: 400))
        // No PDF representation, so the document is not kept in memory.
        #expect(!image.representations.contains { $0 is NSPDFImageRep })
        let pixels = image.representations.map(\.pixelsWide).max() ?? 0
        #expect(pixels == 600)
    }

    @Test func largePDFPageIsCappedInPixels() throws {
        let assets = try assetsDir()
        try writePDF(assets.appendingPathComponent("poster.pdf"), pages: 1,
                     size: CGSize(width: 3000, height: 2000))
        let image = try #require(renderedImages("![p](poster.pdf)", assets: assets).first)
        #expect(image.size == NSSize(width: 3000, height: 2000))
        let pixels = image.representations.map(\.pixelsWide).max() ?? 0
        #expect(pixels == Int(ImageCache.maxPDFPixelSide))
    }

    @Test func editedFileReloads() throws {
        let assets = try assetsDir()
        let url = assets.appendingPathComponent("chart.png")
        try writePNG(url, width: 40, height: 30)
        let before = try #require(renderedImages("![c](chart.png)", assets: assets).first)
        try writePNG(url, width: 80, height: 20)
        let after = try #require(renderedImages("![c](chart.png)", assets: assets).first)
        #expect(before !== after)
        #expect(after.size == NSSize(width: 80, height: 20))
    }

    @Test func missingFileShowsLinkChip() throws {
        let assets = try assetsDir()
        let url = assets.appendingPathComponent("gone.png")
        try writePNG(url, width: 10, height: 10)
        #expect(renderedImages("![g](gone.png)", assets: assets).count == 1)
        try FileManager.default.removeItem(at: url)
        let rendered = BlockRenderer.render(
            content: "![g](gone.png)",
            context: BlockRenderer.Context(resolveBlockRef: { _ in nil }, assetsDir: assets))
        #expect(renderedImages("![g](gone.png)", assets: assets).isEmpty)
        #expect(rendered.string.contains("g"))
    }
}
