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
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        // Form rows are lazy; realize controls with short drags rather than assuming offscreen rows exist.
        for _ in 0..<9 {
            if button.exists && button.isHittable { button.tap(); return }
            let start = app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.72))
            let end = app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.42))
            start.press(forDuration:0.1,thenDragTo:end)
        }
        XCTFail("Control unavailable: \(identifier)\n\(app.debugDescription)")
    }
    private func armAndInject(_ app: XCUIApplication, event: String = "guardian.injectDistress") {
        let arm = app.buttons["guardian.arm"]
        XCTAssertTrue(arm.waitForExistence(timeout:15)); arm.tap()
        if !app.staticTexts["Guardian is armed"].waitForExistence(timeout:25) {
            XCTFail("Arming failed: \(app.debugDescription)"); return
        }
        app.tabBars.buttons["Mock glasses"].tap()
        tap(event,in:app)
        app.tabBars.buttons["Guardian"].tap()
    }
    func testActualMockCameraAndWAVReachAssessment() {
        let app = launch(); armAndInject(app)
        if !app.staticTexts["Assessment (test_fixture)"].waitForExistence(timeout:25) {
            XCTFail("Actual SDK evidence did not reach assessment: \(app.debugDescription)"); return
        }
        XCTAssertTrue(app.staticTexts["UI routing fixture: actual SDK frames received. No real provider classification was performed."].exists)
        XCTAssertTrue(app.staticTexts["guardian.evidence"].label.contains("test_fixture_stt"))
        XCTAssertTrue(app.staticTexts["Demo incident"].exists)
        tap("guardian.stop",in:app)
        XCTAssertTrue(app.staticTexts["Your camera is off"].waitForExistence(timeout:5))
    }
    func testStopClearsActualMockCapture() {
        let app = launch(stopAfterFirstFrame:true); armAndInject(app)
        let stoppedWithFrame = NSPredicate(format:"label CONTAINS %@", "1 SDK frames")
        expectation(for:stoppedWithFrame,evaluatedWith:app.staticTexts["guardian.lastCaptureFrames"])
        waitForExpectations(timeout:10)
        XCTAssertTrue(app.staticTexts["Your camera is off"].waitForExistence(timeout:5))
        let count = app.staticTexts["guardian.frameCount"]
        if count.exists { XCTAssertTrue(count.label.hasPrefix("0/6")) }
        XCTAssertFalse(app.staticTexts["Assessment (test_fixture)"].exists)
    }
    func testActualMockMotionStartsBoundedAssessment() {
        let app = launch(); armAndInject(app,event:"guardian.injectMotion")
        if !app.staticTexts["Assessment (test_fixture)"].waitForExistence(timeout:25) {
            XCTFail("Mock motion did not reach capture: \(app.debugDescription)"); return
        }
        XCTAssertFalse(app.staticTexts["Demo incident"].exists)
        tap("guardian.stop",in:app)
    }
    func testActualMockSpeechRequestsAndCancelsCheckIn() {
        let app = launch(); armAndInject(app,event:"guardian.injectDistress")
        XCTAssertTrue(app.staticTexts["Demo incident"].waitForExistence(timeout:10))
        app.tabBars.buttons["Mock glasses"].tap(); tap("guardian.injectCancel",in:app)
        app.tabBars.buttons["Guardian"].tap()
        XCTAssertTrue(app.staticTexts["Your camera is off"].waitForExistence(timeout:10))
    }
}
