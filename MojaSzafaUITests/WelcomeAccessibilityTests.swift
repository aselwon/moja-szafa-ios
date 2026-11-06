import XCTest

#if HOSTED_STAGING_ACCEPTANCE && targetEnvironment(simulator)
import UIKit

/// Explicitly opt-in: uses a real staging account and its emailed OTP.
/// The external runner must disable all result attachments before supplying input.
final class HostedStagingAcceptanceTests: XCTestCase {
    @MainActor
    func testRealEmailLoginAndSessionRestore() throws {
        guard ProcessInfo.processInfo.environment["HOSTED_PRIVATE_INPUT"] == "1" else {
            throw XCTSkip("Use the private hosted-acceptance runner with attachments disabled")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { UIPasteboard.general.items = []; app.terminate() }
        let welcome = app.buttons["welcome.continue"]
        if welcome.waitForExistence(timeout: 3) {
            for _ in 0..<12 where !welcome.isHittable { app.swipeUp() }
            XCTAssertTrue(welcome.isHittable)
            welcome.tap()
        }
        let email = app.textFields["Email address"]
        XCTAssertTrue(email.waitForExistence(timeout: 15), "A fresh real sign-in screen is required")
        try pastePrivateInput("email", into: email, app: app)
        let send = app.buttons["Send code"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let code = app.textFields["Email verification code"]
        XCTAssertTrue(code.waitForExistence(timeout: 30), "The hosted provider must issue a challenge")
        try pastePrivateInput("otp", into: code, app: app)
        app.buttons["Sign in with code"].tap()
        let wardrobe = app.tabBars.buttons["Wardrobe"]
        if !wardrobe.waitForExistence(timeout: 15) {
            let skip = app.buttons["Skip"]
            for _ in 0..<20 {
                if skip.exists && skip.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(skip.isHittable, "Real sign-in must reach optional onboarding")
            skip.tap()
        }
        XCTAssertTrue(wardrobe.waitForExistence(timeout: 20))
        wardrobe.tap()
        let seeded = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            "Synthetic staging benchmark ")).firstMatch
        XCTAssertTrue(seeded.waitForExistence(timeout: 30), "The real account's seeded wardrobe must load")
        app.terminate()
        app.launch()
        XCTAssertTrue(wardrobe.waitForExistence(timeout: 20), "The real session must survive app relaunch")
        wardrobe.tap()
        XCTAssertTrue(seeded.waitForExistence(timeout: 30))
        XCTAssertFalse(app.textFields["Email address"].exists)
    }

    @MainActor
    private func pastePrivateInput(_ name: String, into field: XCUIElement, app: XCUIApplication) throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let request = directory.appendingPathComponent("hosted-\(name).request")
        let input = directory.appendingPathComponent("hosted-\(name).json")
        try Data().write(to: request, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: request)
            UIPasteboard.general.items = []
        }
        let deadline = Date().addingTimeInterval(120)
        while !FileManager.default.fileExists(atPath: input.path) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard let data = try? Data(contentsOf: input),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let value = object["value"], !value.isEmpty else {
            XCTFail("Private hosted input was not supplied before the deadline")
            return
        }
        try FileManager.default.removeItem(at: input)
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)])
        field.tap()
        field.press(forDuration: 1.1)
        let menuItem = app.menuItems["Paste"]
        let button = app.buttons["Paste"]
        if menuItem.waitForExistence(timeout: 3) { menuItem.tap() }
        else {
            XCTAssertTrue(button.waitForExistence(timeout: 3), "User-initiated Paste must be available")
            button.tap()
        }
        // Never typeText, log, attach, or include the input in assertion messages.
        XCTAssertTrue((field.value as? String) == value, "Private input must reach the intended field")
    }
}
#endif

