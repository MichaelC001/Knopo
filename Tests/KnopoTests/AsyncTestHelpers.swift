import Testing

/// Wait for observable completion. The deadline bounds failures, not performance.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () throws -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while try !condition() {
        try #require(ContinuousClock.now < deadline, "Timed out waiting for completion",
                     sourceLocation: sourceLocation)
        try await Task.sleep(for: .milliseconds(10))
    }
}
