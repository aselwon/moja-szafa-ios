import XCTest

#if WARDROBE_BENCHMARK && targetEnvironment(simulator)
final class WardrobeLaunchBenchmarkTests: XCTestCase {
    @MainActor
    func testPersistedWardrobeLaunchToVisibleFirstPage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let arguments = ["--wardrobe-benchmark", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = arguments + ["--seed-wardrobe-benchmark"]
        app.launch()
        assertReady(app)
        app.terminate()
        app.launchArguments = arguments
        for _ in 0..<3 {
            app.launch()
            assertReady(app)
            app.terminate()
        }
        var samples: [Double] = []
        let clock = ContinuousClock()
        let options = XCTMeasureOptions()
        options.iterationCount = 20
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            startMeasuring()
            let start = clock.now
            app.launch()
            assertReady(app)
            let duration = start.duration(to: clock.now).components
            let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            samples.append(milliseconds)
            stopMeasuring()
            app.terminate()
        }
        // XCTest may add an unrecorded warm-up invocation. Match its final 20
        // measured iterations rather than accidentally including that warm-up.
        XCTAssertGreaterThanOrEqual(samples.count, 20)
        samples = Array(samples.suffix(20))
        let sorted = samples.sorted()
        let report: [String: Any] = [
            "schemaVersion": 1, "samplesMilliseconds": samples, "warmups": 3,
            "p95Milliseconds": sorted[18], "maxMilliseconds": sorted[19],
            "garments": 1000, "historyDays": 1826, "memberships": 9130, "firstPageCount": 40,
            "scope": "Simulator process launch through persisted OfflineStore decode and visible first wardrobe page; includes XCTest launch/query overhead and fixture validation; excludes authentication, network, photos and AI",
            "os": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "T059-wardrobe-launch.json"; attachment.lifetime = .keepAlways
        add(attachment)
        print("T059_WARDROBE_LAUNCH " + String(decoding: data, as: UTF8.self))
    }

    @MainActor
    private func assertReady(_ app: XCUIApplication) {
        XCTAssertFalse(app.staticTexts["benchmark.fixture.failed"].exists)
        let first = app.staticTexts["Benchmark garment 0000"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable, "Readiness requires a visible garment, not just an app window")
        let page = app.descendants(matching: .any)["benchmark.wardrobe.loaded"]
        XCTAssertEqual(page.value as? String, "40", "The real repository must load its first page")
    }
}
#endif

final class WelcomeAccessibilityTests: XCTestCase {
    @MainActor
    func testPolishWelcomeActionsRemainReachable() {
        checkWelcome(language: "pl", locale: "pl_PL", continueLabel: "Przejdź do logowania", emailLabel: "Adres email")
    }

    @MainActor
    func testEnglishWelcomeActionsRemainReachable() {
        checkWelcome(language: "en", locale: "en_US", continueLabel: "Continue to sign in", emailLabel: "Email address")
    }

    @MainActor
    private func checkWelcome(language: String, locale: String, continueLabel: String, emailLabel: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-reset-welcome", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        defer { app.terminate() }
        let next = app.buttons["welcome.continue"]
        let skip = app.buttons["welcome.skip"]
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        for _ in 0..<12 {
            if next.exists && skip.exists && next.isHittable && skip.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(next.waitForExistence(timeout: 2))
        XCTAssertEqual(next.label, continueLabel, "The actual app must use the requested locale")
        XCTAssertTrue(next.isHittable, "Continue must be reachable by scrolling")
        XCTAssertTrue(skip.isHittable, "Skip must be reachable by scrolling")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "welcome-actions-\(language)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        next.tap()
        XCTAssertTrue(app.textFields[emailLabel].waitForExistence(timeout: 10), "Continue must open the real sign-in screen")
        // No sign-in submission: no email, identity, provider or AI call is made.
    }
}