#if DEBUG && LAYOUT_VERIFICATION && targetEnvironment(simulator)
final class AppNavigationLayoutTests: XCTestCase {
    @MainActor
    func testOutfitCreationThroughToolbarOverflow() {
        continueAfterFailure = false
        for polish in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--app-navigation-layout-test", "-AppleLanguages", polish ? "(pl)" : "(en)",
                                   "-AppleLocale", polish ? "pl_PL" : "en_US"]
            app.launch()
            let outfits = polish ? "Zestawy" : "Outfits"
            XCTAssertTrue(app.tabBars.buttons[outfits].waitForExistence(timeout: 10))
            app.tabBars.buttons[outfits].tap()
            let create = app.buttons[polish ? "Nowy zestaw" : "New outfit"].firstMatch
            if !create.exists || !create.isHittable {
                // The captured UIKit hierarchy identifies this system control;
                // never infer overflow from the ordering of toolbar buttons.
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "before-outfit-overflow"; hierarchy.lifetime = .keepAlways
                add(hierarchy)
                let overflow = app.navigationBars.buttons["TopOverflowBarButtonItem"]
                XCTAssertTrue(overflow.waitForExistence(timeout: 5))
                XCTAssertTrue(overflow.isHittable)
                overflow.tap()
                capture(app, name: "outfit-overflow-\(polish ? "pl" : "en")")
            }
            XCTAssertTrue(create.waitForExistence(timeout: 5))
            XCTAssertTrue(create.isHittable)
            create.tap()
            XCTAssertTrue(app.textFields[polish ? "Nazwa zestawu" : "Outfit name"].waitForExistence(timeout: 5))
            let cancel = app.navigationBars.buttons[polish ? "Anuluj" : "Cancel"].firstMatch
            XCTAssertTrue(cancel.isHittable)
            capture(app, name: "outfit-editor-from-overflow-\(polish ? "pl" : "en")")
            cancel.tap()
            XCTAssertTrue(app.navigationBars[outfits].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testPolishSecondaryDestinations() { checkNavigation(polish: true) }

    @MainActor
    func testEnglishSecondaryDestinations() { checkNavigation(polish: false) }

    @MainActor
    private func checkNavigation(polish: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-navigation-layout-test", "-AppleLanguages", polish ? "(pl)" : "(en)",
                               "-AppleLocale", polish ? "pl_PL" : "en_US"]
        app.launch()
        defer { app.terminate() }
        let destinations: [(String, String)] = polish
            ? [("Dzisiaj", "Planer"), ("Dzisiaj", "Historia noszeń"), ("Szafa", "Przed zakupem"),
               ("Zestawy", "Planer"), ("Zestawy", "Wyjazdy"), ("Statystyki", "Przegląd szafy")]
            : [("Today", "Planner"), ("Today", "Wear history"), ("Wardrobe", "Before buying"),
               ("Outfits", "Planner"), ("Outfits", "Trips"), ("Statistics", "Wardrobe review")]
        for (index, destination) in destinations.enumerated() {
            let tab = app.tabBars.buttons[destination.0]
            XCTAssertTrue(tab.waitForExistence(timeout: 10))
            tab.tap()
            let link = app.navigationBars.buttons[destination.1].firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 5), "The secondary destination must be exposed in the real toolbar")
            capture(app, name: "toolbar-\(polish ? "pl" : "en")-\(index)")
            XCTAssertTrue(link.isHittable)
            link.tap()
            XCTAssertTrue(app.navigationBars[destination.1].waitForExistence(timeout: 5))
            capture(app, name: "destination-\(polish ? "pl" : "en")-\(index)")
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.isHittable)
            back.tap()
            XCTAssertTrue(app.tabBars.buttons[destination.0].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}

final class PhotoLayoutAccessibilityTests: XCTestCase {
    @MainActor func testPolishPhotoActions() { checkPhotos(language: "pl") }
    @MainActor func testEnglishPhotoActions() { checkPhotos(language: "en") }

