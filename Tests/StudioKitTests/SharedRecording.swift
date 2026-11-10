import XCTest
@testable import StudioKit

/// Reuse immutable media across classes; each test gets independent project state and export paths.
actor SharedRecording {
    static let shared = SharedRecording()
    private var recording: Task<ProjectDoc, Error>?
    func copy(to dir: URL, frames: Int) async throws -> ProjectDoc {
        let task: Task<ProjectDoc, Error>
        if let existing = recording { task = existing }
        else {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("SharedRecording-" + UUID().uuidString)
            task = Task { try await FixtureProject.make(at: source, frameCount: 180) }
            recording = task
        }
        let source = try await task.value
        try FileManager.default.copyItem(at: source.dir, to: dir)
        var project = source.project; project.name = dir.lastPathComponent
        if frames < 180 {
            project.durationMs = Double(frames) * 1000 / 60
            project.trimEndMs = project.durationMs
            project.timeline.segments = [Segment(startMs: 0, endMs: project.durationMs)]
        }
        let doc = ProjectDoc(dir: dir, project: project); doc.save()
        return doc
    }
}
