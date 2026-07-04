import XCTest
@testable import WordlyCore

final class HotkeyStateMachineTests: XCTestCase {
    typealias E = HotkeyStateMachine.Effect
    typealias D = HotkeyStateMachine.Disposition
    var sm = HotkeyStateMachine()

    override func setUp() { sm = HotkeyStateMachine() }

    func testPushToTalk() {
        var r = sm.hotkeyDown(at: 0)
        XCTAssertEqual(r.0, D.consume)
        XCTAssertEqual(r.1, [E.startCapture])
        r = sm.hotkeyUp(at: 0.5)  // held past 300 ms
        XCTAssertEqual(r.0, D.consume)
        XCTAssertEqual(r.1, [E.stopAndProcess])
        XCTAssertEqual(sm.state, .idle)
        XCTAssertNil(sm.pendingDeadline)
    }

    func testSingleTapDiscardsAndReposts() {
        _ = sm.hotkeyDown(at: 0)
        let r = sm.hotkeyUp(at: 0.1)
        XCTAssertEqual(r.1, [])
        XCTAssertEqual(sm.pendingDeadline, 0.4)  // upTime + window
        let effects = sm.tick(at: 0.41)
        XCTAssertEqual(effects, [E.discardCapture, E.repostKey])
        XCTAssertEqual(sm.state, .idle)
        XCTAssertNil(sm.pendingDeadline)
    }

    func testEarlyTickIsNoop() {
        _ = sm.hotkeyDown(at: 0)
        _ = sm.hotkeyUp(at: 0.1)
        XCTAssertEqual(sm.tick(at: 0.2), [])
        XCTAssertEqual(sm.state, .tapPending)
    }

    func testDoubleTapTogglesThenTapStops() {
        _ = sm.hotkeyDown(at: 0)
        _ = sm.hotkeyUp(at: 0.1)
        var r = sm.hotkeyDown(at: 0.2)          // second tap within window
        XCTAssertEqual(r.0, D.consume)
        XCTAssertEqual(r.1, [])                  // capture keeps running
        XCTAssertEqual(sm.state, .toggling)
        XCTAssertNil(sm.pendingDeadline)
        r = sm.hotkeyUp(at: 0.25)                // release of second tap
        XCTAssertEqual(r.1, [])
        XCTAssertEqual(sm.state, .toggling)
        XCTAssertEqual(sm.tick(at: 5), [])       // stray timer must not fire
        r = sm.hotkeyDown(at: 9)                 // stop tap
        XCTAssertEqual(r.1, [E.stopAndProcess])
        XCTAssertEqual(sm.state, .toggleStopping)
        r = sm.hotkeyUp(at: 9.05)
        XCTAssertEqual(r.1, [])
        XCTAssertEqual(sm.state, .idle)
    }

    func testOtherKeyWhileHeldCancels() {
        _ = sm.hotkeyDown(at: 0)
        let r = sm.otherKeyDown(at: 0.15)
        XCTAssertEqual(r.0, D.pass)              // the other key types normally
        XCTAssertEqual(r.1, [E.discardCapture])
        XCTAssertEqual(sm.state, .cancelled)
        let up = sm.hotkeyUp(at: 0.3)            // our lingering key-up swallowed
        XCTAssertEqual(up.0, D.consume)
        XCTAssertEqual(up.1, [])
        XCTAssertEqual(sm.state, .idle)
    }

    func testOtherKeyDuringTapPendingRepostsThenPasses() {
        _ = sm.hotkeyDown(at: 0)
        _ = sm.hotkeyUp(at: 0.1)
        let r = sm.otherKeyDown(at: 0.2)         // user typed "^a" quickly
        XCTAssertEqual(r.0, D.pass)
        XCTAssertEqual(r.1, [E.discardCapture, E.repostKey])  // ^ first, then a passes
        XCTAssertEqual(sm.state, .idle)
    }

    func testOtherKeysDuringTogglePassAndKeepRecording() {
        _ = sm.hotkeyDown(at: 0)
        _ = sm.hotkeyUp(at: 0.1)
        _ = sm.hotkeyDown(at: 0.2)
        let r = sm.otherKeyDown(at: 1)
        XCTAssertEqual(r.0, D.pass)
        XCTAssertEqual(r.1, [])
        XCTAssertEqual(sm.state, .toggling)
    }

    func testAutorepeatDownWhileHeldIsInert() {
        _ = sm.hotkeyDown(at: 0)
        let r = sm.hotkeyDown(at: 0.2)           // monitor consumes repeats; must not re-start
        XCTAssertEqual(r.0, D.consume)
        XCTAssertEqual(r.1, [])
        XCTAssertEqual(sm.state, .held)
    }

    func testLateSecondDownAfterMissedTickActsAsFreshPress() {
        _ = sm.hotkeyDown(at: 0)
        _ = sm.hotkeyUp(at: 0.1)
        let r = sm.hotkeyDown(at: 2)             // timer never fired (edge)
        XCTAssertEqual(r.1, [E.discardCapture, E.repostKey, E.startCapture])
        XCTAssertEqual(sm.state, .held)
    }

    func testStrayEventsInIdlePass() {
        XCTAssertEqual(sm.hotkeyUp(at: 0).0, D.pass)
        XCTAssertEqual(sm.otherKeyDown(at: 0).0, D.pass)
        XCTAssertEqual(sm.state, .idle)
    }
}
