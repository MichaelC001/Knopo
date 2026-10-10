import AppKit
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct BlockReferenceRenderingTests {
    @Test(arguments: 1...6)
    func headingsUseInlineFormattingAndTheHostLink(level: Int) throws {
        let id = UUID()
        let target = String(repeating: "#", count: level) + " **Heading** *note* ~~done~~\nSecond line"
        let rendered = BlockRenderer.render(content: "Before ((\(id))) after",
            context: .init(resolveBlockRef: { $0 == id ? target : nil }))
        #expect(rendered.string == "Before Heading note done after")
        let text = rendered.string as NSString
        let heading = text.range(of: "Heading")
        let font = try #require(rendered.attribute(.font, at: heading.location, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == BlockRenderer.baseFontSize)
        let bold = BlockRenderer.render(content: "**Heading**", context: .init())
        #expect(font == bold.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font != BlockRenderer.baseFont())
        let noteFont = try #require(rendered.attribute(.font, at: text.range(of: "note").location,
                                                       effectiveRange: nil) as? NSFont)
        #expect(noteFont.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(rendered.attribute(.strikethroughStyle, at: text.range(of: "done").location,
                                   effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        let reference = text.range(of: "Heading note done")
        for offset in reference.location..<NSMaxRange(reference) {
            #expect(rendered.attribute(.link, at: offset, effectiveRange: nil) as? URL == KnopoURL.block(id))
            #expect(rendered.attribute(BlockRenderer.sourceOffsetKey, at: offset, effectiveRange: nil) as? Int == 7)
            #expect(rendered.attribute(BlockRenderer.sourceVerbatimKey, at: offset, effectiveRange: nil) == nil)
        }
        #expect(BlockRenderer.plainPreview(target) == "Heading note done")
    }

    @Test func literalHashesRemainVisible() {
        for (source, expected) in [
            ("#tag", "#tag"),
            ("###word", "###word"),
            ("####### Seven hashes", "####### Seven hashes"),
            ("\\### Escaped", "### Escaped"),
            ("`### code`", "### code"),
            ("Words ### in the middle", "Words ### in the middle")
        ] {
            #expect(BlockRenderer.plainPreview(source) == expected)
        }
    }

    @Test func fullHeadingsKeepTheirSize() throws {
        let rendered = BlockRenderer.render(content: "### **Heading**", context: .init())
        #expect(rendered.string == "Heading")
        let font = try #require(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == BlockRenderer.headingFont(level: 3).pointSize)
        #expect(font.pointSize > BlockRenderer.baseFontSize)
    }

    @Test(arguments: [false, true])
    func innerLinksUseTheReferenceStyle(brackets: Bool) throws {
        let id = UUID()
        let target = "### [[Page]] #tag [docs](https://example.com) https://example.org"
        let rendered = BlockRenderer.render(content: "Before ((\(id))) after",
            context: .init(resolveBlockRef: { _ in target },
                           pageDisplayTitle: { _ in "Page title" }, pageRefBrackets: brackets))
        let page = brackets ? "[[Page title]]" : "Page title"
        let preview = "\(page) #tag docs https://example.org"
        try #require(rendered.string == "Before \(preview) after")
        let surroundingColor = rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let range = (rendered.string as NSString).range(of: preview)
        rendered.enumerateAttributes(in: range) { attributes, _, _ in
            #expect(attributes[.foregroundColor] as? NSColor == surroundingColor)
            #expect(attributes[.link] as? URL == KnopoURL.block(id))
            #expect(attributes[BlockRenderer.tagKey] == nil)
            #expect(attributes[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue
                | NSUnderlineStyle.patternDot.rawValue)
        }

        let direct = BlockRenderer.render(content: "[[Page]] #tag [docs](https://example.com)",
                                          context: .init(pageRefBrackets: false))
        #expect(direct.string == "Page #tag docs\u{2009}\u{2197}")
        #expect(direct.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .linkColor)
        #expect(direct.attribute(.link, at: 0, effectiveRange: nil) as? URL == KnopoURL.page("Page"))
        let tag = (direct.string as NSString).range(of: "#tag").location
        #expect(direct.attribute(BlockRenderer.tagKey, at: tag, effectiveRange: nil) as? Bool == true)
    }

    @Test func imagesWithoutAltTextShowTheirFilename() {
        let id = UUID()
        for (source, expected) in [
            ("../assets/diagram.png", "diagram.png"),
            ("../assets/my #1 diagram.png", "my #1 diagram.png"),
            ("https://example.com/assets/my%20diagram.png?download=1", "my diagram.png")
        ] {
            let rendered = BlockRenderer.render(content: "((\(id)))",
                context: .init(resolveBlockRef: { _ in "![](\(source))" }))
            #expect(rendered.string == expected)
            #expect(rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL == KnopoURL.block(id))
            #expect(rendered.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
        }
    }

    @Test func referencesDoNotExpandRecursivelyOrEmbedImages() {
        let id = UUID()
        let target = "### **Title** ((\(id))) ![diagram](../assets/diagram.png)"
        let rendered = BlockRenderer.render(content: "((\(id)))",
            context: .init(resolveBlockRef: { _ in target }))
        #expect(rendered.string == "Title ((\(id.uuidString.lowercased()))) diagram")
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) {
            value, _, _ in #expect(value == nil)
        }
    }
}
