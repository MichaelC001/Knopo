import AppKit
import Testing
@testable import Knopo

@MainActor
@Suite(.serialized) struct HoverHintTests {
    private final class Scheduler {
        private var pending: [DispatchWorkItem] = []

        func schedule(after _: TimeInterval, work: DispatchWorkItem) {
            pending.append(work)
        }

        func runPending() {
            let work = pending
            pending.removeAll()
            for item in work where !item.isCancelled { item.perform() }
        }
    }

    // Keep hint tests independent of desktop focus and pointer position.
    private final class HintWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var mouseLocationOutsideOfEventStream: NSPoint { NSPoint(x: 20, y: 20) }
    }

    private func makeWindow() -> HintWindow {
        _ = NSApplication.shared
        let window = HintWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                                styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        return window
    }

    @Test func hintAppearsWithoutTakingClicksOrFocus() throws {
        let window = makeWindow()
        let view = try #require(window.contentView)
        let scheduler = Scheduler()
        let hint = HoverHint(scheduleWork: scheduler.schedule)
        defer { hint.dismiss(); window.contentView = nil }
        hint.schedule("A help hint", for: view)
        scheduler.runPending()
        let panel = try #require(hint.panel)
        #expect(panel.isVisible)
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        #expect(panel.parent === window)
        hint.dismiss(for: view)
        #expect(!panel.isVisible)
        #expect(panel.parent == nil)
    }

    @Test func leavingBeforeTheDelayCancelsTheHint() throws {
        let window = makeWindow()
        let view = try #require(window.contentView)
        let scheduler = Scheduler()
        let hint = HoverHint(scheduleWork: scheduler.schedule)
        defer { hint.dismiss(); window.contentView = nil }
        hint.schedule("A help hint", for: view)
        hint.dismiss(for: view)
        scheduler.runPending()
        #expect(hint.panel == nil)
    }

    @Test func hiddenResultsDoNotShowPendingHints() throws {
        let window = makeWindow()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        window.contentView?.addSubview(view)
        let scheduler = Scheduler()
        let hint = HoverHint(scheduleWork: scheduler.schedule)
        defer { hint.dismiss(); window.contentView = nil }
        hint.schedule("A help hint", for: view)
        view.isHidden = true
        scheduler.runPending()
        #expect(hint.panel == nil)
    }

    @Test(arguments: [false, true])
    func inputDismissesTheHint(keyboard: Bool) async throws {
        let window = makeWindow()
        let view = try #require(window.contentView)
        let hint = HoverHint()
        defer { hint.dismiss(); window.contentView = nil }
        hint.schedule("A help hint", for: view)
        try await waitUntil { hint.panel != nil }
        let event = try #require(keyboard
            ? NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, characters: "a",
                              charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
            : NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20),
                                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.sendEvent(event)
        #expect(hint.panel == nil)
    }

    @Test func losingWindowFocusDismissesTheHint() async throws {
        let window = makeWindow()
        let view = try #require(window.contentView)
        let hint = HoverHint()
        defer { hint.dismiss(); window.contentView = nil }
        hint.schedule("A help hint", for: view)
        try await waitUntil { hint.panel != nil }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(hint.panel == nil)
    }

    @Test func linksAndRemovedResultViewsDismissTheSharedHint() async throws {
        let window = makeWindow()
        let view = RenderedTextView.create()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        window.contentView = view
        let text = NSMutableAttributedString(string: "Link plain text", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 0, length: 4))
        view.textStorage?.setAttributedString(text)
        view.hoverHint = "A help hint"
        defer { HoverHint.shared.dismiss(); window.contentView = nil }

        func move(to character: Int) throws {
            let layout = try #require(view.layoutManager)
            let container = try #require(view.textContainer)
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: character)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let point = view.convert(NSPoint(x: rect.midX + view.textContainerOrigin.x,
                                             y: rect.midY + view.textContainerOrigin.y), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            view.mouseMoved(with: event)
        }
        try move(to: 6)
        try await waitUntil { HoverHint.shared.panel != nil }
        try move(to: 1)
        #expect(HoverHint.shared.panel == nil)
        try move(to: 6)
        try await waitUntil { HoverHint.shared.panel != nil }
        ResultBlockText.dismantleNSView(view, coordinator: ())
        #expect(HoverHint.shared.panel == nil)
    }
}
