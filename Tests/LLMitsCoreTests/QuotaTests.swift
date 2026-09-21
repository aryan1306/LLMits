import XCTest
@testable import LLMitsCore

final class QuotaTests: XCTestCase {
    func testPercentageClampsAndConvertsToRemaining() {
        XCTAssertEqual(window(utilization: 1.5).percentage(for: .used), 100)
        XCTAssertEqual(window(utilization: -0.1).percentage(for: .used), 0)
        XCTAssertEqual(window(utilization: 0.42).percentage(for: .remaining), 58)
    }

    func testStatusWindowPrefersFiveHour() {
        let weekly = QuotaWindow(id: "weekly", label: "Weekly", utilization: 0.2, resetsAt: nil)
        let fiveHour = QuotaWindow(id: "five-hour", label: "Five hour", utilization: 0.4, resetsAt: nil)
        let snapshot = UsageSnapshot(provider: .claude, plan: "Max", windows: [weekly, fiveHour], fetchedAt: .now)
        XCTAssertEqual(snapshot.statusWindow, fiveHour)
    }

    func testStatusWindowFallsBackToWeekly() {
        let weekly = QuotaWindow(id: "weekly", label: "Weekly", utilization: 0.2, resetsAt: nil)
        let modelLimit = QuotaWindow(id: "fable-weekly", label: "Fable weekly", utilization: 0.3, resetsAt: nil)
        let snapshot = UsageSnapshot(provider: .claude, plan: "Max", windows: [modelLimit, weekly], fetchedAt: .now)
        XCTAssertEqual(snapshot.statusWindow, weekly)
        XCTAssertEqual(snapshot.windows.count, 2, "Unknown model limits must be retained")
    }

    func testCountdownBoundaries() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(QuotaFormatting.countdown(until: now, now: now), "Now")
        XCTAssertEqual(QuotaFormatting.countdown(until: now.addingTimeInterval(90), now: now), "1m")
        XCTAssertEqual(QuotaFormatting.countdown(until: now.addingTimeInterval(7_500), now: now), "2h 5m")
        XCTAssertEqual(QuotaFormatting.countdown(until: now.addingTimeInterval(90_000), now: now), "1d 1h")
    }

    func testStalenessUsesLastSuccessfulFetch() {
        let fetched = Date(timeIntervalSince1970: 1_000)
        let snapshot = UsageSnapshot(provider: .codex, plan: "Plus", windows: [], fetchedAt: fetched)
        XCTAssertFalse(snapshot.isStale(at: fetched.addingTimeInterval(60), interval: 60))
        XCTAssertTrue(snapshot.isStale(at: fetched.addingTimeInterval(61), interval: 60))
    }

    private func window(utilization: Double) -> QuotaWindow {
        QuotaWindow(id: "weekly", label: "Weekly", utilization: utilization, resetsAt: nil)
    }
}
