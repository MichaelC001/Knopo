import AppKit
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct NumberedOutlineTests {
    private func numbered(_ text: String = "", children: [Block] = [], logseq: Bool = false) -> Block {
        Block(content: text, children: children, properties: [BlockProperty(
            key: logseq ? "logseq.order-list-type" : "knopo.list-type",
            value: logseq ? "number" : "ordered")])
    }

    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
    }

    private func withOutline(
        _ blocks: [Block], zoom: UUID? = nil, reopen: Bool = false,
        _ body: (AppState, OutlineEditorController, NSWindow) throws -> Void
    ) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-numbered-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GraphStore(root: dir)
        var page = try store.createPage(named: "Lists")
        page.blocks = blocks
        store.updatePage(page)
        try store.savePage(named: "Lists")
        let app = AppState(store: reopen ? try GraphStore(root: dir) : store)
        defer { app.shutdown() }
        let controller = OutlineEditorController(app: app, nav: Navigator(app: app))
        controller.initialLayoutWidth = 600
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        scroll.documentView = controller.tableView
        controller.tableView.frame.size = scroll.bounds.size
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { controller.endEditing(); window.contentView = nil }
        controller.present(pageName: "Lists", zoom: zoom)
        window.layoutIfNeeded()
        try body(app, controller, window)
    }

    private func editor(_ window: NSWindow) throws -> BlockEditorTextView {
        try #require(window.firstResponder as? BlockEditorTextView)
    }

    @Test func provisionalPropertySurvivesRefreshAndUndoWithoutBecomingSticky() throws {
        let original = numbered("body", logseq: true)
        try withOutline([original, Block(content: "other")]) { app, controller, window in
            controller.focusBlock(original.id, selection: nil)
            let editor = try editor(window)
            let typed = "body\nknopo.list-type:: none"
            editor.insertText(typed, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            #expect(!app.document(for: "Lists").blocks[0].isNumbered)
            let caret = editor.selectedRange()
            let host = editor.superview
            controller.present(pageName: "Lists", zoom: nil)
            #expect(editor.string == typed)
            #expect(editor.selectedRange() == caret)
            #expect(editor.superview === host)
            controller.editorIndent() // first root cannot indent
            controller.focusBlock(original.id, selection: caret)
            #expect(editor.string == typed)
            app.undo()
            #expect(editor.string == "body")
            #expect(app.document(for: "Lists").blocks[0].isNumbered)
            app.redo()
            #expect(editor.string == typed)
            #expect(!app.document(for: "Lists").blocks[0].isNumbered)
            editor.insertText("body", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            #expect(app.document(for: "Lists").blocks[0].numberingProperties == original.numberingProperties)
            app.flushPendingSaves()
            let reopened = PageParser.parse(try String(contentsOf: app.store.fileURL(forPageNamed: "Lists"), encoding: .utf8))
            #expect(reopened.blocks[0].numberingProperties == original.numberingProperties)
        }
    }

    @Test func nestedEmptyEnterAdoptsFollowingSiblingsAndUndoes() throws {
        let empty = numbered(logseq: true)
        let following = numbered("following", children: [numbered("descendant", logseq: true)])
        let parent = numbered("parent", children: [numbered("before"), empty, following])
        try withOutline([parent, numbered("last")]) { app, controller, window in
            controller.focusBlock(empty.id, selection: NSRange(location: 0, length: 0))
            controller.editorSplit(atUTF16Offset: 0)
            let result = app.document(for: "Lists").blocks
            #expect(result.map(\.id) == [parent.id, empty.id, result[2].id])
            #expect(result[0].children.count == 1)
            #expect(result[1].children.map(\.id) == [following.id])
            #expect(result[1].children[0].children.count == 1)
            #expect(result[1].numberingProperties == empty.numberingProperties)
            #expect(OutlineNumbering.markers(in: result)[empty.id]?.label == "2.")
            let focused = try editor(window)
            #expect(focused.selectedRange().location == 0)
            app.undo()
            #expect(app.document(for: "Lists").blocks[0].children.map(\.id) == parent.children.map(\.id))
            app.redo()
            #expect(app.document(for: "Lists").blocks[1].id == empty.id)
        }
    }

    @Test func emptyEnterInZoomClearsInsteadOfLeavingScope() throws {
        let child = numbered(logseq: true)
        let root = numbered("root", children: [child])
        try withOutline([root], zoom: root.id) { app, controller, _ in
            controller.focusBlock(child.id, selection: nil)
            controller.editorSplit(atUTF16Offset: 0)
            let after = app.document(for: "Lists").blocks[0]
            #expect(after.children.map(\.id) == [child.id])
            #expect(!after.children[0].isNumbered)
            app.undo()
            #expect(app.document(for: "Lists").blocks[0].children[0].numberingProperties == child.numberingProperties)
        }
    }

    @Test func backspaceClearsFirstAndForwardMergeKeepsReceiverFormat() throws {
        let first = numbered("first", logseq: true)
        let second = numbered("second")
        try withOutline([first, second]) { app, controller, _ in
            controller.focusBlock(second.id, selection: NSRange(location: 0, length: 0))
            controller.editorMergeWithPrevious()
            #expect(app.document(for: "Lists").blocks.count == 2)
            #expect(!app.document(for: "Lists").blocks[1].isNumbered)
            app.undo()
            controller.focusBlock(first.id, selection: NSRange(location: 5, length: 0))
            controller.editorMergeWithNext()
            #expect(app.document(for: "Lists").blocks.count == 1)
            #expect(app.document(for: "Lists").blocks[0].content == "firstsecond")
            #expect(app.document(for: "Lists").blocks[0].numberingProperties == first.numberingProperties)
        }
    }

    @Test func slashCommandIsOnePropertyTransactionAndUndoRestoresTrigger() throws {
        let block = Block(content: "/numbered-list")
        try withOutline([block]) { app, controller, window in
            controller.focusBlock(block.id, selection: NSRange(location: 14, length: 0))
            let editor = try editor(window)
            let completion = try #require(editor.autocomplete)
            completion.textDidChange(in: editor)
            let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            #expect(completion.handleKeyDown(enter))
            #expect(editor.string.isEmpty)
            #expect(app.document(for: "Lists").blocks[0].isNumbered)
            app.undo()
            #expect(editor.string == "/numbered-list")
            #expect(!app.document(for: "Lists").blocks[0].isNumbered)
            app.redo()
            #expect(editor.string.isEmpty)
            #expect(app.document(for: "Lists").blocks[0].isNumbered)
        }
    }

    @Test(arguments: [false, true])
    func typingShortcutRequiresDirectTypingAndUndoRestoresLiteral(keypad: Bool) throws {
        let block = Block()
        try withOutline([block]) { app, controller, window in
            controller.focusBlock(block.id, selection: nil)
            let editor = try editor(window)
            editor.insertText("1. ", replacementRange: NSRange(location: 0, length: 0))
            #expect(!app.document(for: "Lists").blocks[0].isNumbered)
            editor.insertText("", replacementRange: NSRange(location: 0, length: 3))
            for (character, code) in [("1", UInt16(keypad ? 83 : 18)), (".", UInt16(keypad ? 65 : 47))] {
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: keypad ? [.numericPad] : [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
                editor.keyDown(with: event)
            }
            let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            editor.keyDown(with: space)
            #expect(app.document(for: "Lists").blocks[0].isNumbered)
            #expect(editor.string.isEmpty)
            app.undo()
            #expect(editor.string == "1. ")
            #expect(!app.document(for: "Lists").blocks[0].isNumbered)
        }
    }

    @Test(arguments: [false, true])
    func formattingCommitsAVisibleNumberingProperty(backspace: Bool) throws {
        let block = Block(content: "body")
        try withOutline([block]) { app, controller, window in
            controller.focusBlock(block.id, selection: nil)
            let editor = try editor(window)
            let text = "body\nknopo.list-type:: ordered"
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            if backspace { controller.editorMergeWithPrevious() }
            else { controller.setNumbering(on: [block.id]) }
            #expect(editor.string == "body")
            #expect(!app.document(for: "Lists").blocks[0].isNumbered)
            editor.insertText("x", replacementRange: editor.selectedRange())
            #expect(editor.string == "xbody")
            #expect(!app.document(for: "Lists").blocks[0].isNumbered)
            app.undo()
            app.undo()
            #expect(editor.string == text)
            #expect(app.document(for: "Lists").blocks[0].isNumbered)
            app.redo()
            #expect(editor.string == "body")
            #expect(!app.document(for: "Lists").blocks[0].isNumbered)
        }
    }

    @Test func firstResultViewAfterAnUnsavedSplitUsesSourceNumbers() throws {
        let blocks = [numbered("one"), numbered("two #match"), Block(content: "ordinary #match"), numbered("four #match")]
        try withOutline(blocks, reopen: true) { app, controller, window in
            let hits = try app.store.cache.blocks(taggedWith: "match")
            let first = app.document(for: "Lists").blocks[0]
            controller.focusBlock(first.id, selection: NSRange(location: 0, length: 0))
            controller.editorSplit(atUTF16Offset: 0)
            let source = SourceNumbering(app: app, page: "Lists")
            #expect(hits.map { source.markers[$0.blockID]?.label } == ["3.", nil, "1."])
        }
    }

    @Test func existingLiteralPrefixDoesNotBecomeAShortcut() throws {
        let block = Block(content: "1.")
        try withOutline([block]) { app, controller, window in
            controller.focusBlock(block.id, selection: NSRange(location: 2, length: 0))
            let editor = try editor(window)
            let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            editor.keyDown(with: space)
            #expect(editor.string == "1. ")
            #expect(!app.document(for: "Lists").blocks[0].isNumbered)
        }
    }

    @Test func placeholderPasteAndSelectionCopyKeepOneUndoStepAndRunCounters() throws {
        let placeholder = numbered(logseq: true)
        try withOutline([placeholder]) { app, controller, window in
            controller.focusBlock(placeholder.id, selection: nil)
            controller.editorPasteBlocks("one\ntwo\nthree")
            #expect(app.document(for: "Lists").blocks.map(\.content) == ["one", "two", "three"])
            #expect(app.document(for: "Lists").blocks[0].id == placeholder.id)
            #expect(app.document(for: "Lists").blocks[0].numberingProperties == placeholder.numberingProperties)
            app.undo()
            #expect(app.document(for: "Lists").blocks.map(\.id) == [placeholder.id])
            let focused = try editor(window)
            #expect(focused.string.isEmpty)
            app.redo()
            controller.endEditing()
            #expect(controller.selectAllBlocks())
            #expect(controller.selectionMarkdown() == "1. one\n2. two\n3. three\n")
            controller.setNumbering(on: app.document(for: "Lists").blocks.map(\.id))
            #expect(controller.selectionMarkdown() == "- one\n- two\n- three\n")
        }
    }

    @Test func structuralRefreshRetainsTypedPropertiesAndFormattingStartsANewSnapshot() throws {
        let first = Block(content: "before")
        let target = numbered("body", logseq: true)
        try withOutline([first, target]) { app, controller, window in
            controller.focusBlock(target.id, selection: nil)
            let editor = try editor(window)
            let text = "body\nknopo.list-type:: none"
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            controller.editorIndent()
            #expect(editor.string == text)
            #expect(app.document(for: "Lists").blocks[0].children[0].id == target.id)
            editor.insertText("body", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            #expect(app.document(for: "Lists").blocks[0].children[0].numberingProperties == target.numberingProperties)
            controller.setNumbering(on: [target.id])
            #expect(!app.document(for: "Lists").blocks[0].children[0].isNumbered)
            editor.insertText("body edited", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            #expect(!app.document(for: "Lists").blocks[0].children[0].isNumbered)
            app.undo()
            #expect(editor.string == "body")
            app.undo()
            #expect(app.document(for: "Lists").blocks[0].children[0].numberingProperties == target.numberingProperties)
        }
    }

    @Test func undoElsewhereRebasesThePendingTypingDocument() throws {
        let current = numbered("current")
        let other = Block(content: "other")
        try withOutline([current, other]) { app, controller, window in
            controller.focusBlock(current.id, selection: NSRange(location: 7, length: 0))
            let editor = try editor(window)
            var doc = app.document(for: "Lists")
            doc.blocks[1].content = "TODO other"
            app.commit(doc, undoLabel: "Toggle Todo")
            app.undo()
            controller.present(pageName: "Lists", zoom: nil)
            editor.insertText(" edited", replacementRange: NSRange(location: 7, length: 0))
            app.undo()
            #expect(app.document(for: "Lists").blocks.map(\.content) == ["current", "other"])
        }
    }

    @Test func mergeAndDeleteRedoRestoreTheReceiverAndCaret() throws {
        let first = numbered("first")
        let second = Block(content: "second")
        try withOutline([first, second]) { app, controller, window in
            controller.focusBlock(second.id, selection: NSRange(location: 0, length: 0))
            controller.editorMergeWithPrevious()
            app.undo()
            app.redo()
            let focused = try editor(window)
            #expect(focused.string == "firstsecond")
            #expect(focused.selectedRange() == NSRange(location: 5, length: 0))
        }
        let empty = Block()
        try withOutline([first, empty]) { app, controller, window in
            controller.focusBlock(empty.id, selection: NSRange(location: 0, length: 0))
            controller.editorDeleteEmptyBlock()
            app.undo()
            app.redo()
            let focused = try editor(window)
            #expect(focused.string == "first")
            #expect(focused.selectedRange() == NSRange(location: 5, length: 0))
        }
    }

    @Test func generatedMarkersAlignFirstAndContinuationLines() throws {
        let blocks = [numbered("first\nsecond")] + (2...10).map { numbered("item \($0)") }
        try withOutline(blocks) { _, controller, _ in
            let rendered = try #require(controller.renderEmbed(.page("Lists")))
            let view = RenderedTextView.create()
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
            view.textStorage?.setAttributedString(rendered)
            let layout = try #require(view.textLayoutManager)
            let manager = try #require(layout.textContentManager)
            layout.ensureLayout(for: layout.documentRange)
            @MainActor func x(_ word: String) throws -> CGFloat {
                let range = (rendered.string as NSString).range(of: word)
                let start = try #require(manager.location(manager.documentRange.location, offsetBy: range.location))
                let end = try #require(manager.location(start, offsetBy: range.length))
                let textRange = try #require(NSTextRange(location: start, end: end))
                var frame: CGRect?
                layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
                    frame = rect
                    return false
                }
                return try #require(frame).minX
            }
            let firstX = try x("first")
            let secondX = try x("second")
            let tenthX = try x("item 10")
            #expect(abs(firstX - secondX) < 0.5)
            #expect(abs(firstX - tenthX) < 0.5)
        }
    }

    @Test func ninthToTenthItemRefreshesUnchangedRowsWithoutReplacingTheEditor() throws {
        let blocks = (0..<9).map { numbered("item \( $0)") }
        try withOutline(blocks) { app, controller, window in
            controller.focusBlock(blocks[4].id, selection: NSRange(location: 2, length: 0))
            let editor = try editor(window)
            let host = editor.superview
            let oldX = try #require(host).frame.minX
            var doc = app.document(for: "Lists")
            doc.blocks.insert(numbered("inserted"), at: 0)
            app.commit(doc, undoLabel: "New Block")
            controller.present(pageName: "Lists", zoom: nil)
            window.layoutIfNeeded()
            #expect(editor.superview === host)
            #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
            #expect(editor.superview?.frame.minX == oldX)
            let last = try #require(controller.tableView.view(atColumn: 0, row: 9, makeIfNecessary: true))
            #expect(descendants(last, BulletView.self).first?.label == "10.")
        }
    }

    @Test func numberedGeneratedHostGetsItsOwnLineAndQueryUsesSourceLabels() throws {
        let matches = [numbered("one"), numbered("two #match"), numbered("three"), numbered("four #match")]
        let host = numbered("{{query #match}}")
        try withOutline(matches + [host]) { app, controller, _ in
            app.flushPendingSaves()
            controller.present(pageName: "Lists", zoom: nil)
            let cell = try #require(controller.tableView.view(atColumn: 0, row: 4, makeIfNecessary: true))
            let rendered = try #require(descendants(cell, RenderedTextView.self).first)
            #expect(rendered.string.hasPrefix("\n"))
            #expect(rendered.string.contains("2."))
            #expect(rendered.string.contains("4."))
            let bullet = try #require(descendants(cell, BulletView.self).first)
            #expect(!bullet.isHidden)
            #expect(bullet.label == "5.")
        }
    }

    @Test func indentAnimationUsesTheNumberedContentPosition() throws {
        let first = numbered("parent")
        let second = numbered("child")
        try withOutline([first, second]) { _, controller, window in
            controller.tableView.blockEditAnimation = BlockEditAnimation(
                currentTime: { 0 }, reducesMotion: { false })
            controller.focusBlock(second.id, selection: NSRange(location: 2, length: 0))
            window.layoutIfNeeded()
            let editor = try editor(window)
            let oldX = try #require(editor.superview).frame.minX
            controller.editorIndent()
            window.layoutIfNeeded()
            let container = try #require(editor.superview)
            let animation = try #require(container.layer?.animation(
                forKey: BlockEditAnimation.animationKey) as? CABasicAnimation)
            let shift = try #require(animation.fromValue as? CGFloat)
            #expect(abs(shift - (oldX - container.frame.minX)) < 0.5)
            #expect(abs(abs(shift) - OutlineRowCell.indentPerDepth) < 0.5)
        }
    }

    @Test func geometryReservesTwoDigitsAndMovesDescendantsWithWideParents() {
        let children = (0..<30).map { _ in numbered("child") }
        let blocks = [numbered("parent", children: children)]
        let markers = OutlineNumbering.markers(in: blocks)
        let rows = OutlineOps.visibleRows(in: blocks)
        let geometry = OutlineMarkerLayout.geometry(rows: rows, markers: markers,
                                                     widths: OutlineMarkerLayout.runWidths(markers))
        let parent = geometry[blocks[0].id]!
        let child = geometry[children[0].id]!
        #expect(child.gutterOrigin == parent.contentOrigin + OutlineRowCell.indentPerDepth - OutlineRowCell.gutterWidth)
        let siblings = (0..<10).map { _ in numbered("row") }
        let labels = OutlineNumbering.markers(in: siblings)
        let layouts = OutlineMarkerLayout.geometry(rows: OutlineOps.visibleRows(in: siblings), markers: labels,
                                                    widths: OutlineMarkerLayout.runWidths(labels))
        #expect(layouts[siblings[8].id]?.contentOrigin == layouts[siblings[9].id]?.contentOrigin)
    }

    @Test func numberingUsesCurrentBlockIdsWhenAnotherPaneChangedTheTree() throws {
        let first = Block(content: "first"), target = Block(content: "target")
        try withOutline([first, target]) { app, controller, _ in
            var doc = app.document(for: "Lists")
            doc.blocks.insert(Block(content: "inserted"), at: 0)
            app.commit(doc, undoLabel: "New Block")
            controller.setNumbering(on: [target.id])
            let changed = app.document(for: "Lists").blocks
            #expect(changed.block(id: target.id)?.isNumbered == true)
            #expect(changed.block(id: first.id)?.isNumbered == false)
            doc = app.document(for: "Lists")
            doc.blocks.removeAll { $0.id == target.id }
            app.commit(doc, undoLabel: "Delete Block")
            controller.setNumbering(on: [target.id])
            app.undo()
            #expect(app.document(for: "Lists").blocks.block(id: target.id) != nil)
        }
    }

    @Test func changingAParentGutterRefitsItsChildTable() throws {
        let table = Block(content: "| A | B |\n| --- | --- |\n| one | two |")
        let parent = Block(content: "parent", children: [table])
        // Joining this Roman-numbered run needs more than the reserved two digits.
        let siblings = (0..<37).map { _ in numbered("sibling") }
        let root = numbered("root", children: [numbered("branch", children: [parent] + siblings)])
        try withOutline([root]) { _, controller, window in
            @MainActor func tableWidth() throws -> CGFloat {
                window.layoutIfNeeded()
                let cell = try #require(controller.tableView.view(atColumn: 0, row: 3, makeIfNecessary: true))
                let view = try #require(descendants(cell, RenderedTextView.self).first)
                let geometry = try #require(view.attributedString().attribute(
                    BlockRenderer.tableKey, at: 0, effectiveRange: nil) as? BlockRenderer.TableGeometry)
                return try #require(geometry.columnEdges.last)
            }
            let before = try tableWidth()
            controller.setNumbering(on: [parent.id])
            #expect(try tableWidth() < before)
        }
    }

    @Test func markerAndBodyUseTheSameBaselineForHeadingsAndFocusedSource() throws {
        let blocks = [numbered("body"), numbered("# Heading"), numbered("### Heading"), numbered("TODO task"),
                      numbered("```swift\nlet value = 1\n```"), numbered("| A | B |\n| --- | --- |\n| a | b |") ]
        try withOutline(blocks) { _, controller, window in
            @MainActor func baseline(_ text: NSTextView, in cell: NSView) throws -> CGFloat {
                let layout = try #require(text.textLayoutManager)
                layout.ensureLayout(for: layout.documentRange)
                let fragment = try #require(layout.textLayoutFragment(for: layout.documentRange.location))
                let line = try #require(fragment.textLineFragments.first)
                let y = text.textContainerOrigin.y + fragment.layoutFragmentFrame.minY
                    + line.typographicBounds.minY + line.glyphOrigin.y
                return cell.convert(NSPoint(x: 0, y: y), from: text).y
            }
            for (row, block) in blocks.enumerated() {
                let cell = try #require(controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true))
                cell.layoutSubtreeIfNeeded()
                let marker = try #require(descendants(cell, BulletView.self).first)
                let markerY = cell.convert(NSPoint(x: 0, y: marker.bounds.height - OutlineMarkerLayout.font.ascender),
                                          from: marker).y
                let rendered = try #require(descendants(cell, RenderedTextView.self).first)
                let bodyY = try baseline(rendered, in: cell)
                #expect(abs(markerY - bodyY) < 0.5)
                controller.focusBlock(block.id, selection: nil)
                window.layoutIfNeeded()
                cell.layoutSubtreeIfNeeded()
                let editor = try editor(window)
                let focusedY = try baseline(editor, in: cell)
                let focusedMarkerY = cell.convert(
                    NSPoint(x: 0, y: marker.bounds.height - OutlineMarkerLayout.font.ascender), from: marker).y
                #expect(abs(focusedMarkerY - focusedY) < 0.5)
            }
        }
    }

    @Test func resultMarkersResolveVolatileIdsAfterReopeningAGraph() throws {
        let blocks = [numbered("one"), numbered("two #match"), numbered("three"), numbered("four #match")]
        try withOutline(blocks) { app, _, _ in
            let reopened = try GraphStore(root: app.store.root)
            let otherApp = AppState(store: reopened)
            defer { otherApp.shutdown() }
            let hits = try reopened.cache.blocks(taggedWith: "match")
            #expect(!reopened.isLoaded("Lists"))
            let source = SourceNumbering(app: otherApp, page: "Lists")
            #expect(!reopened.isLoaded("Lists"))
            #expect(hits.count == 2)
            #expect(hits.compactMap { source.markers[$0.blockID]?.label } == ["2.", "4."])
            var doc = otherApp.document(for: "Lists")
            _ = SourceNumbering(app: otherApp, page: "Lists")
            doc.blocks.insert(numbered("inserted"), at: 0)
            otherApp.commit(doc)
            let moved = SourceNumbering(app: otherApp, page: "Lists")
            #expect(hits.compactMap { moved.markers[$0.blockID]?.label } == ["3.", "5."])
        }
    }

    @Test func sourceLabelsSurviveZoomEmbedsResultsAndEmptyPreviews() throws {
        let blocks = [numbered("first"), numbered("second #match"), numbered(), numbered("fourth #match")]
        try withOutline(blocks, zoom: blocks[1].id) { app, controller, _ in
            app.flushPendingSaves()
            let source = SourceNumbering(app: app, page: "Lists")
            #expect(source.markers[blocks[1].id]?.label == "2.")
            let embedded = try #require(controller.renderEmbed(.block(blocks[1].id)))
            #expect(embedded.string.contains("2."))
            let preview = try #require(controller.previewAttributedString(forPage: "Lists"))
            #expect(preview.string.contains("3."))
            let hits = try app.store.cache.blocks(taggedWith: "match")
            let rows = ResultRowLayout.layout(hits, ancestors: [:], markers: source.markers, widths: source.widths)
            #expect(rows.compactMap { $0.marker?.label } == ["2.", "4."])
        }
    }
    @Test func todoRedoRestoresThePostCommandCaret() throws {
        let block = numbered("body")
        try withOutline([block]) { app, controller, window in
            controller.focusBlock(block.id, selection: NSRange(location: 0, length: 0))
            let text = try editor(window)
            controller.editorToggleTodo()
            #expect(text.selectedRange().location == 5)
            app.undo()
            #expect(text.string == "body")
            #expect(text.selectedRange().location == 0)
            app.redo()
            #expect(text.string == "TODO body")
            #expect(text.selectedRange().location == 5)
        }
    }

    @Test func ordinaryTypingAndSavesReuseTheLiveNumberingSnapshot() throws {
        let blocks = [numbered("one"), numbered("two")]
        try withOutline(blocks) { app, controller, window in
            controller.focusBlock(blocks[0].id, selection: NSRange(location: 3, length: 0))
            let text = try editor(window)
            let snapshot = try app.store.numbering(onPageNamed: "Lists")
            let reads = app.store.cache.numberingReadCount
            for _ in 0..<5 {
                text.insertText("x", replacementRange: text.selectedRange())
                app.flushPendingSaves()
                controller.present(pageName: "Lists", zoom: nil)
                _ = SourceNumbering(app: app, page: "Lists")
                #expect(try app.store.numbering(onPageNamed: "Lists") === snapshot)
            }
            #expect(app.store.cache.numberingReadCount == reads)
        }
    }

    @Test(arguments: [CGFloat(0.8), 0.9, 1, 1.1, 1.2, 1.5], BlockRenderer.ContentWeight.allCases)
    func mixedSiblingsAlignTheirMarkersAndContent(zoom: CGFloat, weight: BlockRenderer.ContentWeight) throws {
        let previous = BlockRenderer.zoom
        let previousWeight = BlockRenderer.contentWeight
        BlockRenderer.zoom = zoom
        BlockRenderer.contentWeight = weight
        defer {
            BlockRenderer.zoom = previous
            BlockRenderer.contentWeight = previousWeight
        }
        let blocks = [Block(content: "bullet"), numbered("number"), Block(content: "after")]
        try withOutline(blocks) { app, controller, window in
            window.layoutIfNeeded()
            var contentX: [CGFloat] = []
            var markerCenters: [CGFloat] = []
            for i in blocks.indices {
                let cell = try #require(controller.tableView.view(atColumn: 0, row: i, makeIfNecessary: true))
                cell.layoutSubtreeIfNeeded()
                let text = try #require(descendants(cell, RenderedTextView.self).first)
                contentX.append(try #require(text.superview).frame.minX)
                let marker = try #require(descendants(cell, BulletView.self).first)
                #expect(marker.isAccessibilityElement())
                #expect(marker.accessibilityRole() == .button)
                if let label = marker.label {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(
                        string: label, attributes: [.font: OutlineMarkerLayout.font]))
                    let labelWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                    let digitEnd = CTLineGetOffsetForStringIndex(line, 1, nil)
                    markerCenters.append(marker.frame.maxX - labelWidth + digitEnd / 2)
                } else {
                    markerCenters.append(marker.frame.midX)
                }
            }
            #expect(contentX.max()! - contentX.min()! < 0.5)
            #expect(markerCenters.max()! - markerCenters.min()! < 0.01)
            let generated = try #require(controller.renderEmbed(.page("Lists")))
            let positions = try textPositions(["bullet", "number", "after"], in: generated)
            #expect(positions.max()! - positions.min()! < 0.5)
            let preview = try #require(controller.previewAttributedString(forPage: "Lists"))
            let previewPositions = try textPositions(["bullet", "number", "after"], in: preview)
            #expect(previewPositions.max()! - previewPositions.min()! < 0.5)
            let source = SourceNumbering(app: app, page: "Lists")
            #expect(source.widths[blocks[0].id] ?? OutlineMarkerLayout.minimumSlot == source.widths[blocks[1].id])
        }
    }

    @Test func indentingTheOnlyNumberedSiblingDoesNotMoveTheOrdinaryBlock() throws {
        let ordinary = Block(content: "Good stuff")
        let item = numbered("Weird", children: [numbered("Strange")])
        try withOutline([ordinary, item]) { app, controller, window in
            controller.focusBlock(item.id, selection: NSRange(location: 0, length: 0))
            @MainActor func ordinaryPosition() throws -> [CGFloat] {
                window.layoutIfNeeded()
                let cell = try #require(controller.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true))
                cell.layoutSubtreeIfNeeded()
                let text = try #require(descendants(cell, RenderedTextView.self).first)
                let bullet = try #require(descendants(cell, BulletView.self).first)
                return [text.convert(text.bounds, to: cell).minX, bullet.frame.midX]
            }
            let before = try ordinaryPosition()
            controller.editorIndent()
            #expect(app.document(for: "Lists").blocks[0].children.first?.id == item.id)
            #expect(try ordinaryPosition() == before)
            controller.editorOutdent()
            #expect(try ordinaryPosition() == before)
            app.undo()
            #expect(try ordinaryPosition() == before)
            app.redo()
            #expect(try ordinaryPosition() == before)
        }
    }

    @Test func wideNumberedRunsDoNotWidenUnrelatedRows() {
        let ordinary = Block(content: "ordinary")
        let separateRun = numbered("separate")
        let wideRun = (0..<1000).map { _ in numbered("wide") }
        let blocks = [separateRun, ordinary] + wideRun
        let markers = OutlineNumbering.markers(in: blocks)
        let geometry = OutlineMarkerLayout.geometry(rows: OutlineOps.visibleRows(in: blocks),
            markers: markers, widths: OutlineMarkerLayout.runWidths(markers))
        #expect(geometry[ordinary.id]?.gutterWidth == OutlineRowCell.gutterWidth)
        #expect(geometry[separateRun.id]?.gutterWidth == OutlineRowCell.gutterWidth)
        #expect(geometry[wideRun[0].id]!.gutterWidth > OutlineRowCell.gutterWidth)
    }

    private func textPositions(_ words: [String], in rendered: NSAttributedString) throws -> [CGFloat] {
        let view = RenderedTextView.create()
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 1000)
        view.textStorage?.setAttributedString(rendered)
        let layout = try #require(view.textLayoutManager)
        let manager = try #require(layout.textContentManager)
        layout.ensureLayout(for: layout.documentRange)
        return try words.map { word in
            let range = (rendered.string as NSString).range(of: word)
            #expect(range.location != NSNotFound)
            let start = try #require(manager.location(manager.documentRange.location, offsetBy: range.location))
            let end = try #require(manager.location(start, offsetBy: range.length))
            let textRange = try #require(NSTextRange(location: start, end: end))
            var x: CGFloat?
            layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
                x = rect.minX
                return false
            }
            return try #require(x)
        }
    }

    @Test func nestedNumberedEmbedsTranslateTabsAndContinuationsTogether() throws {
        try withOutline([numbered("{{embed [[Inner]]}}")]) { app, controller, _ in
            var inner = app.document(for: "Inner")
            inner.blocks = [numbered("first\ncontinued"), Block(content: "ordinary"),
                            numbered("last", children: [numbered("child")])]
            app.commit(inner)
            let rendered = try #require(controller.renderEmbed(.page("Lists")))
            let x = try textPositions(["first", "continued", "ordinary", "last", "child"], in: rendered)
            #expect(abs(x[0] - x[1]) < 0.5)
            #expect(abs(x[0] - x[2]) < 0.5)
            #expect(abs(x[0] - x[3]) < 0.5)
            #expect(x[4] > x[3])
        }
    }

    @Test func largeSelectionCopyRetainsOneNumberedRun() throws {
        let blocks = (0..<3000).map { numbered("item\($0)") }
        try withOutline(blocks) { _, controller, _ in
            controller.endEditing()
            #expect(controller.selectAllBlocks())
            let start = Date()
            let copied = try #require(controller.selectionMarkdown())
            print("Copied 3000 selected rows in \(Date().timeIntervalSince(start)) seconds")
            #expect(copied.hasPrefix("1. item0\n"))
            #expect(copied.hasSuffix("3000. item2999\n"))
            #expect(copied.split(separator: "\n").count == 3000)
        }
    }

}
