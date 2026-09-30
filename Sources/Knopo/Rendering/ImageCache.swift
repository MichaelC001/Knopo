import AppKit

/// The images rendered blocks show, shared across renders.
///
/// Every render used to load its own copy of the file. Each outline, sidebar
/// pane and reference row showing an image held a separate one. A PDF is the
/// worst case: its `NSImage` keeps the whole document, so an 80 MB scan cost
/// over 100 MB per place it appeared.
enum ImageCache {
    /// Past this, images no longer on screen are evicted. Ones still shown stay
    /// alive through their attachments; they reload on their next render.
    static let costLimit = 256 * 1_048_576
    /// A PDF page is rasterized at up to 2x, capped to this many pixels on its
    /// longer side.
    static let maxPDFPixelSide: CGFloat = 2048

    private final class Entry {
        let stamp: Stamp
        let image: NSImage
        init(stamp: Stamp, image: NSImage) {
            self.stamp = stamp
            self.image = image
        }
    }

    /// Detects a file replaced or edited on disk since it was cached.
    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int?
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = costLimit
        return cache
    }()

    /// The image for a local file, or nil when it is missing or unreadable.
    static func image(at url: URL) -> NSImage? {
        let key = url.standardizedFileURL.path as NSString
        guard let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            cache.removeObject(forKey: key)
            return nil
        }
        let stamp = Stamp(modified: values.contentModificationDate, size: values.fileSize)
        if let entry = cache.object(forKey: key), entry.stamp == stamp {
            return entry.image
        }
        guard let image = load(url) else {
            cache.removeObject(forKey: key)
            return nil
        }
        cache.setObject(Entry(stamp: stamp, image: image), forKey: key, cost: cost(of: image))
        return image
    }

    static func removeAll() {
        cache.removeAllObjects()
    }

    private static func load(_ url: URL) -> NSImage? {
        if url.pathExtension.lowercased() == "pdf" {
            return firstPDFPage(url)
        }
        return NSImage(contentsOf: url)
    }

    /// Page 1 as a bitmap. Only that page is ever shown, so the document is
    /// released right after drawing it.
    private static func firstPDFPage(_ url: URL) -> NSImage? {
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let size = page.rotationAngle % 180 == 0
            ? box.size : CGSize(width: box.height, height: box.width)
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = min(2, maxPDFPixelSide / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Pages are paper. Unfilled, a page's text would sit on the dark
        // background in dark mode.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(
            .cropBox, rect: CGRect(origin: .zero, size: size),
            rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let bitmap = context.makeImage() else { return nil }
        // Sized in points like the page, so layout and resizing see the same
        // natural size as before. An explicit bitmap rep reports its real
        // pixel count, which the cache cost needs.
        let rep = NSBitmapImageRep(cgImage: bitmap)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Decoded size in bytes, which is what drawing the image costs.
    private static func cost(of image: NSImage) -> Int {
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        if pixels > 0 { return pixels * 4 }
        // Vector images report no pixels. Estimate them at 2x.
        return Int(image.size.width * image.size.height * 16)
    }
}
