import Testing
@testable import SwiftSentry

struct SentryTests {
    func testUploadEvent() async throws {
        let sentry = try Sentry(dsn: "dsn")
    }
}