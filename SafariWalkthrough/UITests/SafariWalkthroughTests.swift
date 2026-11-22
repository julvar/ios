import Foundation
import XCTest

@MainActor
final class SafariWalkthroughTests: XCTestCase {
    private let host = XCUIApplication()
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: "HOST\n" + host.debugDescription + "\nSAFARI\n" + safari.debugDescription + "\nSPRINGBOARD\n" + springboard.debugDescription)
        tree.name = "Accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    func testSaveBeforeSafariFillAndNextSelectionMatches() async throws {
        try await prepare(mode: "save")
        try openPicker()
        try tap("Autofill and Save")
        try await assertFilled()
        let state = try await api("state")
        let events = eventTypes(state)
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "save-success")),
                          try XCTUnwrap(events.firstIndex(of: "handoff")))
        let uris = try XCTUnwrap(state["savedURIs"] as? [String])
        XCTAssertEqual(uris.count, 2)
        XCTAssertEqual(uris.first, "https://old.example.invalid")
        XCTAssertTrue(uris.last?.contains("127.0.0.1") == true)
        capture("Successful save and Safari fill")

        // Keep the disposable vault association, but start a new empty Safari document.
        host.activate()
        host.buttons["open-safari"].tap()
        try openPicker()
        try await assertFilled() // Matching entry must fill without the new confirmation.
        let matchedState = try await api("state")
        XCTAssertEqual(matchedState["savedURIs"] as? [String], uris)
    }

    func testAutofillOnlyDoesNotSave() async throws {
        try await prepare(mode: "save")
        try openPicker()
        try tap("Autofill Only")
        try await assertFilled()
        let state = try await api("state")
        XCTAssertFalse(eventTypes(state).contains("save-start"))
        XCTAssertEqual(state["savedURIs"] as? [String], ["https://old.example.invalid"])
    }

    func testCancelDoesNotSaveOrFill() async throws {
        try await prepare(mode: "save")
        try openPicker()
        try tap("Cancel")
        XCTAssertTrue(fixtureRow.waitForExistence(timeout: 5), "Cancel must return to the picker")
        try tap("Cancel")
        try await assertUntouched()
    }

    func testSaveFailureKeepsPickerOpenUntilExplicitFillOnly() async throws {
        try await prepare(mode: "failure")
        try openPicker()
        try tap("Autofill and Save")
        let error = surfaceElement("Couldn’t save", partial: true)
        XCTAssertTrue(error.waitForExistence(timeout: 15), "Save error must remain visible")
        capture("Save failure before explicit fill")
        let before = try await api("state")
        XCTAssertFalse(eventTypes(before).contains("handoff"), "No credentials returned while error is open")
        XCTAssertEqual(before["savedURIs"] as? [String], ["https://old.example.invalid"])
        try tap("Autofill Only")
        try await assertFilled()
        let afterExplicitFill = try await api("state")
        XCTAssertEqual(eventTypes(afterExplicitFill).filter { $0 == "save-start" }.count, 1)
    }

    func testSaveFailureCancelDoesNotFill() async throws {
        try await prepare(mode: "failure")
        try openPicker()
        try tap("Autofill and Save")
        XCTAssertTrue(surfaceElement("Couldn’t save", partial: true).waitForExistence(timeout: 15))
        try tap("Cancel")
        XCTAssertTrue(fixtureRow.waitForExistence(timeout: 5))
        try tap("Cancel")
        try await assertUntouched()
        let cancelledState = try await api("state")
        XCTAssertTrue(eventTypes(cancelledState).contains("save-failed"))
    }

    func testReadOnlyLoginFillsWithoutSavePrompt() async throws {
        try await prepare(mode: "readonly")
        try openPicker()
        try await assertFilled()
        let readOnlyState = try await api("state")
        XCTAssertFalse(eventTypes(readOnlyState).contains("save-start"))
    }

    private var fixtureRow: XCUIElement {
        safari.staticTexts["Safari disposable login"]
    }

    private func prepare(mode: String) async throws {
        _ = try await api("reset", body: ["mode": mode])
        host.launch()
        let hostReady = host.buttons["enable-provider"].waitForExistence(timeout: 15)
        print("WALKTHROUGH_HOST_STATE: \(host.state.rawValue)")
        print("WALKTHROUGH_HOST_TREE: \(host.debugDescription)")
        XCTAssertTrue(hostReady, "Scene-backed fixture host must display its enable button")
        host.buttons["enable-provider"].tap()
        let allow = springboard.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'Turn On' OR label == 'Allow' OR label == 'Enable'"
        )).firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        let hostAllow = host.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'Turn On' OR label == 'Allow' OR label == 'Enable'"
        )).firstMatch
        if hostAllow.exists { hostAllow.tap() }
        if !host.staticTexts["Test provider enabled"].waitForExistence(timeout: 3) {
            try enableProviderThroughSettings()
        }
        host.buttons["check-provider"].tap()
        XCTAssertTrue(host.staticTexts["Test provider enabled"].waitForExistence(timeout: 15),
                      "iOS must enable the disposable credential provider; do not bypass this gate")
        host.buttons["open-safari"].tap()
        let continueButton = safari.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 2) { continueButton.tap() }
        XCTAssertTrue(safari.textFields["Username"].waitForExistence(timeout: 20))
    }

    private func enableProviderThroughSettings() throws {
        host.buttons["provider-settings"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15), "AutoFill Settings must open")
        print("WALKTHROUGH_SETTINGS_TREE: \\(settings.debugDescription)")
        capture("System AutoFill provider settings")
        let globalSwitch = settings.switches.matching(NSPredicate(
            format: "label CONTAINS[c] 'AutoFill Passwords'"
        )).firstMatch
        if globalSwitch.exists && globalSwitch.value as? String == "0" { globalSwitch.tap() }
        let provider = settings.switches.matching(NSPredicate(
            format: "label CONTAINS[c] 'Walkthrough'"
        )).firstMatch
        if !provider.waitForExistence(timeout: 5) {
            let row = settings.staticTexts["Bitwarden Walkthrough"]
            if row.exists { row.tap() }
        }
        XCTAssertTrue(provider.waitForExistence(timeout: 5), "Disposable provider must be registered in system settings")
        if provider.value as? String == "0" { provider.tap() }
        let consent = settings.buttons.matching(NSPredicate(
            format: "label == 'Allow' OR label CONTAINS[c] 'Turn On' OR label == 'Enable'"
        )).firstMatch
        if consent.waitForExistence(timeout: 2) { consent.tap() }
        let systemConsent = springboard.buttons.matching(NSPredicate(
            format: "label == 'Allow' OR label CONTAINS[c] 'Turn On' OR label == 'Enable'"
        )).firstMatch
        if systemConsent.exists { systemConsent.tap() }
        print("WALKTHROUGH_SETTINGS_AFTER: \\(settings.debugDescription)")
        host.activate()
    }

    private func openPicker() throws {
        let field = safari.textFields["Username"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        let passwords = safari.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'password' OR label == 'AutoFill'"
        )).firstMatch
        if passwords.waitForExistence(timeout: 5) {
            passwords.tap()
        } else {
            field.press(forDuration: 1.2)
            let autofill = safari.buttons["AutoFill"]
            XCTAssertTrue(autofill.waitForExistence(timeout: 5))
            autofill.tap()
        }
        if !fixtureRow.waitForExistence(timeout: 3) {
            let provider = safari.buttons.matching(NSPredicate(
                format: "label CONTAINS[c] 'Walkthrough'"
            )).firstMatch
            if provider.waitForExistence(timeout: 3) { provider.tap() }
            let passwordMenu = safari.buttons.matching(NSPredicate(
                format: "label CONTAINS[c] 'Passwords'"
            )).firstMatch
            if !fixtureRow.exists && passwordMenu.exists { passwordMenu.tap() }
        }
        XCTAssertTrue(fixtureRow.waitForExistence(timeout: 15), "The actual Safari extension picker must be visible")
        capture("Actual Safari credential picker")
        fixtureRow.tap()
    }

    private func surfaceElement(_ text: String, partial: Bool = false) -> XCUIElement {
        let predicate = NSPredicate(format: partial ? "label CONTAINS %@" : "label == %@", text)
        return safari.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func tap(_ title: String) throws {
        let button = safari.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Missing action: " + title)
        capture(title + " action")
        button.tap()
    }

    private func assertFilled() async throws {
        XCTAssertTrue(safari.staticTexts["Disposable login filled"].waitForExistence(timeout: 15))
        let state = try await api("state")
        XCTAssertTrue(eventTypes(state).contains("handoff"))
        let events = state["events"] as? [[String: Any]] ?? []
        XCTAssertTrue(events.contains { $0["type"] as? String == "filled" && $0["valid"] as? Bool == true })
    }

    private func assertUntouched() async throws {
        XCTAssertTrue(safari.staticTexts["Form empty"].waitForExistence(timeout: 10))
        // Give the page's polling observer time to report any unintended values after dismissal.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let state = try await api("state")
        XCTAssertFalse(eventTypes(state).contains("handoff"))
        XCTAssertFalse(eventTypes(state).contains("filled"))
        XCTAssertEqual(state["savedURIs"] as? [String], ["https://old.example.invalid"])
    }

    private func eventTypes(_ state: [String: Any]) -> [String] {
        (state["events"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
    }

    private func capture(_ title: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func api(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/" + path)!)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
