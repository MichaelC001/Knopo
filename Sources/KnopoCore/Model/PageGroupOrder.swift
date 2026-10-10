import Foundation

public enum PageGroupOrder {
    /// Journal days first, newest first, then other page names alphabetically.
    public static func sorted<Value>(_ groups: [String: Value]) -> [(key: String, value: Value)] {
        groups.map { (key: $0.key, value: $0.value, date: JournalDate(pageName: $0.key)) }
            .sorted {
                switch ($0.date, $1.date) {
                case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
                }
            }
            .map { (key: $0.key, value: $0.value) }
    }
}
