import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct SidebarOpenBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNOPO_SIDEBAR_BENCH"] == "1"),
          arguments: [1, 10])
    func openAndSavePanesWithBacklinks(paneCount: Int) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-sidebar-open-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try GraphStore(root: root)
        for i in 0..<10 {
            var doc = try seed.createPage(named: "Pane \(i)")
            doc.blocks = (0..<400).map {
                Block(content: "Block \($0): some **formatted text** with a [[Link]] and a #tag, and enough words to wrap in a sidebar.")
            }
            seed.updatePage(doc)
            try seed.savePage(named: doc.name)
        }
        let refs = (0..<10).map { "[[Pane \($0)]]" }.joined(separator: " ")
        for i in 0..<50 {
            var doc = try seed.createPage(named: "Source \(i)")
            doc.blocks = (0..<20).map { Block(content: "Reference \($0): \(refs)") }
            seed.updatePage(doc)
            try seed.savePage(named: doc.name)
        }
        let store = try GraphStore(root: root)
        #expect(try store.cache.backlinks(of: PageName.key("Pane 0")).count == 1_000)
        let app = AppState(store: store)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        nav.rightPanes = (0..<paneCount).map { RightPane(target: .page(name: "Pane \($0)")) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        func cpuMS() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000
        }
        func settle(_ seconds: Double) async throws -> (cpu: Double, stall: Double) {
            let cpu = cpuMS()
            let end = ProcessInfo.processInfo.systemUptime + seconds
            var stall = 0.0
            while ProcessInfo.processInfo.systemUptime < end {
                let start = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .milliseconds(5))
                stall = max(stall, (ProcessInfo.processInfo.systemUptime - start - 0.005) * 1_000)
            }
            return (cpuMS() - cpu, stall)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let host = NSHostingView(rootView: RightSidebar().environmentObject(app).environmentObject(nav))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let openMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        let opened = try await settle(0.5)
        func tables(_ view: NSView) -> [OutlineTableView] {
            ((view as? OutlineTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables)
        }
        let outlines = tables(host)
        #expect(outlines.count == paneCount)
        let controller = try #require(outlines.first?.delegate as? OutlineEditorController)
        controller.focusBlock(app.document(for: "Pane 0").blocks[0].id,
                              selection: NSRange(location: 0, length: 0))
        defer { controller.endEditing() }
        _ = try await settle(0.2)
        let editor = try #require(window.firstResponder as? BlockEditorTextView)
        let version = app.dataVersion
        let editStart = ProcessInfo.processInfo.systemUptime
        editor.insertText("x", replacementRange: editor.selectedRange())
        let editMS = (ProcessInfo.processInfo.systemUptime - editStart) * 1_000
        let saved = try await settle(2.5)
        #expect(app.dataVersion > version)
        #expect(try String(contentsOf: store.fileURL(forPageNamed: "Pane 0"), encoding: .utf8)
            .contains("xBlock 0:"))
        print(String(format: "SIDEBAR BENCH (%d panes): open %.1f ms + %.1f ms settle CPU (max stall %.1f ms); key %.1f ms; save/settle CPU %.1f ms (max stall %.1f ms)",
                     paneCount, openMS, opened.cpu, opened.stall, editMS, saved.cpu, saved.stall))
    }
}
