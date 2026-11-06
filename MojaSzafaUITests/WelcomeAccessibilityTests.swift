import XCTest

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
