import XCTest
@testable import StudioKit

final class GameWaitListTests: XCTestCase {
    func testAtMostThreeWait() {
        var q = GameWaitList()
        XCTAssertTrue(q.admit(0.000)); XCTAssertTrue(q.admit(0.016)); XCTAssertTrue(q.admit(0.033))
        XCTAssertFalse(q.admit(0.050), "a fourth frame waits for one to be shown")
        q.release(0.000)
        XCTAssertTrue(q.admit(0.066))
        XCTAssertEqual(q.expired, 0)
    }

    /// The freeze seen on real hardware: presented handlers stop arriving, and a plain counter then rejects every frame.
    func testRecoversWhenShownReportsNeverArrive() {
        var q = GameWaitList()
        var drawn = 0
        for i in 0..<600 where q.admit(Double(i) / 60) { drawn += 1 }   // ten seconds, nothing ever released
        XCTAssertGreaterThan(drawn, 250, "drawing must continue at a useful rate without any release")
        XCTAssertGreaterThan(q.expired, 0)
        XCTAssertLessThanOrEqual(q.times.count, 3)
    }

    func testLateReleaseOfAForgottenFrameIsHarmless() {
        var q = GameWaitList()
        XCTAssertTrue(q.admit(0)); XCTAssertTrue(q.admit(0.5))
        XCTAssertEqual(q.expired, 1)
        q.release(0)
        XCTAssertEqual(q.times, [0.5])
    }
}
