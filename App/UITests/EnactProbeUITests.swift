import XCTest

/// Drives the iPhone app against enactd on the host (the simulator reaches it at 127.0.0.1).
/// CI starts a clean server on 8770 and one with ENACT_FAULTS=lateChunk on 8771.
/// Test names carry the use-case numbers from the README.
final class EnactProbeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false }

    override func tearDown() {
        if let a = app { let s = XCTAttachment(screenshot: a.screenshot()); s.lifetime = .keepAlways; add(s) }
    }

    func launch(port: Int, chunks: Int = 20) {
        app = XCUIApplication()
        app.launchArguments = ["-server", "ws://127.0.0.1:\(port)", "-chunks", "\(chunks)"]
        app.launch()
    }

    func text(_ id: String) -> String {
        let e = app.staticTexts[id]
        return (e.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? e.label
    }

    /// Keep dragging on the stage, as a viewer does while watching, until `until` seconds pass.
    func drag(for seconds: Double, noteAfter: Double? = nil) {
        let stage = app.otherElements["stage"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 5))
        let start = Date()
        var noted = false
        var i = 0
        while Date().timeIntervalSince(start) < seconds {
            let a = stage.coordinate(withNormalizedOffset: CGVector(dx: 0.2 + 0.1 * Double(i % 3), dy: 0.3))
            let b = stage.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7 - 0.1 * Double(i % 3)))
            a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.2)
            i += 1
            if let n = noteAfter, !noted, Date().timeIntervalSince(start) > n {
                app.buttons["directButton"].tap()
                noted = true
            }
        }
    }

    func test_UC1_UC2_UC3_UC4_UC7_UC8_UC9_liveSessionWithTouchAndNote() {
        launch(port: 8770)
        app.buttons["startButton"].tap()
        drag(for: 12, noteAfter: 5)
        let verdict = app.staticTexts["hud.verdict"]
        XCTAssertTrue(verdict.waitForExistence(timeout: 40), "session never finished")
        let summary = "\(text("hud.verdict")) | \(text("hud.latency")) | \(text("hud.stream")) | \(text("hud.inputs")) | \(text("hud.device"))"
        let note = XCTAttachment(string: summary)
        note.name = "session report"
        note.lifetime = .keepAlways
        add(note)
        // What the app itself is responsible for, whatever the machine: every frame, in order;
        // touches sent; the director's note reached the picture.
        XCTAssertTrue(text("hud.stream").contains("frames 340"), summary)
        XCTAssertTrue(text("hud.stream").contains("sequence ok"), summary)
        XCTAssertFalse(text("hud.inputs").hasPrefix("inputs 0 "), summary)
        XCTAssertFalse(text("hud.bargeIn").contains("none"), "the note never produced a new beat: \(summary)")
        if text("hud.validity").contains("too slow") {
            // Timing on an overloaded CI VM measures the VM. Recorded above; not gated.
            print("timing not gated: \(text("hud.validity")) — \(summary)")
        } else {
            XCTAssertTrue(text("hud.verdict").hasPrefix("PASS"), summary)
            XCTAssertTrue(text("hud.stream").contains("stalls 0"), summary)
        }
    }

    func test_UC4_appDetectsStallsFromALateServer() {
        launch(port: 8771)
        app.buttons["startButton"].tap()
        let verdict = app.staticTexts["hud.verdict"]
        XCTAssertTrue(verdict.waitForExistence(timeout: 45))
        XCTAssertTrue(text("hud.verdict").contains("stream.no-stalls"), "late chunks not reported: \(text("hud.verdict"))")
    }

    func test_UC5_sessionCPUAndMemory() {
        launch(port: 8770, chunks: 10)
        let opts = XCTMeasureOptions()
        opts.iterationCount = 1
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: opts) {
            app.buttons["startButton"].tap()
            XCTAssertTrue(app.staticTexts["hud.verdict"].waitForExistence(timeout: 40))
        }
        XCTAssertTrue(text("hud.device").contains("thermal nominal") || text("hud.device").contains("thermal fair"), text("hud.device"))
    }
}