    @MainActor private func checkPhotos(language: String) {
        continueAfterFailure = false
        let pl = language == "pl"
        let app = XCUIApplication()
        app.launchArguments = ["--photo-layout-test", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", pl ? "pl_PL" : "en_US"]
        app.launch()
        defer { app.terminate() }
        let photoImport = app.buttons["layout.photoImport"]
        XCTAssertTrue(photoImport.waitForExistence(timeout: 10))
        photoImport.tap()
        let editor = app.buttons[pl ? "Edytuj zdjęcie" : "Edit photo"].firstMatch
        reveal(editor, app: app)
        editor.tap()
        let preview = app.buttons[pl ? "Podgląd z tłem" : "Preview with background"].firstMatch
        reveal(preview, app: app)
        capture(app, "photo-crop-\(language)")
        preview.tap()
        let accept = app.buttons[pl ? "Akceptuj zdjęcie" : "Accept photo"].firstMatch
        reveal(accept, app: app)
        XCTAssertTrue(accept.isEnabled)
        capture(app, "photo-accept-\(language)")
        accept.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(accept.exists, "Accept must return to the import draft")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let export = app.buttons["layout.photoExport"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        let share = app.buttons[pl ? "Udostępnij…" : "Share…"].firstMatch
        reveal(share, app: app)
        XCTAssertTrue(share.isEnabled)
        capture(app, "photo-share-\(language)")
        // Do not dispatch an activity or send anything to another application.
        app.buttons[pl ? "Anuluj" : "Cancel"].firstMatch.tap()
        XCTAssertTrue(export.waitForExistence(timeout: 5))
    }

    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<35 {
            if element.exists && element.isHittable && app.frame.insetBy(dx: 0, dy: 24).contains(element.frame) { return }
            app.swipeUp()
        }
        capture(app, "unreachable-photo-action")
        XCTAssertTrue(element.exists && element.isHittable && app.frame.insetBy(dx: 0, dy: 24).contains(element.frame),
                      "The complete photo action must remain visible and reachable by scrolling")
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}

final class FeatureLayoutAccessibilityTests: XCTestCase {
    @MainActor
    func testPolishPriceErrorWithKeyboard() { checkPriceError(language: "pl") }

    @MainActor
    func testEnglishPriceErrorWithKeyboard() { checkPriceError(language: "en") }

    @MainActor
    private func checkPriceError(language: String) {
        continueAfterFailure = false
        let pl = language == "pl"
        let app = XCUIApplication()
        app.launchArguments = ["--feature-layout-test", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", pl ? "pl_PL" : "en_US"]
        app.launch()
        defer { app.terminate() }
        let fixture = app.buttons["layout.garment"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 10))
        fixture.tap()
        let name = app.textFields[pl ? "Nazwa" : "Name"].firstMatch
        reveal(name, app: app)
        XCTAssertEqual((name.value as? String)?.count, 200)
        let price = app.textFields[pl ? "Cena zakupu (PLN)" : "Purchase price (PLN)"].firstMatch
        reveal(price, app: app)
        price.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        price.typeText("123") // The fixture already has two decimal places.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(price.value as? String, "123.45123")
        XCTAssertLessThanOrEqual(price.frame.maxY, app.keyboards.firstMatch.frame.minY,
                                 "The focused price must be above the keyboard")
        capture(app, "garment-price-keyboard-\(language)")
        let save = app.buttons[pl ? "Zapisz ubranie" : "Save garment"].firstMatch
        revealAboveKeyboard(save, app: app, whole: true)
        print("T003_KEYBOARD_AT_SAVE \(language) \(app.keyboards.firstMatch.exists)")
        capture(app, "garment-save-keyboard-\(language)")
        save.tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            pl ? "Podaj nieujemną kwotę PLN" : "Enter a nonnegative PLN amount")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        revealAboveKeyboard(error, app: app, whole: false)
        capture(app, "garment-price-error-\(language)")
        revealAboveKeyboard(save, app: app, whole: true)
        XCTAssertTrue(save.isEnabled)
        capture(app, "garment-error-save-\(language)")
        XCTAssertFalse(app.staticTexts["layout.garmentSaved"].exists,
                       "Invalid money must not invoke the save callback")
        let cancel = app.buttons[pl ? "Anuluj" : "Cancel"].firstMatch
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(fixture.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["layout.garmentSaved"].exists)
    }

    @MainActor
    private func revealAboveKeyboard(_ element: XCUIElement, app: XCUIApplication, whole: Bool) {
        for _ in 0..<35 {
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? keyboard.frame.minY - 8 : app.frame.maxY - 24
            let top = app.frame.minY + app.frame.height * 0.22
            let viewport = CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: bottom - top)
            if element.exists && element.isHittable {
                let visible = viewport.intersection(element.frame)
                if whole ? viewport.contains(element.frame) : visible.height >= min(element.frame.height, 88) { return }
            }
            // Starting a gesture in the keyboard only types/moves focus; it does
            // not scroll the form. Keep both endpoints in visible form content.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let lower = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: bottom - 24))
            let upper = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: max(top + 24, bottom - 210)))
            if element.exists && element.frame.maxY < top {
                upper.press(forDuration: 0.05, thenDragTo: lower)
            } else {
                lower.press(forDuration: 0.05, thenDragTo: upper)
            }
        }
        capture(app, "unreachable-keyboard-action")
        XCTFail("The form control must be reachable above any visible keyboard")
    }

    @MainActor
    func testPolishFormActions() { checkForms(language: "pl") }

    @MainActor
    func testEnglishFormActions() { checkForms(language: "en") }

    @MainActor
    private func checkForms(language: String) {
        continueAfterFailure = false
        let pl = language == "pl"
        let app = XCUIApplication()
        app.launchArguments = ["--feature-layout-test", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", pl ? "pl_PL" : "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["layout.profile"].waitForExistence(timeout: 10))
        app.buttons["layout.profile"].tap()
        let style = app.switches[pl ? "Codzienny" : "Casual"].firstMatch
        reveal(style, app: app)
        capture(app, "profile-localized-\(language)")
        style.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: style)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        let saveProfile = app.buttons[pl ? "Zapisz" : "Save"].firstMatch
        reveal(saveProfile, app: app)
        capture(app, "profile-save-\(language)")
        saveProfile.tap()
        XCTAssertTrue(app.staticTexts["layout.profileSaved"].waitForExistence(timeout: 5))

        app.buttons["layout.consent"].tap()
        let allow = app.buttons[pl ? "Zgadzam się na przesłanie danych do AI" : "I consent to sending data to AI"].firstMatch
        reveal(allow, app: app)
        capture(app, "consent-allow-\(language)")
        allow.tap()
        let revoke = app.buttons[pl ? "Cofnij zgodę" : "Revoke consent"].firstMatch
        reveal(revoke, app: app)
        XCTAssertTrue(revoke.isEnabled)
        capture(app, "consent-revoke-\(language)")
        revoke.tap()
        reveal(allow, app: app)
        XCTAssertTrue(allow.isEnabled)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["layout.garment"].waitForExistence(timeout: 5))
        app.buttons["layout.garment"].tap()
        let black = app.switches[pl ? "Czarny" : "Black"].firstMatch
        reveal(black, app: app)
        capture(app, "garment-localized-\(language)")
        let saveGarment = app.buttons[pl ? "Zapisz ubranie" : "Save garment"].firstMatch
        reveal(saveGarment, app: app)
        capture(app, "garment-save-\(language)")
        saveGarment.tap()
        XCTAssertTrue(app.staticTexts["layout.garmentSaved"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<60 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        capture(app, "unreachable-action")
        XCTAssertTrue(element.exists && element.isHittable, "The form action must be reachable by scrolling")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif

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
