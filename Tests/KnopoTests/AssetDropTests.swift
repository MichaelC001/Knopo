import AppKit
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct AssetDropTests {
    private func rig(blocks: [Block] = [Block(content: "Before"), Block(content: "After")]) throws
        -> (AppState, OutlineEditorController) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-asset-drop-\(UUID().uuidString)")
        let store = try GraphStore(root: root)
        var doc = store.page(named: "Files")
        doc.blocks = blocks
        store.updatePage(doc)
        let app = AppState(store: store)
        let controller = OutlineEditorController(app: app, nav: Navigator(app: app))
        controller.present(pageName: "Files", zoom: nil)
        controller.presentAssetImportAlert = { alert in
            Issue.record("Unexpected import alert: \(alert.informativeText)")
        }
        return (app, controller)
    }

    private func cleanUp(_ app: AppState) {
        app.shutdown()
        try? FileManager.default.removeItem(at: app.store.root)
    }

    private func source(_ store: GraphStore, named name: String, size: Int? = nil) throws -> URL {
        let directory = store.root.appendingPathComponent("sources/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        if let size {
            try Data().write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(size))
        } else if url.pathExtension.lowercased() == "pdf" {
            var box = CGRect(x: 0, y: 0, width: 100, height: 150)
            let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            context.endPDFPage()
            context.closePDF()
        } else {
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
        return url
    }

    @Test func pasteboardAcceptsPDFsAndImagesInOrder() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let urls = ["/tmp/a.PDF", "/tmp/b.png", "/tmp/notes.txt"].map(URL.init(fileURLWithPath:))
        #expect(pasteboard.writeObjects(urls as [NSURL]))
        #expect(OutlineEditorController.assetFileURLs(from: pasteboard) == Array(urls.prefix(2)))
        pasteboard.clearContents()
        pasteboard.writeObjects([urls[2] as NSURL])
        #expect(OutlineEditorController.assetFileURLs(from: pasteboard) == nil)
    }

    @Test func mixedDropCopiesFilesInOrderAndUndoesAsOneEdit() throws {
        let (app, controller) = try rig()
        defer { cleanUp(app) }
        let image = try source(app.store, named: "photo.png")
        let pdf = try source(app.store, named: "My paper.PDF")
        let before = app.document(for: "Files").blocks

        #expect(controller.importDroppedAssets([image, pdf], row: 1, operation: .above))
        let blocks = app.document(for: "Files").blocks
        #expect(blocks.map(\.content) == ["Before", "![photo](../assets/photo.png)",
                                         "![My_paper](../assets/My_paper.PDF)", "After"])
        #expect(blocks.first?.id == before.first?.id && blocks.last?.id == before.last?.id)
        for (original, name) in [(image, "photo.png"), (pdf, "My_paper.PDF")] {
            #expect(try Data(contentsOf: original)
                    == Data(contentsOf: app.store.assetsDir.appendingPathComponent(name)))
        }
        app.undo()
        #expect(app.document(for: "Files").blocks.map(\.id) == before.map(\.id))
        #expect(FileManager.default.fileExists(atPath: app.store.assetsDir.appendingPathComponent("My_paper.PDF").path))
        app.redo()
        #expect(app.document(for: "Files").blocks.map(\.id) == blocks.map(\.id))
    }

    @Test func consecutiveFileDropsCompleteWithoutBreakingTheNextSession() throws {
        let (app, controller) = try rig()
        defer { cleanUp(app) }
        let table = controller.tableView
        var completions = 0
        let cancelSpringLoad = table.onDragExited
        table.onDragExited = {
            completions += 1
            cancelSpringLoad?()
        }
        let image = try source(app.store, named: "photo.png")
        let pdf = try source(app.store, named: "paper.pdf")
        for (index, file) in [image, pdf, image, pdf].enumerated() {
            let info = FileDragInfo(file: file, sequence: index + 1)
            defer { info.draggingPasteboard.releaseGlobally() }
            #expect(controller.tableView(table, validateDrop: info,
                                         proposedRow: 1, proposedDropOperation: .above) == .copy)
            #expect(controller.tableView(table, acceptDrop: info, row: 1, dropOperation: .above))
            // AppKit sends this after acceptance. Calling an unimplemented
            // superclass callback here used to abort drag-session cleanup.
            table.draggingEnded(info)
            #expect(completions == index + 1)
            #expect(app.document(for: "Files").blocks.count == index + 3)
        }
    }

    @Test func dropIntoCollapsedParentExpandsAndPreservesChildren() throws {
        var parent = Block(content: "Parent", children: [Block(content: "Existing")])
        parent.collapsed = true
        let (app, controller) = try rig(blocks: [parent])
        defer { cleanUp(app) }
        let pdf = try source(app.store, named: "paper.pdf")
        #expect(controller.importDroppedAssets([pdf], row: 0, operation: .on))
        let result = try #require(app.document(for: "Files").blocks.first)
        #expect(!result.collapsed)
        #expect(result.children.map(\.content) == ["![paper](../assets/paper.pdf)", "Existing"])
        app.undo()
        #expect(app.document(for: "Files").blocks.first?.collapsed == true)
        #expect(app.document(for: "Files").blocks.first?.children.map(\.content) == ["Existing"])
    }

    @Test func partialDropReportsEveryFailureAndKeepsValidFiles() throws {
        let (app, controller) = try rig()
        defer { cleanUp(app) }
        let image = try source(app.store, named: "huge.png", size: GraphStore.maxImageImportBytes + 1)
        let pdf = try source(app.store, named: "huge.pdf", size: GraphStore.maxPDFImportBytes + 1)
        let valid = try source(app.store, named: "small.pdf")
        let missing = app.store.root.appendingPathComponent("missing.png")
        var alerts: [NSAlert] = []
        controller.presentAssetImportAlert = { alerts.append($0) }

        #expect(controller.importDroppedAssets([image, valid, pdf, missing], row: 1, operation: .above))
        #expect(app.document(for: "Files").blocks.map(\.content)
                == ["Before", "![small](../assets/small.pdf)", "After"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: app.store.assetsDir.path) == ["small.pdf"])
        let alert = try #require(alerts.first)
        #expect(alerts.count == 1)
        for text in ["huge.png", "64 MB", "huge.pdf", "512 MB", "missing.png"] {
            #expect(alert.informativeText.contains(text))
        }
        #expect(alert.informativeText.components(separatedBy: "missing.png").count == 2)
    }

    @Test func fullyRejectedDropDoesNotEditOrCreateAssets() throws {
        let (app, controller) = try rig()
        defer { cleanUp(app) }
        let image = try source(app.store, named: "huge.png", size: GraphStore.maxImageImportBytes + 1)
        let before = app.document(for: "Files").blocks.map(\.id)
        var alerts = 0
        controller.presentAssetImportAlert = { _ in alerts += 1 }
        #expect(!controller.importDroppedAssets([image], row: 1, operation: .above))
        #expect(alerts == 1)
        #expect(app.document(for: "Files").blocks.map(\.id) == before)
        #expect(!FileManager.default.fileExists(atPath: app.store.assetsDir.path))
    }

    @Test(arguments: ["png", "pdf"])
    func rejectedAssetPasteKeepsSelectionAndDoesNotFallBackToFilename(_ ext: String) throws {
        let (app, controller) = try rig()
        defer { cleanUp(app) }
        let limit = ext == "pdf" ? GraphStore.maxPDFImportBytes : GraphStore.maxImageImportBytes
        let file = try source(app.store, named: "huge.\(ext)", size: limit + 1)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setString(file.lastPathComponent, forType: .string)
        let editor = BlockEditorTextView.create()
        editor.actions = controller
        editor.setContent("Keep me")
        editor.setSelectedRange(NSRange(location: 0, length: 7))
        var alerts = 0
        controller.presentAssetImportAlert = { _ in alerts += 1 }
        #expect(editor.pasteKnopoContent(from: pasteboard))
        #expect(editor.string == "Keep me")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 7))
        #expect(alerts == 1)
    }

    @Test(arguments: [false, true])
    func pdfPasteImportsAloneAndAlongsideImages(_ includeImage: Bool) throws {
        let (app, controller) = try rig()
        defer { cleanUp(app) }
        let pdf = try source(app.store, named: "paper.pdf")
        var files = [pdf]
        if includeImage { files.append(try source(app.store, named: "photo.png")) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects(files as [NSURL])
        pasteboard.setString(files.map(\.lastPathComponent).joined(separator: "\n"), forType: .string)
        let editor = BlockEditorTextView.create()
        editor.actions = controller
        editor.setContent("Before After")
        editor.setSelectedRange(NSRange(location: 7, length: 0))

        #expect(editor.pasteKnopoContent(from: pasteboard))
        let expected = files.map { GraphStore.imageMarkdown(assetNamed: $0.lastPathComponent) }
            .joined(separator: " ")
        #expect(editor.string == "Before \(expected)After")
        for file in files {
            #expect(try Data(contentsOf: app.store.assetsDir.appendingPathComponent(file.lastPathComponent))
                    == Data(contentsOf: file))
        }
    }
}

@MainActor
private final class FileDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingSequenceNumber: Int
    let draggingSource: Any? = nil
    let draggingDestinationWindow: NSWindow? = nil
    let draggingSourceOperationMask: NSDragOperation = .copy
    let draggingLocation = NSPoint.zero
    let draggedImageLocation = NSPoint.zero
    let draggedImage: NSImage? = nil
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(file: URL, sequence: Int) {
        draggingSequenceNumber = sequence
        super.init()
        draggingPasteboard.writeObjects([file as NSURL])
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
