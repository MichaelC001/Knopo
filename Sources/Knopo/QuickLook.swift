import AppKit
import Quartz

/// Shows files in the system Quick Look panel. A PDF shows every page there.
/// Several files step with the arrow keys, as in Finder.
///
/// The panel finds its controller through the key window's responder chain.
/// Knopo has no app delegate or window controller to take that role. So this
/// object joins the chain right after the window, and leaves when the panel
/// closes.
final class QuickLook: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()

    private var files: [URL] = []
    private weak var window: NSWindow?

    static func show(_ files: [URL], from window: NSWindow?) {
        shared.show(files, from: window)
    }

    /// Opens the panel, or closes it if open. Like Space in Finder.
    static func toggle(_ files: [URL], from window: NSWindow?) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
           panel.isVisible {
            panel.orderOut(nil)
        } else {
            show(files, from: window)
        }
    }

    private func show(_ files: [URL], from window: NSWindow?) {
        guard !files.isEmpty else { return }
        self.files = files
        if let window, window !== self.window {
            leaveChain()
            nextResponder = window.nextResponder
            window.nextResponder = self
            self.window = window
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func leaveChain() {
        if let window, window.nextResponder === self {
            window.nextResponder = nextResponder
        }
        nextResponder = nil
        window = nil
    }

    // MARK: Panel control

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !files.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        files = []
        leaveChain()
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        files.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        files[index] as NSURL
    }
}
