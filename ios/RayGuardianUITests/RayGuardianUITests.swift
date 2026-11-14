import XCTest
final class RayGuardianUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(stopAfterFirstFrame: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--guardian-ui-fixture"]
        if stopAfterFirstFrame { app.launchArguments.append("--guardian-stop-after-first-frame") }
        app.launchEnvironment["GUARDIAN_UI_TEST_API"] = "http://127.0.0.1:8787"
        app.launch()
        return app
    }
    private func armAndInject(_ app: XCUIApplication) {
        let arm = app.buttons["Arm for 30 minutes"]
        XCTAssertTrue(arm.waitForExistence(timeout:15)); arm.tap()
        if !app.staticTexts["Guardian is armed"].waitForExistence(timeout:25) {
            XCTFail("Arming failed: \(app.debugDescription)"); return
        }
        app.tabBars.buttons["Replay lab"].tap()
        let inject = app.buttons["Inject ‘Guardian help me’"]
        XCTAssertTrue(inject.waitForExistence(timeout:5)); inject.tap()
        app.tabBars.buttons["Guardian"].tap()

    }
    func testActualMockCameraAndWAVReachAssessment() {
        let app = launch(); armAndInject(app)
        if !app.staticTexts["Assessment (test_fixture)"].waitForExistence(timeout:20) {
            XCTFail("Actual SDK evidence did not reach assessment: \(app.debugDescription)"); return
        }
        XCTAssertTrue(app.staticTexts["UI routing fixture: actual SDK frames received. No real provider classification was performed."].exists)
        XCTAssertTrue(app.staticTexts["guardian.evidence"].label.contains("test_fixture_stt"))
        XCTAssertFalse(app.staticTexts["Demo incident"].exists)
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.staticTexts["Your camera is off"].waitForExistence(timeout:5))
    }
    func testStopClearsActualMockCapture() {
        let app = launch(stopAfterFirstFrame:true); armAndInject(app)
        XCTAssertTrue(app.staticTexts["guardian.lastCaptureFrames"].label.contains("1 SDK frames"))
        XCTAssertTrue(app.staticTexts["Your camera is off"].waitForExistence(timeout:5))
        XCTAssertFalse(app.staticTexts["guardian.frameCount"].exists)
        XCTAssertFalse(app.staticTexts["Assessment (test_fixture)"].exists)
    }
}
