import AppKit
import KnopoCore

/// Measures shared marker slots and carries widened gutters into child rows.
enum OutlineMarkerLayout {
    private static var cachedFont: (key: String, font: NSFont)?
    private static var widthTypography: String?
    private static var labelWidths: [String: CGFloat] = [:]
    static var typographyKey: String { "\(BlockRenderer.baseFontSize)|\(BlockRenderer.contentWeight.rawValue)" }
    struct Geometry: Equatable {
        var gutterOrigin: CGFloat
        var gutterWidth: CGFloat
        var contentOrigin: CGFloat { gutterOrigin + gutterWidth }
    }

    static var font: NSFont {
        let key = typographyKey
        if let cachedFont, cachedFont.key == key { return cachedFont.font }
        let descriptor = BlockRenderer.baseFont().fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: 6,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: 0]]
        ])
        let font = NSFont(descriptor: descriptor, size: BlockRenderer.baseFontSize) ?? BlockRenderer.baseFont()
        cachedFont = (key, font)
        return font
    }

    static func width(_ label: String) -> CGFloat {
        ceil(advance(label))
    }

    private static func advance(_ label: String) -> CGFloat {
        let key = typographyKey
        if widthTypography != key {
            labelWidths.removeAll(keepingCapacity: true)
            widthTypography = key
        }
        if let width = labelWidths[label] { return width }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: font]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if labelWidths.count < 4096 { labelWidths[label] = width }
        return width
    }

    static func runWidths(_ markers: [UUID: OutlineNumbering.Marker]) -> [UUID: CGFloat] {
        let minimum = minimumSlot
        var widths: [UUID: CGFloat] = [:]
        for marker in markers.values {
            widths[marker.runID] = max(widths[marker.runID] ?? minimum, width(marker.label))
        }
        return widths
    }

    static var minimumSlot: CGFloat { width("88.") }
    /// The punctuation hangs to the right of the digit; centre ordinary dots on the digit.
    static var bulletCenterOffset: CGFloat { advance("1.") - advance("1") / 2 }
    static var gap: CGFloat { 8 * BlockRenderer.zoom }
    static var generatedGutter: CGFloat { minimumSlot + gap }
    static func gutterWidth(slot: CGFloat) -> CGFloat {
        (14 * BlockRenderer.zoom).rounded() + max(minimumSlot, slot) + gap
    }
    static func contentWidth(origin: CGFloat, rowWidth: CGFloat) -> CGFloat {
        max(40, rowWidth - origin - OutlineRowCell.trailingPad)
    }

    static func geometry(
        rows: [OutlineOps.VisibleRow], markers: [UUID: OutlineNumbering.Marker],
        widths: [UUID: CGFloat]
    ) -> [UUID: Geometry] {
        var result: [UUID: Geometry] = [:]
        var parentContent: [Int: CGFloat] = [:]
        for row in rows {
            let origin = row.depth == 0 ? 0 : (parentContent[row.depth - 1] ?? 0)
                + OutlineRowCell.indentPerDepth - OutlineRowCell.gutterWidth
            let slot = widths[row.id] ?? markers[row.id].flatMap { widths[$0.runID] } ?? 0
            let geometry = Geometry(gutterOrigin: origin, gutterWidth: gutterWidth(slot: slot))
            result[row.id] = geometry
            parentContent[row.depth] = geometry.contentOrigin
        }
        return result
    }
}
