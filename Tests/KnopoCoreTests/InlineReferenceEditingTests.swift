import Foundation
import Testing
@testable import KnopoCore

@Suite struct InlineReferenceEditingTests {
    private let id = "de305d54-75b4-431b-adb2-eb6b9e546014"

    private func applying(_ paste: InlineReferenceEditing.Paste, to source: String) -> String {
        (source as NSString).replacingCharacters(
            in: paste.replacementRange, with: paste.insertion
        )
    }

    @Test func copiedBlockReferenceReplacesTheSkeletonAndItsClose() throws {
        let source = "before {{embed (())}} after"
        let caret = ("before {{embed ((" as NSString).length
        let paste = try #require(InlineReferenceEditing.pastedReference(
            "((\(id)))", in: source, replacing: NSRange(location: caret, length: 0)
        ))

        expectEqual(applying(paste, to: source), "before {{embed ((\(id)))}} after")
        expectEqual(paste.caretLocation, ("before {{embed ((\(id)))" as NSString).length)
        expectEqual(paste.blockID, UUID(uuidString: id))
    }

    @Test func copiedPageReferenceReplacesThePageSkeleton() throws {
        let source = "{{embed [[]]}}"
        let paste = try #require(InlineReferenceEditing.pastedReference(
            "[[Project X]]", in: source, replacing: NSRange(location: 10, length: 0)
        ))

        expectEqual(applying(paste, to: source), "{{embed [[Project X]]}}")
        expectEqual(paste.caretLocation, ("{{embed [[Project X]]" as NSString).length)
        expectNil(paste.blockID)
    }

    @Test func surroundingEmbedWhitespaceAndCaseDoNotMatter() throws {
        let source = "before {{  EmBeD\t         (())  }} after"
        let caret = ("before {{  EmBeD\t         ((" as NSString).length
        let paste = try #require(InlineReferenceEditing.pastedReference(
            "((\(id)))", in: source, replacing: NSRange(location: caret, length: 0)
        ))

        expectEqual(
            applying(paste, to: source),
            "before {{  EmBeD\t         ((\(id)))  }} after"
        )
    }

    @Test func fencedCodeKeepsTheCopiedReferenceLiteral() {
        let source = "```text\n{{embed (())}}\n```"
        let caret = ("```text\n{{embed ((" as NSString).length

        expectNil(InlineReferenceEditing.pastedReference(
            "((\(id)))", in: source, replacing: NSRange(location: caret, length: 0)
        ))
    }

    @Test func wrappedNonUUIDIsNotABlockReference() {
        let source = "{{embed (())}}"

        expectNil(InlineReferenceEditing.pastedReference(
            "((not-a-uuid))", in: source, replacing: NSRange(location: 10, length: 0)
        ))
    }

    @Test func unterminatedEmbedUsesOrdinaryPaste() {
        let source = "{{embed (())"

        expectNil(InlineReferenceEditing.pastedReference(
            "((\(id)))", in: source, replacing: NSRange(location: 10, length: 0)
        ))
    }

    @Test func missingPreSuppliedCloseUsesOrdinaryPaste() {
        let source = "{{embed (("

        expectNil(InlineReferenceEditing.pastedReference(
            "((\(id)))", in: source, replacing: NSRange(location: 10, length: 0)
        ))
    }

    @Test func copiedReferenceOutsideAnOpenTriggerUsesOrdinaryPaste() {
        expectNil(InlineReferenceEditing.pastedReference(
            "((\(id)))", in: "ordinary block", replacing: NSRange(location: 8, length: 0)
        ))
    }

    @Test func matchingBracketsOutsideAnEmbedUseOrdinaryPaste() {
        expectNil(InlineReferenceEditing.pastedReference(
            "[[Project X]]", in: "plain [[]] text", replacing: NSRange(location: 8, length: 0)
        ))
    }

    @Test func pastingOverASelectionReplacesTheOldTarget() throws {
        let old = "8f14e45f-ceea-467a-9b2a-4c4d1a1b2c3d"
        let source = "{{embed ((\(old)))}}"
        let selected = NSRange(
            location: ("{{embed ((" as NSString).length, length: (old as NSString).length
        )
        let paste = try #require(InlineReferenceEditing.pastedReference(
            "((\(id)))", in: source, replacing: selected
        ))

        expectEqual(applying(paste, to: source), "{{embed ((\(id)))}}")
        expectEqual(paste.blockID, UUID(uuidString: id))
    }

    // MARK: - Trigger detection

    @Test func triggerFindsTheUnclosedOpenerLeftOfTheCaret() throws {
        let text = "see [[Proj" as NSString
        let trigger = try #require(InlineReferenceEditing.trigger(
            open: "[[", close: "]]", in: text, caret: text.length
        ))

        expectEqual(trigger.location, 4)
        expectEqual(trigger.query, "Proj")
    }

    @Test func backslashEscapesTheOpener() {
        let text = "see \\[[Proj" as NSString

        expectNil(InlineReferenceEditing.trigger(
            open: "[[", close: "]]", in: text, caret: text.length
        ))
    }

    @Test func anAlreadyClosedReferenceIsNotATrigger() {
        let text = "see [[Proj]] and" as NSString

        expectNil(InlineReferenceEditing.trigger(
            open: "[[", close: "]]", in: text, caret: text.length
        ))
    }

    @Test func aTriggerDoesNotCrossALineBreak() {
        let text = "[[Proj\nmore" as NSString

        expectNil(InlineReferenceEditing.trigger(
            open: "[[", close: "]]", in: text, caret: text.length
        ))
    }

    @Test func anOverlongQueryStopsBeingATrigger() {
        let text = "[[" + String(repeating: "x", count: 81) as NSString

        expectNil(InlineReferenceEditing.trigger(
            open: "[[", close: "]]", in: text, caret: text.length
        ))
    }

    // MARK: - Completion ranges

    @Test func completionAbsorbsAPreSuppliedClose() throws {
        let text = "{{embed [[]]}}" as NSString
        let completion = try #require(InlineReferenceEditing.completion(
            insertion: "[[Project X]]", close: "]]", in: text,
            triggerLocation: 8, selection: NSRange(location: 10, length: 0)
        ))

        expectTrue(completion.absorbedClose)
        expectEqual(
            text.replacingCharacters(in: completion.replacementRange, with: "[[Project X]]"),
            "{{embed [[Project X]]}}"
        )
    }

    @Test func completionKeepsTheCloseWhenNoneFollowsTheCaret() throws {
        let text = "see [[Proj" as NSString
        let completion = try #require(InlineReferenceEditing.completion(
            insertion: "[[Project X]]", close: "]]", in: text,
            triggerLocation: 4, selection: NSRange(location: text.length, length: 0)
        ))

        expectFalse(completion.absorbedClose)
        expectEqual(
            text.replacingCharacters(in: completion.replacementRange, with: "[[Project X]]"),
            "see [[Project X]]"
        )
    }

    @Test func completionWithoutAClosingInsertionAbsorbsNothing() throws {
        let completion = try #require(InlineReferenceEditing.completion(
            insertion: "#tag", close: "]]", in: "{{embed [[]]}}" as NSString,
            triggerLocation: 8, selection: NSRange(location: 10, length: 0)
        ))

        expectFalse(completion.absorbedClose)
    }

    @Test func completionSpansTheWholeSelection() throws {
        let text = "{{embed [[Old]]}}" as NSString
        let completion = try #require(InlineReferenceEditing.completion(
            insertion: "[[New]]", close: "]]", in: text,
            triggerLocation: 8, selection: NSRange(location: 10, length: 3)
        ))

        expectTrue(completion.absorbedClose)
        expectEqual(
            text.replacingCharacters(in: completion.replacementRange, with: "[[New]]"),
            "{{embed [[New]]}}"
        )
    }

    @Test func aCaretBeforeItsTriggerHasNoCompletion() {
        expectNil(InlineReferenceEditing.completion(
            insertion: "[[Project X]]", close: "]]", in: "{{embed [[]]}}" as NSString,
            triggerLocation: 8, selection: NSRange(location: 2, length: 0)
        ))
    }
}
