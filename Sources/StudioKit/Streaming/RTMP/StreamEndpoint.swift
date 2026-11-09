import Foundation

struct StreamEndpoint: Equatable {
    var scheme: String
    var host: String
    var port: Int
    var app: String
    var tcUrl: String { "\(scheme)://\(host):\(port)/\(app)" }

    init?(url: String) {
        guard let c = URLComponents(string: url), let scheme = c.scheme?.lowercased(),
              ["rtmp", "rtmps"].contains(scheme), let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.fragment == nil else { return nil }
        let path = c.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let port = c.port ?? (scheme == "rtmps" ? 443 : 1935)
        guard !path.isEmpty, (1...65535).contains(port) else { return nil }
        self.scheme = scheme; self.host = host; self.port = port
        self.app = path + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
}

struct StreamMetadata {
    var width, height: Int
    var fps: Double
    var videoKbps, audioKbps: Int
}
