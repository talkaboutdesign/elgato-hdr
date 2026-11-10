import Foundation

/// "Test connection": runs connect → createStream → publish against the server, then disconnects without sending
/// media. Reports "Connected" or the stage that failed with the server's message.
final class ConnectionTester {
    private var publisher: RTMPPublisher?
    private var finished = false
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 15) { self.timeout = timeout }

    /// `done` runs once, on main.
    func run(endpoint: StreamEndpoint, key: String, metadata: StreamMetadata, done: @escaping (ConnectionTestResult) -> Void) {
        let publisher = RTMPPublisher(endpoint: endpoint, streamKey: key, metadata: metadata)
        self.publisher = publisher
        let finish: (ConnectionTestResult) -> Void = { [self] result in
            DispatchQueue.main.async { [self] in
                guard !finished else { return }
                finished = true
                self.publisher?.onState = nil; self.publisher?.stop(); self.publisher = nil
                done(result)
            }
        }
        publisher.onState = { [weak publisher] state in
            switch state {
            case .publishing: finish(.connected)
            case .failed(let message):
                finish(.failed(stage: "Publish", message: "Stream key rejected" + (message.isEmpty ? "." : ": \(message)")))
            case .reconnecting:
                // Called on the publisher's queue, where reading stats does not block.
                let (stage, text) = StreamErrorText.describe(publisher?.stats.lastError)
                finish(.failed(stage: stage, message: text))
            default: break
            }
        }
        publisher.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(.failed(stage: "Connect", message: "No answer from the server within \(Int(self.timeout)) seconds."))
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true; publisher?.onState = nil; publisher?.stop(); publisher = nil
    }
}
