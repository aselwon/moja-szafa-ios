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

final class CoreLayoutAccessibilityTests: XCTestCase {
    @MainActor
    func testPolishWardrobeAndOutfitActionsRemainReachable() {
        checkCore(language: "pl", locale: "pl_PL", wardrobe: "Szafa", outfits: "Zestawy",
                  archive: "Pokaż archiwum", newOutfit: "Nowy zestaw", name: "Nazwa zestawu", save: "Zapisz zestaw")
    }

    @MainActor
    func testEnglishWardrobeAndOutfitActionsRemainReachable() {
        checkCore(language: "en", locale: "en_US", wardrobe: "Wardrobe", outfits: "Outfits",
                  archive: "Show archive", newOutfit: "New outfit", name: "Outfit name", save: "Save outfit")
    }

    @MainActor
    private func checkCore(language: String, locale: String, wardrobe: String, outfits: String,
                           archive: String, newOutfit: String, name: String, save: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The existing Debug-only demo uses production views with an in-memory
        // repository. No login, provider, notification or AI request is made.
        app.launchArguments = ["--demo", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.tabBars.buttons[wardrobe].waitForExistence(timeout: 10))
        capture(app, name: "wardrobe-start-\(language)")
        // SwiftUI may expose a NavigationLink's combined label rather than a
        // separate static-text child. Match the visible garment name either way.
        let shirt = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Granatowy T-shirt")).firstMatch
        reveal(shirt, in: app)
        shirt.tap()
        let archived = app.switches[archive].firstMatch
        reveal(archived, in: app)
        capture(app, name: "garment-status-\(language)")
        // SwiftUI exposes the whole labeled row as the switch's AX frame.
        // Activate its trailing control, not the noninteractive label center.
        archived.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: archived)
        let outcome = XCTWaiter.wait(for: [changed], timeout: 5)
        if outcome != .completed { capture(app, name: "archive-not-updated-\(language)") }
        XCTAssertEqual(outcome, .completed)

        app.tabBars.buttons[outfits].tap()
        let create = app.buttons[newOutfit].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(create.isHittable, "The new-outfit toolbar action must remain reachable")
        create.tap()
        let title = app.textFields[name].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let longName = language == "pl"
            ? "Strój testowy z bardzo długą nazwą na chłodny dzień"
            : "An outfit with a deliberately long name for a cold day"
        title.tap()
        title.typeText(longName + "\n")
        let garment = app.buttons["Jasne spodnie"].firstMatch
        reveal(garment, in: app)
        garment.tap()
        let saveButton = app.buttons[save].firstMatch
        reveal(saveButton, in: app)
        XCTAssertTrue(saveButton.isEnabled)
        capture(app, name: "outfit-save-\(language)")
        saveButton.tap()
        let saved = app.staticTexts[longName].firstMatch
        reveal(saved, in: app)
        capture(app, name: "outfit-saved-\(language)")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<16 {
            XCTAssertEqual(app.state, .runningForeground)
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        capture(app, name: "unreachable-element")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "unreachable-element-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertTrue(element.exists, "Expected action or content must exist")
        XCTAssertTrue(element.isHittable, "Expected action or content must be reachable by scrolling")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

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
