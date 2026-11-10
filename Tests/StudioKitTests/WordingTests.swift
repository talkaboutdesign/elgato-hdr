import XCTest
@testable import StudioKit

/// Copy shared by the live window and the editor says what is true in each.
final class WordingTests: XCTestCase {
    func testTokenHelpFitsEachContext() {
        let m = makeEditorModel()
        XCTAssertTrue(m.tokenHelp.contains("exported video"), "in an edit {timer} is the edited timeline's time")
        XCTAssertTrue(m.tokenHelp.contains("when that moment was recorded"), "in an edit {time} is the recording's clock")
        XCTAssertTrue(SceneModel().tokenHelp.hasPrefix("Live, {timer} counts the stream"))
        XCTAssertNotEqual(m.tokenHelp, SceneModel().tokenHelp)
    }

    /// "Live Sessions" means a switch, punch-in or marker (`hasLiveEvents`), not "made while streaming".
    func testLibraryEmptyStates() {
        XCTAssertFalse(LibraryCopy.noLiveSessions.contains("while streaming"))
        for word in ["switched scenes", "punched in", "marker"] { XCTAssertTrue(LibraryCopy.noLiveSessions.contains(word), word) }
        XCTAssertTrue(LibraryCopy.noRecordings.contains("open a recording"))
    }
}
