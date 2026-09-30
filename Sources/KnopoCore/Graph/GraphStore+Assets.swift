import Foundation

public enum AssetImportError: Error, Equatable {
    case fileTooLarge(name: String, maximumBytes: Int)
    case notRegularFile(name: String)
}

extension GraphStore {
    public static let maxImageImportBytes = 64_000_000
    public static let maxPDFImportBytes = 512_000_000

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg",
        "avif", "jp2",
    ]

    public static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isPreviewAssetFile(_ url: URL) -> Bool {
        isImageFile(url) || url.pathExtension.lowercased() == "pdf"
    }

    private static func validateAssetSize(_ size: Int, named name: String) throws {
        let url = URL(fileURLWithPath: name)
        let limit: Int
        if url.pathExtension.lowercased() == "pdf" {
            limit = maxPDFImportBytes
        } else if isImageFile(url) {
            limit = maxImageImportBytes
        } else {
            return
        }
        guard size <= limit else {
            throw AssetImportError.fileTooLarge(name: name, maximumBytes: limit)
        }
    }

    /// Check metadata before reading bytes or creating the assets directory.
    func validateAssetImport(from source: URL, named name: String? = nil) throws {
        let name = name ?? source.lastPathComponent
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw AssetImportError.notRegularFile(name: name)
        }
        // Reusing an existing asset does not copy any bytes.
        guard source.deletingLastPathComponent() != assetsDir.resolvingSymlinksInPath() else { return }
        try Self.validateAssetSize(values.fileSize ?? 0, named: name)
    }

    /// Markdown for an imported asset. The src is written `../assets/<name>` —
    /// relative to the page file, the way Logseq and CommonMark tools (GitHub,
    /// Obsidian) resolve it — so pages stay portable; Knopo's own renderer
    /// resolves both this and a bare filename (§5.1).
    public static func imageMarkdown(assetNamed name: String, alt: String? = nil) -> String {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        return "![\(alt ?? stem)](../assets/\(name))"
    }

    /// Copies a file into `assets/`, creating the directory on demand.
    @discardableResult
    public func importAsset(from source: URL) throws -> String {
        let requestedName = source.lastPathComponent
        // Copy the target bytes, keeping the name and type the user selected.
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        try validateAssetImport(from: source, named: requestedName)
        if source.deletingLastPathComponent() == assetsDir.resolvingSymlinksInPath() {
            return source.lastPathComponent
        }
        let name = Self.sanitizedAssetName(requestedName)
        let destination = try uniqueAssetURL(named: name, matching: source)
        if destination.isExistingMatch { return destination.url.lastPathComponent }
        try FileManager.default.copyItem(at: source, to: destination.url)
        return destination.url.lastPathComponent
    }

    /// Writes raw asset bytes into `assets/`, creating the directory on demand.
    @discardableResult
    public func saveAsset(_ data: Data, preferredName: String) throws -> String {
        let name = Self.sanitizedAssetName(preferredName)
        try Self.validateAssetSize(data.count, named: name)
        let destination = try uniqueAssetURL(named: name, matching: data)
        if !destination.isExistingMatch {
            try data.write(to: destination.url, options: .atomic)
        }
        return destination.url.lastPathComponent
    }

    private static func sanitizedAssetName(_ name: String) -> String {
        let component = (name as NSString).lastPathComponent
        let forbidden = CharacterSet(charactersIn: "()[]/\\").union(.controlCharacters)
        let replaced = String(component.unicodeScalars.map { scalar -> Character in
            // Spaces become underscores (Logseq-style): CommonMark forbids
            // unescaped spaces in a link destination, so a spaced filename
            // would break the `![alt](src)` token outside Knopo.
            if scalar == " " { return "_" }
            return forbidden.contains(scalar) ? "-" : Character(scalar)
        })
        let stripped = replaced.drop(while: { $0 == "." })
        return stripped.isEmpty ? "image" : String(stripped)
    }

    private func uniqueAssetURL(named name: String, matching source: URL) throws
        -> (url: URL, isExistingMatch: Bool) {
        try uniqueAssetURL(named: name) { candidate in
            FileManager.default.contentsEqual(atPath: source.path, andPath: candidate.path)
        }
    }

    private func uniqueAssetURL(named name: String, matching data: Data) throws
        -> (url: URL, isExistingMatch: Bool) {
        try uniqueAssetURL(named: name) { candidate in
            try Data(contentsOf: candidate) == data
        }
    }

    private func uniqueAssetURL(named name: String, matches: (URL) throws -> Bool) throws
        -> (url: URL, isExistingMatch: Bool) {
        let fm = FileManager.default
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        let proposed = assetsDir.appendingPathComponent(name)
        let proposedIsLink = isSymbolicLink(proposed)
        if !fm.fileExists(atPath: proposed.path), !proposedIsLink {
            return (proposed, false)
        }
        if !proposedIsLink, try matches(proposed) {
            return (proposed, true)
        }

        let nameURL = URL(fileURLWithPath: name)
        let ext = nameURL.pathExtension
        let stem = nameURL.deletingPathExtension().lastPathComponent
        var suffix = 1
        while true {
            let candidateName = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            let candidate = assetsDir.appendingPathComponent(candidateName)
            let candidateIsLink = isSymbolicLink(candidate)
            if !fm.fileExists(atPath: candidate.path), !candidateIsLink {
                return (candidate, false)
            }
            if !candidateIsLink, try matches(candidate) {
                return (candidate, true)
            }
            suffix += 1
        }
    }

    /// Old imports may contain links. Never reuse them as stored asset bytes.
    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}
