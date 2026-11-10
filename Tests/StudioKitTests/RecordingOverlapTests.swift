import XCTest
@testable import StudioKit

/// Stop recording A, start B before A's writers finish: A's completion must not expose B to library recovery.
final class RecordingOverlapTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Overlap-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppDelegate.recordingDirs = []; AppDelegate.activeRecordingDir = nil
    }
    override func tearDown() {
        AppDelegate.recordingDirs = []; AppDelegate.activeRecordingDir = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// A project folder in state "recording" with no game.mov yet, as before a recording's first fragment.
    func recordingProject(_ name: String) -> URL {
        let dir = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var p = Project(name: name, createdAt: Date()); p.state = "recording"
        ProjectDoc(dir: dir, project: p).save()
        return dir
    }

    func attempted(_ lib: Library, _ dir: URL) -> Bool {
        lib.recoveryAttempted.contains { AppDelegate.recordingKey($0) == AppDelegate.recordingKey(dir) }
    }

    func testFinishingEarlierRecordingKeepsLaterOneProtected() {
        let lib = Library(root: root)
        let a = recordingProject("Capture A"), b = recordingProject("Capture B")
        AppDelegate.activeRecordingDir = a              // start A
        AppDelegate.activeRecordingDir = b              // stop A, start B while A's writers are still finishing
        XCTAssertTrue(AppDelegate.isRecording(a))
        // A's finalize completes and the library reloads, as in finishRecording.
        if let doc = ProjectDoc.load(a) { doc.project.state = "complete"; doc.save() }
        AppDelegate.recordingFinalized(a)
        lib.reload()
        XCTAssertFalse(AppDelegate.isRecording(a))
        XCTAssertTrue(AppDelegate.isRecording(b))
        XCTAssertEqual(AppDelegate.activeRecordingDir, b)
        XCTAssertFalse(attempted(lib, b), "the recording in progress was treated as interrupted")
        XCTAssertEqual(ProjectDoc.load(b)?.project.state, "recording")

        // Once B is finalized too, a folder still in "recording" is a real leftover and gets recovered.
        AppDelegate.recordingFinalized(b)
        XCTAssertNil(AppDelegate.activeRecordingDir)
        lib.reload()
        XCTAssertTrue(attempted(lib, b))
        let damaged = expectation(for: NSPredicate { _, _ in ProjectDoc.load(b)?.project.state == "damaged" }, evaluatedWith: nil)
        wait(for: [damaged], timeout: 10)
    }

    /// Folder URLs listed from disk end in "/", the one `newProjectDir` returns does not.
    func testRecordingMatchesListedFolderURL() throws {
        let dir = recordingProject("Capture C")
        AppDelegate.activeRecordingDir = root.appendingPathComponent("Capture C")
        let listed = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        XCTAssertTrue(AppDelegate.isRecording(listed))
        AppDelegate.recordingFinalized(listed)
        XCTAssertFalse(AppDelegate.isRecording(dir))
    }
}
