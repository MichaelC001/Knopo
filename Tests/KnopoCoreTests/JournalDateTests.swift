import Foundation
import Testing
@testable import KnopoCore

@Suite struct JournalDateTests {
    @Test func pageNamesParseAndNormalize() {
        expectEqual(JournalDate(pageName: "2026-06-10")?.pageName, "2026-06-10")
        expectNil(JournalDate(pageName: "2026-13-01"))
        expectNil(JournalDate(pageName: "not-a-date"))
        expectNil(JournalDate(pageName: "2026-6-1"))

        // Logseq's underscore filename form names the same day.
        expectEqual(JournalDate(pageName: "2024_04_30")?.pageName, "2024-04-30")
        expectNil(JournalDate(pageName: "2024_13_01"))
        expectNil(JournalDate(pageName: "not_a_date"))
    }

    @Test func displayNameUsesTheRequestedFormat() throws {
        let day = try #require(JournalDate(pageName: "2026-06-10"))
        expectEqual(day.displayName(using: JournalDateFormat(rawValue: "MMM d{ordinal}, yyyy"),
                                    locale: Locale(identifier: "en_US")), "Jun 10th, 2026")
    }

    @Test func addingDaysCrossesYearBoundaries() throws {
        let june = try #require(JournalDate(pageName: "2026-06-10"))
        expectEqual(june.adding(days: 1).pageName, "2026-06-11")
        let january = try #require(JournalDate(pageName: "2026-01-01"))
        expectEqual(january.adding(days: -1).pageName, "2025-12-31")
    }
}
