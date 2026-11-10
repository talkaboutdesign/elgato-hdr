import XCTest
@testable import StudioKit

/// Reuse immutable media across classes; each test gets independent project state and export paths.
actor SharedRecording {
    static let shared = SharedRecording()
    private var recordings: [Int: Task<ProjectDoc, Error>] = [:]
    func copy(to dir: URL, frames: Int) async throws -> ProjectDoc {
        let task: Task<ProjectDoc, Error>
        if let existing = recordings[frames] { task = existing }
        else {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("SharedRecording-" + UUID().uuidString)
            task = Task { try await FixtureProject.make(at: source, frameCount: frames) }
            recordings[frames] = task
        }
        let source = try await task.value
        try FileManager.default.copyItem(at: source.dir, to: dir)
        var project = source.project; project.name = dir.lastPathComponent
        let doc = ProjectDoc(dir: dir, project: project); doc.save()
        return doc
    }
}
