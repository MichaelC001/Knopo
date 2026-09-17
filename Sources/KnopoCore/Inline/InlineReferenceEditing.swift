import Foundation

/// Shared bracket-reference completion for autocomplete and paste.
public enum InlineReferenceEditing {
    public struct Trigger: Equatable, Sendable {
        public var location: Int
        public var query: String

        public init(location: Int, query: String) {
            self.location = location
            self.query = query
        }
    }

    public struct Completion: Equatable, Sendable {
        public var replacementRange: NSRange
        public var absorbedClose: Bool

        public init(replacementRange: NSRange, absorbedClose: Bool) {
            self.replacementRange = replacementRange
            self.absorbedClose = absorbedClose
        }
    }

    public struct Paste: Equatable, Sendable {
        public var insertion: String
        public var replacementRange: NSRange
        public var caretLocation: Int
        public var blockID: UUID?

        public init(
            insertion: String, replacementRange: NSRange,
            caretLocation: Int, blockID: UUID?
        ) {
            self.insertion = insertion
            self.replacementRange = replacementRange
            self.caretLocation = caretLocation
            self.blockID = blockID
        }
    }

    /// Finds an unfinished `[[` / `((` trigger immediately left of the caret.
    public static func trigger(
        open: String, close: String, in text: NSString, caret: Int
    ) -> Trigger? {
        guard caret > 0, caret <= text.length else { return nil }
        let windowStart = max(0, caret - 160)
        let searchRange = NSRange(location: windowStart, length: caret - windowStart)
        let openRange = text.range(of: open, options: [.backwards, .literal], range: searchRange)
        guard openRange.location != NSNotFound else { return nil }
        if openRange.location > 0, text.character(at: openRange.location - 1) == 0x5C {
            return nil
        }
        let queryStart = openRange.location + (open as NSString).length
        guard caret >= queryStart else { return nil }
        let query = text.substring(with: NSRange(location: queryStart, length: caret - queryStart))
        guard !query.contains(close), !query.contains("\n"), query.count <= 80 else { return nil }
        return Trigger(location: openRange.location, query: query)
    }

    /// Replaces a trigger through the selection. A matching close after it is
    /// included so completing inside `[[]]` or `(())` does not double brackets.
    public static func completion(
        insertion: String, close: String, in text: NSString,
        triggerLocation: Int, selection: NSRange
    ) -> Completion? {
        guard triggerLocation >= 0, triggerLocation <= selection.location,
              selection.location >= 0, selection.length >= 0,
              selection.location <= text.length,
              selection.length <= text.length - selection.location else { return nil }
        let end = NSMaxRange(selection)
        var range = NSRange(location: triggerLocation, length: end - triggerLocation)
        let closeLength = (close as NSString).length
        var absorbedClose = false
        if !close.isEmpty, insertion.hasSuffix(close), end + closeLength <= text.length,
           text.substring(with: NSRange(location: end, length: closeLength)) == close {
            range.length += closeLength
            absorbedClose = true
        }
        return Completion(replacementRange: range, absorbedClose: absorbedClose)
    }

    /// Completes a pre-bracketed reference from a full reference on the clipboard.
    /// Returns nil in fenced code, where all brackets are literal.
    public static func pastedReference(
        _ pastedText: String, in source: String, replacing selection: NSRange
    ) -> Paste? {
        let pasted = pastedText as NSString
        let syntax: (open: String, close: String, target: EmbedTarget, blockID: UUID?)
        if pasted.length > 4,
           pasted.substring(to: 2) == "((",
           pasted.substring(from: pasted.length - 2) == "))" {
            let value = pasted.substring(with: NSRange(location: 2, length: pasted.length - 4))
            guard let id = UUID(uuidString: value) else { return nil }
            syntax = ("((", "))", .block(id), id)
        } else if pasted.length > 4,
                  pasted.substring(to: 2) == "[[",
                  pasted.substring(from: pasted.length - 2) == "]]" {
            let value = pasted.substring(with: NSRange(location: 2, length: pasted.length - 4))
            guard !value.isEmpty, !value.contains("["), !value.contains("]") else { return nil }
            syntax = ("[[", "]]", .page(value), nil)
        } else {
            return nil
        }

        guard selection.location >= 0, selection.length >= 0,
              !BlockKind.caretInsideFence(source, utf16Caret: selection.location) else {
            return nil
        }
        let text = source as NSString
        guard selection.location <= text.length,
              selection.length <= text.length - selection.location,
              let trigger = trigger(
                  open: syntax.open, close: syntax.close,
                  in: text, caret: selection.location
              ),
              let completion = completion(
                  insertion: pastedText, close: syntax.close, in: text,
                  triggerLocation: trigger.location, selection: selection
              ),
              completion.absorbedClose else { return nil }
        let completed = text.replacingCharacters(
            in: completion.replacementRange, with: pastedText
        )
        let belongsToEmbed = InlineParser.parseSpans(completed).contains { span in
            span.node == .embed(syntax.target)
                && NSLocationInRange(completion.replacementRange.location, span.range)
        }
        guard belongsToEmbed else { return nil }
        return Paste(
            insertion: pastedText,
            replacementRange: completion.replacementRange,
            caretLocation: completion.replacementRange.location + pasted.length,
            blockID: syntax.blockID
        )
    }
}
