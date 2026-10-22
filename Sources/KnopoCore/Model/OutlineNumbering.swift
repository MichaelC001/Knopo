import Foundation

/// Presentation labels derived from the source tree, before folding or filtering.
public enum OutlineNumbering {
    /// Shared until structure or the effective numbered state changes.
    public final class Snapshot: Sendable {
        public let markers: [UUID: Marker]
        public init(blocks: [Block]) {
            markers = OutlineNumbering.markers(in: blocks)
        }
    }

    public enum Style: Int, Sendable {
        case decimal, alphabetic, roman
    }

    public struct Marker: Equatable, Sendable {
        public var ordinal: Int
        public var style: Style
        public var label: String
        /// The first item identifies a consecutive sibling run.
        public var runID: UUID
    }

    public static func markers(in blocks: [Block]) -> [UUID: Marker] {
        var result: [UUID: Marker] = [:]
        func walk(_ siblings: [Block], ancestors: Int) {
            var ordinal = 0
            var runID: UUID?
            for block in siblings {
                let numbered = block.isNumbered
                if numbered {
                    ordinal += 1
                    if runID == nil { runID = block.id }
                    let style = Style(rawValue: ancestors % 3)!
                    result[block.id] = Marker(
                        ordinal: ordinal, style: style,
                        label: label(ordinal, style: style) + ".", runID: runID!)
                } else {
                    ordinal = 0
                    runID = nil
                }
                walk(block.children, ancestors: numbered ? ancestors + 1 : 0)
            }
        }
        walk(blocks, ancestors: 0)
        return result
    }

    static func label(_ ordinal: Int, style: Style) -> String {
        guard ordinal > 0 else { return String(ordinal) }
        switch style {
        case .decimal: return String(ordinal)
        case .alphabetic:
            var n = ordinal
            var text = ""
            while n > 0 {
                n -= 1
                text = String(UnicodeScalar(97 + n % 26)!) + text
                n /= 26
            }
            return text
        case .roman:
            guard ordinal <= 3999 else { return String(ordinal) }
            var n = ordinal
            var text = ""
            for (value, symbol) in [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
                                    (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
                                    (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")] {
                while n >= value { text += symbol; n -= value }
            }
            return text
        }
    }
}
