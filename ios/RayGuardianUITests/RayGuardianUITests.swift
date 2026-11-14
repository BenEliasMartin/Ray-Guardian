import XCTest
final class RayGuardianUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--guardian-ui-fixture"]
        app.launchEnvironment["GUARDIAN_UI_TEST_API"] = "http://127.0.0.1:8787"
        app.launch()
        return app
    }
    private func armAndInject(_ app: XCUIApplication) {
        let arm = app.buttons["Arm for 15 minutes"]
        XCTAssertTrue(arm.waitForExistence(timeout:15)); arm.tap()
        XCTAssertTrue(app.staticTexts["Guardian is armed"].waitForExistence(timeout:25))
        app.tabBars.buttons["Replay lab"].tap()
        let inject = app.buttons["Inject ‘Guardian help me’"]
        XCTAssertTrue(inject.waitForExistence(timeout:5)); inject.tap()
        app.tabBars.buttons["Guardian"].tap()
        let frameCounter = app.staticTexts["guardian.frameCount"]
        let received = NSPredicate(format:"label MATCHES %@", ".*[1-6]/6 frames.*")
        expectation(for:received,evaluatedWith:frameCounter)
        waitForExpectations(timeout:10)
    }
    func testActualMockCameraAndWAVReachAssessment() {
        let app = launch(); armAndInject(app)
        XCTAssertTrue(app.staticTexts["Assessment (test_fixture)"].waitForExistence(timeout:20))
        XCTAssertTrue(app.staticTexts["UI routing fixture: actual SDK frames received. No real provider classification was performed."].exists)
        XCTAssertTrue(app.staticTexts["guardian.evidence"].label.contains("test_fixture_stt"))
        XCTAssertFalse(app.staticTexts["Demo incident"].exists)
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.staticTexts["Your camera is off"].waitForExistence(timeout:5))
    }
    func testStopClearsActualMockCapture() {
        let app = launch(); armAndInject(app); app.buttons["Stop"].tap()
        XCTAssertTrue(app.staticTexts["Your camera is off"].waitForExistence(timeout:5))
        XCTAssertFalse(app.staticTexts["guardian.frameCount"].exists)
        XCTAssertFalse(app.staticTexts["Assessment (test_fixture)"].exists)
    }
}
