import Testing
@testable import KnopoCore

@Suite struct PageGroupOrderTests {
    @Test func journalsPrecedeAlphabeticalPagesAndPreserveGroups() {
        let groups = ["Zebra": [1], "alpha": [2, 3], "2026-01-01": [4],
                      "Oct 9th, 2026": [5], "2026_10_10": [6]]
        let sorted = PageGroupOrder.sorted(groups)
        expectEqual(sorted.map(\.key), ["2026_10_10", "Oct 9th, 2026", "2026-01-01", "alpha", "Zebra"])
        for group in sorted { expectEqual(group.value, groups[group.key]) }
    }

    @Test func equalDatesHaveAStableNameOrderAndInvalidDatesArePages() {
        let groups = ["2026_10_10": 1, "2026-10-10": 2, "2026-02-30": 3, "Alpha": 4]
        let sorted = PageGroupOrder.sorted(groups).map(\.key)
        expectEqual(Set(sorted.prefix(2)), Set(["2026_10_10", "2026-10-10"]))
        expectEqual(Array(sorted[2...]), ["2026-02-30", "Alpha"])
        expectEqual(sorted, PageGroupOrder.sorted(groups).map(\.key))
    }
}
