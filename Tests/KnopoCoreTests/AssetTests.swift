import Testing
import Foundation
@testable import KnopoCore

@Suite struct AssetTests {

    private func makeGraph() throws -> GraphStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knopo-asset-test-\(UUID().uuidString)")
        return try GraphStore(root: root)
    }

    private func makeSource(named name: String, data: Data) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knopo-asset-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func importCreatesAssetsAndCopiesFile() throws {
        let store = try makeGraph()
        let source = try makeSource(named: "shot.png", data: Data([1, 2, 3]))
        expectFalse(FileManager.default.fileExists(atPath: store.assetsDir.path))

        let name = try store.importAsset(from: source)

        expectEqual(name, "shot.png")
        expectEqual(try Data(contentsOf: store.assetsDir.appendingPathComponent(name)), Data([1, 2, 3]))
    }

    @Test func collisionsUseNumericSuffixes() throws {
        let store = try makeGraph()
        let first = try makeSource(named: "shot.png", data: Data([1]))
        let second = try makeSource(named: "shot.png", data: Data([2]))
        let third = try makeSource(named: "shot.png", data: Data([3]))

        expectEqual(try store.importAsset(from: first), "shot.png")
        expectEqual(try store.importAsset(from: second), "shot-1.png")
        expectEqual(try store.importAsset(from: third), "shot-2.png")
    }

    @Test func identicalBytesReuseExistingAsset() throws {
        let store = try makeGraph()
        let first = try makeSource(named: "same.png", data: Data([4, 5]))
        let second = try makeSource(named: "same.png", data: Data([4, 5]))

        expectEqual(try store.importAsset(from: first), "same.png")
        expectEqual(try store.importAsset(from: second), "same.png")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: store.assetsDir.path).count, 1)
    }

    @Test func sourceAlreadyInAssetsIsReturnedUnchanged() throws {
        let store = try makeGraph()
        let name = try store.saveAsset(Data([6]), preferredName: "inside.png")
        let source = store.assetsDir.appendingPathComponent(name)

        expectEqual(try store.importAsset(from: source), "inside.png")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: store.assetsDir.path).count, 1)
    }

    @Test func saveAssetSanitizesAndRoundTripsBytes() throws {
        let store = try makeGraph()
        let data = Data([7, 8, 9])

        let name = try store.saveAsset(data, preferredName: "capture (one)[x].png")

        expectEqual(name, "capture_-one--x-.png")
        expectEqual(try Data(contentsOf: store.assetsDir.appendingPathComponent(name)), data)
    }

    @Test func sanitizesAssetNames() throws {
        let store = try makeGraph()
        expectEqual(try store.saveAsset(Data([1]), preferredName: "shot (v2).png"), "shot_-v2-.png")
        expectEqual(try store.saveAsset(Data([2]), preferredName: ".hidden.png"), "hidden.png")
        expectEqual(try store.saveAsset(Data([3]), preferredName: "a/b.png"), "b.png")
        expectEqual(try store.saveAsset(Data([4]), preferredName: ""), "image")
        // Spaces become underscores (CommonMark forbids spaces in a link
        // destination, and Logseq writes underscores too).
        expectEqual(try store.saveAsset(Data([5]), preferredName: "Dark blue theme ex. 1.jpg"),
                    "Dark_blue_theme_ex._1.jpg")
    }

    @Test func recognizesImageExtensionsCaseInsensitively() {
        for name in ["a.png", "a.JPG", "a.jpeg", "a.gif", "a.webp", "a.HEIC", "a.heif",
                     "a.tif", "a.tiff", "a.bmp", "a.svg", "a.avif", "a.jp2"] {
            expectTrue(GraphStore.isImageFile(URL(fileURLWithPath: name)), name)
        }
        for name in ["a.pdf", "a.txt", "a", "png"] {
            expectFalse(GraphStore.isImageFile(URL(fileURLWithPath: name)), name)
        }
    }

    @Test func emitsImageMarkdown() {
        // `../assets/` src — resolved relative to the page file, so the pages
        // stay portable to Logseq/GitHub/Obsidian (Knopo reads both forms).
        expectEqual(GraphStore.imageMarkdown(assetNamed: "shot.png"),
                    "![shot](../assets/shot.png)")
        expectEqual(GraphStore.imageMarkdown(assetNamed: "shot-1.png"),
                    "![shot-1](../assets/shot-1.png)")
        expectEqual(GraphStore.imageMarkdown(assetNamed: "pasted.png", alt: "image"),
                    "![image](../assets/pasted.png)")
    }

    @Test func emittedMarkdownParsesAsImageNode() {
        let markdown = GraphStore.imageMarkdown(assetNamed: "Dark_blue_theme_ex._1.jpg")
        let nodes = InlineParser.parse(markdown)
        expectEqual(nodes.count, 1)
        guard case .image(let alt, let src, nil) = nodes.first else {
            Issue.record("expected .image node, got \(nodes)")
            return
        }
        expectEqual(alt, "Dark_blue_theme_ex._1")
        expectEqual(src, "../assets/Dark_blue_theme_ex._1.jpg")
    }

    @Test func acceptsPDFsAsPreviewAssetsWithoutClassifyingThemAsImages() {
        for name in ["paper.pdf", "paper.PDF", "shot.JPG"] {
            expectTrue(GraphStore.isPreviewAssetFile(URL(fileURLWithPath: name)))
        }
        expectFalse(GraphStore.isImageFile(URL(fileURLWithPath: "paper.pdf")))
        expectFalse(GraphStore.isPreviewAssetFile(URL(fileURLWithPath: "paper.txt")))
    }

    @Test func pdfImportCopiesOriginalBytesAndKeepsSource() throws {
        let store = try makeGraph()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let bytes = Data("%PDF-1.7\noriginal document".utf8)
        let source = try makeSource(named: "My paper.PDF", data: bytes)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let name = try store.importAsset(from: source)
        expectEqual(name, "My_paper.PDF")
        expectEqual(try Data(contentsOf: source), bytes)
        expectEqual(try Data(contentsOf: store.assetsDir.appendingPathComponent(name)), bytes)
    }

    @Test func fileSizeLimitsIncludeBoundaryAndRejectOneByteOver() throws {
        let store = try makeGraph()
        defer { try? FileManager.default.removeItem(at: store.root) }
        for (name, limit) in [("shot.PNG", GraphStore.maxImageImportBytes),
                              ("paper.PDF", GraphStore.maxPDFImportBytes)] {
            let source = try makeSource(named: name, data: Data())
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            let handle = try FileHandle(forWritingTo: source)
            defer { try? handle.close() }
            // Sparse files exercise real metadata without allocating large buffers.
            try handle.truncate(atOffset: UInt64(limit))
            try store.validateAssetImport(from: URL(fileURLWithPath: source.path))
            try handle.truncate(atOffset: UInt64(limit + 1))
            do {
                _ = try store.importAsset(from: URL(fileURLWithPath: source.path))
                Issue.record("import accepted a file over its size limit")
            } catch let error as AssetImportError {
                expectEqual(error, .fileTooLarge(name: name, maximumBytes: limit))
            }
            expectFalse(FileManager.default.fileExists(atPath: store.assetsDir.path))
            expectTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test func rejectsOversizedBitmapBeforeCreatingAssets() throws {
        let store = try makeGraph()
        defer { try? FileManager.default.removeItem(at: store.root) }
        do {
            _ = try store.saveAsset(Data(count: GraphStore.maxImageImportBytes + 1),
                                    preferredName: "pasted.png")
            Issue.record("accepted oversized bitmap")
        } catch let error as AssetImportError {
            expectEqual(error, .fileTooLarge(name: "pasted.png",
                                           maximumBytes: GraphStore.maxImageImportBytes))
        }
        expectFalse(FileManager.default.fileExists(atPath: store.assetsDir.path))
    }

    @Test func rejectsDirectoriesAndMissingSourcesBeforeCreatingAssets() throws {
        let store = try makeGraph()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let directory = store.root.appendingPathComponent("folder.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            _ = try store.importAsset(from: directory)
            Issue.record("accepted a directory as a PDF")
        } catch let error as AssetImportError {
            expectEqual(error, .notRegularFile(name: "folder.pdf"))
        }
        #expect(throws: (any Error).self) {
            try store.importAsset(from: store.root.appendingPathComponent("missing.png"))
        }
        expectFalse(FileManager.default.fileExists(atPath: store.assetsDir.path))
    }

    @Test func symlinkImportCopiesTargetBytesAndKeepsSelectedName() throws {
        let store = try makeGraph()
        defer { try? FileManager.default.removeItem(at: store.root) }
        for name in ["linked.png", "linked.pdf"] {
            let bytes = Data("original \(name)".utf8)
            let target = try makeSource(named: "target.data", data: bytes)
            defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
            let link = target.deletingLastPathComponent().appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let imported = try store.importAsset(from: link)
            expectEqual(imported, name)
            let asset = store.assetsDir.appendingPathComponent(imported)
            expectEqual(try asset.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, false)
            try FileManager.default.removeItem(at: target)
            expectEqual(try Data(contentsOf: asset), bytes)
        }
    }

    @Test func pdfAt512MBImports() throws {
        let store = try makeGraph()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let source = try makeSource(named: "book.pdf", data: Data("%PDF-1.7\n".utf8))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 512_000_000)
        try handle.close()

        let name = try store.importAsset(from: source)
        let asset = store.assetsDir.appendingPathComponent(name)
        expectEqual(name, "book.pdf")
        expectEqual(try asset.resourceValues(forKeys: [.fileSizeKey]).fileSize, 512_000_000)
    }

    @Test func symlinkSizeCheckUsesTargetBytesAndSelectedFileType() throws {
        let store = try makeGraph()
        defer { try? FileManager.default.removeItem(at: store.root) }
        for (name, limit) in [("linked.png", GraphStore.maxImageImportBytes),
                              ("linked.pdf", GraphStore.maxPDFImportBytes)] {
            let target = try makeSource(named: "target.data", data: Data())
            defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
            let handle = try FileHandle(forWritingTo: target)
            try handle.truncate(atOffset: UInt64(limit + 1))
            try handle.close()
            let link = target.deletingLastPathComponent().appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            do {
                _ = try store.importAsset(from: link)
                Issue.record("accepted oversized symlink target")
            } catch let error as AssetImportError {
                expectEqual(error, .fileTooLarge(name: name, maximumBytes: limit))
            }
        }
        expectFalse(FileManager.default.fileExists(atPath: store.assetsDir.path))
    }

    @Test func existingOversizedAssetsAreReusedButDirectoriesAreRejected() throws {
        let store = try makeGraph()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try FileManager.default.createDirectory(at: store.assetsDir, withIntermediateDirectories: true)
        for (name, limit) in [("large.png", GraphStore.maxImageImportBytes),
                              ("large.pdf", GraphStore.maxPDFImportBytes)] {
            let asset = store.assetsDir.appendingPathComponent(name)
            try Data().write(to: asset)
            let handle = try FileHandle(forWritingTo: asset)
            try handle.truncate(atOffset: UInt64(limit + 1))
            try handle.close()
            expectEqual(try store.importAsset(from: asset), name)
        }
        let directory = store.assetsDir.appendingPathComponent("folder.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            _ = try store.importAsset(from: directory)
            Issue.record("accepted a directory already in assets")
        } catch let error as AssetImportError {
            expectEqual(error, .notRegularFile(name: "folder.pdf"))
        }
    }

    @Test func existingAssetSymlinksAreNotReusedOrOverwritten() throws {
        let store = try makeGraph()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let bytes = Data("document".utf8)
        let source = try makeSource(named: "paper.pdf", data: bytes)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.assetsDir, withIntermediateDirectories: true)
        let oldLink = store.assetsDir.appendingPathComponent("paper.pdf")
        let brokenLink = store.assetsDir.appendingPathComponent("paper-1.pdf")
        try FileManager.default.createSymbolicLink(at: oldLink, withDestinationURL: source)
        try FileManager.default.createSymbolicLink(
            at: brokenLink, withDestinationURL: source.appendingPathExtension("missing"))

        // Importing an old asset link must also bring its target into the graph.
        let name = try store.importAsset(from: oldLink)
        expectEqual(name, "paper-2.pdf")
        expectEqual(try store.importAsset(from: source), name)
        let asset = store.assetsDir.appendingPathComponent(name)
        expectEqual(try asset.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, false)
        expectEqual(try oldLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        try FileManager.default.removeItem(at: source)
        expectEqual(try Data(contentsOf: asset), bytes)
    }
}
