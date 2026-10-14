import Foundation
import Testing
@testable import Knopo

/// Which graph a new window or tab opens (SPEC §12).
@MainActor
@Suite struct NewWindowGraphTests {

    @Test func aNewWindowInheritsTheActiveGraph() {
        let active = URL(fileURLWithPath: "/tmp/knopo-active", isDirectory: true)
        #expect(GraphManager.rootForNewWindow(inheriting: active) == active)
    }

    /// Without an active graph, use the environment or saved default.
    @Test func withNoWindowTheDefaultRootDecides() {
        #expect(GraphManager.rootForNewWindow(inheriting: nil) == GraphManager.defaultRoot())
    }
}
