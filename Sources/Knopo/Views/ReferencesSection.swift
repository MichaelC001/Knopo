import AppKit
import SwiftUI
import KnopoCore

/// Linked References and Unlinked References below page content (SPEC §9).
struct ReferencesSection: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let pageName: String

    @State private var linkedExpanded = true
    @State private var unlinkedExpanded = false

    var body: some View {
        let _ = app.dataVersion
        let backlinks = (try? app.store.cache.backlinks(of: PageName.key(pageName))) ?? []
        // Only the cheap existence probe runs per render; the full unlinked
        // scan (fetch + word-boundary regex) is deferred until the section is
        // expanded, so opening/editing a heavily-referenced page doesn't pay
        // for it on every keystroke's debounced save.
        let hasUnlinked = (try? app.store.cache.hasUnlinkedReferences(toPageNamed: pageName)) ?? false

        VStack(alignment: .leading, spacing: 18 * BlockRenderer.zoom) {
            if !backlinks.isEmpty {
                VStack(alignment: .leading, spacing: 8 * BlockRenderer.zoom) {
                    linkedSection(backlinks)
                }
            }
            if hasUnlinked {
                VStack(alignment: .leading, spacing: 8 * BlockRenderer.zoom) {
                    unlinkedSection()
                }
            }
        }
    }

    /// Section titles and badges scale with content zoom, like the blocks.
    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: BlockRenderer.baseFontSize * 1.08, weight: .semibold))
    }

    /// Both section headers sit at the same level. Their contents sit one
    /// level in, so the two read as peers.
    private func sectionHeader(
        _ title: LocalizedStringKey, expanded: Bool, count: Int?, fill: Color,
        toggle: @escaping () -> Void
    ) -> some View {
        Button(action: toggle) {
            HStack(spacing: 4 * BlockRenderer.zoom) {
                ResultChevron(expanded: expanded)
                sectionTitle(title)
                if let count { countBadge(count, fill: fill).padding(.leading, 2) }
            }
        }
        .buttonStyle(.plain)
    }

    private func countBadge(_ count: Int, fill: Color) -> some View {
        Text(verbatim: "\(count)")   // a number, not a key
            .font(.system(size: BlockRenderer.baseFontSize * 0.8))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(fill))
    }

    // MARK: - Linked (SPEC §9.1)

    @ViewBuilder
    private func linkedSection(_ hits: [BacklinkHit]) -> some View {
        sectionHeader("Linked References", expanded: linkedExpanded, count: hits.count,
                      fill: Color.accentColor.opacity(0.2)) { linkedExpanded.toggle() }
        if linkedExpanded {
            BlockResultList(
                groups: PageGroupOrder.sorted(Dictionary(grouping: hits, by: \.pageDisplayName)),
                editable: true)
                .padding(.leading, BlockResultList.levelIndent)
        }
    }

    // MARK: - Unlinked (SPEC §9.2)

    @ViewBuilder
    private func unlinkedSection() -> some View {
        // The full word-boundary scan runs only while the section is open; the
        // collapsed header is driven by the cheap existence probe in `body`.
        let hits = unlinkedExpanded
            ? ((try? app.store.cache.unlinkedReferences(toPageNamed: pageName)) ?? [])
            : []

        sectionHeader("Unlinked References", expanded: unlinkedExpanded,
                      count: unlinkedExpanded ? hits.count : nil,
                      fill: Color.secondary.opacity(0.15)) { unlinkedExpanded.toggle() }

        if unlinkedExpanded {
            if hits.isEmpty {
                Text("No unlinked references.")
                    .font(.system(size: BlockRenderer.baseFontSize * 0.85))
                    .foregroundStyle(.secondary)
                    .padding(.leading, BlockResultList.levelIndent)
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(hits, id: \.blockID) { hit in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.displayTitle(for: hit.pageDisplayName))
                                    .font(.system(size: BlockRenderer.baseFontSize * 0.85))
                                    .foregroundStyle(.secondary)
                                ResultBlockText(
                                    text: BlockRenderer.render(
                                        content: hit.content,
                                        context: BlockResultList.renderContext(app)),
                                    onLink: { url, sidebar in nav.openURL(url, inSidebar: sidebar) },
                                    onImageResize: { index, width in
                                        BlockResultList.resizeImage(app, block: hit.blockID,
                                                                    imageIndex: index, width: width)
                                    })
                            }
                            Button("Link") { link(hit) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        .padding(.leading, BlockResultList.levelIndent)
                    }
                }
            }
        }
    }

    /// Wraps the matched text in `[[...]]` in the source block (SPEC §9.2).
    private func link(_ hit: SearchHit) {
        let pattern = "(?<![\\[\\w#])" + NSRegularExpression.escapedPattern(for: pageName) + "(?![\\]\\w])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return }
        let linked = BlockResultList.updateSourceBlock(app, hit.blockID, undoLabel: "Link Reference") {
            content in
            let range = NSRange(content.startIndex..., in: content)
            guard let match = regex.firstMatch(in: content, range: range),
                  let r = Range(match.range, in: content) else { return nil }
            return content.replacingCharacters(in: r, with: "[[\(pageName)]]")
        }
        if linked { app.flushPendingSaves() }
    }
}
