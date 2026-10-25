import AppKit
import SwiftUI

/// A short help hint with a predictable delay. It never takes focus or clicks.
@MainActor
final class HoverHint {
    static let shared = HoverHint()
    static let delay: TimeInterval = 0.35

    private weak var owner: NSView?
    private var text = ""
    private var pending: DispatchWorkItem?
    private(set) var panel: NSPanel?
    private var eventMonitor: Any?
    private var windowObserver: NSObjectProtocol?
    private let scheduleWork: (TimeInterval, DispatchWorkItem) -> Void

    init(scheduleWork: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) {
        self.scheduleWork = scheduleWork
    }

    func schedule(_ text: String, for view: NSView) {
        guard view.window?.isKeyWindow == true else { return }
        if owner === view && self.text == text {
            guard panel == nil else { return }
            pending?.cancel()
        } else {
            dismiss()
            owner = view
            self.text = text
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
            ) { [weak self] event in
                self?.dismiss()
                return event
            }
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: view.window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self else { return }
            guard let view, self.owner === view,
                  let window = view.window, window.isKeyWindow,
                  !view.isHiddenOrHasHiddenAncestor,
                  view.visibleRect.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
            else { self.dismiss(); return }
            self.show(text, from: view)
        }
        pending = work
        scheduleWork(Self.delay, work)
    }

    func dismiss(for view: NSView) {
        if owner === view { dismiss() }
    }

    func dismiss() {
        pending?.cancel()
        pending = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        if let panel { panel.parent?.removeChildWindow(panel) }
        panel?.orderOut(nil)
        panel = nil
        owner = nil
    }

    private func show(_ text: String, from view: NSView) {
        guard let window = view.window, let screen = window.screen else { return }
        let content = NSHostingView(rootView:
            Text(verbatim: text)
                .font(.system(size: NSFont.smallSystemFontSize))
                .foregroundStyle(.primary)
                .padding(8)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        )
        content.appearance = view.effectiveAppearance
        let size = content.fittingSize
        let mouse = NSEvent.mouseLocation
        let visible = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 16)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        if origin.y < visible.minY { origin.y = mouse.y + 20 }
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel
    }
}

extension View {
    func hoverHint(_ text: String) -> some View {
        background(HoverHintArea(text: text))
            .accessibilityHint(Text(verbatim: text))
    }
}

private struct HoverHintArea: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> HintView { HintView() }
    func updateNSView(_ view: HintView, context: Context) { view.text = text }
    static func dismantleNSView(_ view: HintView, coordinator: ()) {
        HoverHint.shared.dismiss(for: view)
    }

    final class HintView: NSView {
        var text = ""
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero,
                                     options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                     owner: self)
            addTrackingArea(area)
            self.area = area
        }

        override func mouseEntered(with event: NSEvent) { HoverHint.shared.schedule(text, for: self) }
        override func mouseMoved(with event: NSEvent) { HoverHint.shared.schedule(text, for: self) }
        override func mouseExited(with event: NSEvent) { HoverHint.shared.dismiss(for: self) }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            HoverHint.shared.dismiss(for: self)
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
