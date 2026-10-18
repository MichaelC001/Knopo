import AppKit

/// Row geometry and focus change immediately. Only the displayed layers move.
@MainActor
final class BlockEditAnimation {
    static let animationKey = "knopo.blockEdit"
    nonisolated static let defaultDuration: CFTimeInterval = 0.098
    nonisolated static let indentationDuration: CFTimeInterval = 0.075
    private static let quietInterval: CFTimeInterval = 0.18
    private let currentTime: () -> CFTimeInterval
    private let reducesMotion: () -> Bool
    private var lastEditTime: CFTimeInterval = -.infinity
    private let animatedLayers = NSHashTable<CALayer>.weakObjects()
    private var removalOverlay: RemovalOverlay?
    private var removalCleanup: DispatchWorkItem?
    var removalSnapshotCount: Int { removalOverlay?.images.count ?? 0 }

    struct Snapshot {
        var positions: [UUID: NSPoint] = [:]
        var removedImages: [(image: NSImage, frame: NSRect)] = []
        weak var host: NSView?
    }

    init(currentTime: @escaping () -> CFTimeInterval = CACurrentMediaTime,
         reducesMotion: @escaping () -> Bool = {
             NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
         }) {
        self.currentTime = currentTime
        self.reducesMotion = reducesMotion
    }

    func prepare(in table: OutlineTableView, removingIDs: Set<UUID> = [],
                 rowAt: (Int) -> (id: UUID, depth: Int)?) -> Snapshot? {
        cancel()
        let now = currentTime()
        let idle = now - lastEditTime >= Self.quietInterval
        // Repeated edits settle the first slide and stay instant until a pause.
        guard idle, table.window != nil, !reducesMotion() else { return nil }
        table.cancelFoldAnimation()
        table.layoutSubtreeIfNeeded()
        var snapshot = Snapshot()
        // The clip view keeps a deleted last row visible while the outline shrinks.
        snapshot.host = table.enclosingScrollView?.contentView ?? table.window?.contentView
        let visible = table.visibleRect
        table.enumerateAvailableRowViews { view, index in
            guard let row = rowAt(index), view.frame.intersects(visible) else { return }
            snapshot.positions[row.id] = NSPoint(
                x: CGFloat(row.depth) * OutlineRowCell.indentPerDepth, y: view.frame.minY)
            guard removingIDs.contains(row.id), let host = snapshot.host else { return }
            let rect = view.convert(visible.intersection(view.frame), from: table)
            guard !rect.isEmpty, let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else {
                return
            }
            view.cacheDisplay(in: rect, to: bitmap)
            let image = NSImage(size: rect.size)
            image.addRepresentation(bitmap)
            snapshot.removedImages.append((image, view.convert(rect, to: host)))
        }
        return snapshot
    }

    func animate(in table: OutlineTableView, from snapshot: Snapshot,
                 insertedID: UUID? = nil,
                 duration: CFTimeInterval = BlockEditAnimation.defaultDuration,
                 rowAt: (Int) -> (id: UUID, depth: Int)?) {
        table.layoutSubtreeIfNeeded()
        let visible = table.visibleRect
        var movingRows: [(index: Int, view: NSTableRowView, id: UUID, depth: Int)] = []
        table.enumerateAvailableRowViews { view, index in
            guard let row = rowAt(index),
                  snapshot.positions[row.id] != nil || view.frame.intersects(visible) else { return }
            movingRows.append((index, view, row.id, row.depth))
        }
        movingRows.sort { $0.index < $1.index }
        // Newly revealed rows follow their nearest surviving neighbor vertically.
        // Otherwise they appear beneath rows that are still sliding into place.
        var previousDY = movingRows.first { snapshot.positions[$0.id] != nil }.map {
            snapshot.positions[$0.id]!.y - $0.view.frame.minY
        } ?? 0
        for row in movingRows {
            let view = row.view
            let inserted = row.id == insertedID
            let old = snapshot.positions[row.id]
            let dx = old.map { $0.x - CGFloat(row.depth) * OutlineRowCell.indentPerDepth } ?? 0
            if let old { previousDY = old.y - view.frame.minY }
            let dy = inserted ? -min(12, view.frame.height / 2)
                : previousDY
            guard abs(dx) > 0.5 || abs(dy) > 0.5 else { continue }
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let group = CAAnimationGroup()
            group.animations = [self.animation("transform.translation.y", from: dy, to: 0, duration: duration)]
            if inserted {
                group.animations?.append(self.animation("opacity", from: 0, to: 1, duration: duration))
            }
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(group, forKey: Self.animationKey)
            self.animatedLayers.add(layer)
            if abs(dx) > 0.5,
               let cell = table.view(atColumn: 0, row: row.index, makeIfNecessary: false) as? OutlineRowCell {
                for content in cell.indentationAnimationViews {
                    content.wantsLayer = true
                    guard let contentLayer = content.layer else { continue }
                    let slide = animation("transform.translation.x", from: dx, to: 0, duration: duration)
                    slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    contentLayer.add(slide, forKey: Self.animationKey)
                    animatedLayers.add(contentLayer)
                }
            }
        }
        guard !snapshot.removedImages.isEmpty, let host = snapshot.host,
              host.window === table.window else { return }
        let overlay = RemovalOverlay(frame: host.bounds)
        overlay.wantsLayer = true
        host.addSubview(overlay)
        overlay.images = snapshot.removedImages.map {
            ($0.image, overlay.convert($0.frame, from: host))
        }
        overlay.needsDisplay = true
        removalOverlay = overlay
        let fade = animation("opacity", from: 1, to: 0, duration: duration)
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        overlay.layer?.opacity = 0
        overlay.layer?.add(fade, forKey: Self.animationKey)
        let cleanup = DispatchWorkItem { [weak self, weak overlay] in
            overlay?.removeFromSuperview()
            if self?.removalOverlay === overlay {
                self?.removalOverlay = nil
                self?.removalCleanup = nil
            }
        }
        removalCleanup = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: cleanup)
    }

    func didFinishEdit() {
        // Time spent rebuilding or taking snapshots is not a pause in typing.
        lastEditTime = currentTime()
    }

    private func animation(_ keyPath: String, from: CGFloat, to: CGFloat,
                           duration: CFTimeInterval) -> CABasicAnimation {
        let result = CABasicAnimation(keyPath: keyPath)
        result.fromValue = from
        result.toValue = to
        result.duration = duration
        result.timingFunction = CAMediaTimingFunction(name: .linear)
        return result
    }

    func cancel() {
        removalCleanup?.cancel()
        removalCleanup = nil
        removalOverlay?.removeFromSuperview()
        removalOverlay = nil
        for layer in animatedLayers.allObjects {
            layer.removeAnimation(forKey: Self.animationKey)
        }
        animatedLayers.removeAllObjects()
    }

    func remove(rowView: NSTableRowView) {
        guard animatedLayers.count > 0, let layer = rowView.layer else { return }
        removeAnimations(from: layer)
    }

    private func removeAnimations(from layer: CALayer) {
        layer.removeAnimation(forKey: Self.animationKey)
        animatedLayers.remove(layer)
        for child in layer.sublayers ?? [] { removeAnimations(from: child) }
    }

    final class RemovalOverlay: NSView {
        var images: [(image: NSImage, frame: NSRect)] = []
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func accessibilityChildren() -> [Any]? { [] }

        override func draw(_ dirtyRect: NSRect) {
            for (image, frame) in images {
                image.draw(in: frame, from: .zero, operation: .sourceOver,
                           fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }
}
