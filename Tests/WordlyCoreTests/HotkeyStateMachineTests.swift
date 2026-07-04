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
        XCTAssertNil(sm.pendingDeadline)
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
        XCTAssertNil(sm.pendingDeadline)
    }

    func testStrayEventsInIdlePass() {
        XCTAssertEqual(sm.hotkeyUp(at: 0).0, D.pass)
        XCTAssertEqual(sm.otherKeyDown(at: 0).0, D.pass)
        XCTAssertEqual(sm.state, .idle)
    }

    func testExactBoundaries() throws {
        // Hold of exactly tapWindow is a PTT release, not a tap.
        // (t - 0 is exact in FP, so this literal boundary is safe.)
        _ = sm.hotkeyDown(at: 0)
        var r = sm.hotkeyUp(at: sm.tapWindow)
        XCTAssertEqual(r.1, [E.stopAndProcess])
        XCTAssertEqual(sm.state, .idle)

        // Second down exactly at the deadline is a fresh press, not a double-tap.
        // Boundary times must come from the machine's own arithmetic: a decimal
        // literal like 1.4 rounds to either side of upTime + tapWindow.
        _ = sm.hotkeyDown(at: 1)
        _ = sm.hotkeyUp(at: 1.1)
        let boundary = try XCTUnwrap(sm.pendingDeadline)
        r = sm.hotkeyDown(at: boundary)
        XCTAssertEqual(r.1, [E.discardCapture, E.repostKey, E.startCapture])
        XCTAssertEqual(sm.state, .held)
        XCTAssertNil(sm.pendingDeadline)

        // Tick exactly at the deadline fires.
        _ = sm.hotkeyUp(at: boundary + 1)        // long hold → PTT, back to idle
        _ = sm.hotkeyDown(at: 3)
        _ = sm.hotkeyUp(at: 3.1)
        let deadline = try XCTUnwrap(sm.pendingDeadline)
        XCTAssertEqual(sm.tick(at: deadline), [E.discardCapture, E.repostKey])
        XCTAssertEqual(sm.state, .idle)
    }

    func testInertArmsStayInert() {
        // toggleStopping: extra down/otherKey must do nothing.
        _ = sm.hotkeyDown(at: 0)
        _ = sm.hotkeyUp(at: 0.1)
        _ = sm.hotkeyDown(at: 0.2)               // toggling
        _ = sm.hotkeyUp(at: 0.25)
        _ = sm.hotkeyDown(at: 1)                 // toggleStopping
        var r = sm.hotkeyDown(at: 1.01)
        XCTAssertEqual(r.0, D.consume)
        XCTAssertEqual(r.1, [])
        var o = sm.otherKeyDown(at: 1.02)
        XCTAssertEqual(o.0, D.pass)
        XCTAssertEqual(o.1, [])
        XCTAssertEqual(sm.state, .toggleStopping)
        _ = sm.hotkeyUp(at: 1.1)                 // → idle

        // cancelled: extra down/otherKey must do nothing.
        _ = sm.hotkeyDown(at: 2)
        _ = sm.otherKeyDown(at: 2.1)             // cancelled
        r = sm.hotkeyDown(at: 2.2)
        XCTAssertEqual(r.0, D.consume)
        XCTAssertEqual(r.1, [])
        o = sm.otherKeyDown(at: 2.3)
        XCTAssertEqual(o.0, D.pass)
        XCTAssertEqual(o.1, [])
        XCTAssertEqual(sm.state, .cancelled)
    }
}
