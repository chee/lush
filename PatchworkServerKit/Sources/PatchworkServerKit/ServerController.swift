import Foundation
import Observation
import SystemConfiguration

@Observable
@MainActor
public final class ServerController {
    public private(set) var port: UInt16?
    public private(set) var peerId: String?
    public private(set) var irohNodeId: String?
    public private(set) var friends: [String] = []
    public private(set) var lastError: String?

    public nonisolated static let preferredPort: UInt16 = 43217

    private let bonjour = BonjourAdvertiser()

    public var websocketURL: URL? {
        port.map { URL(string: "ws://127.0.0.1:\($0)")! }
    }

    public init() {}

    public static var dataDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SubductionServer", isDirectory: true)
    }

    /// Starts the in-process subduction server on 127.0.0.1, preferring a
    /// well-known port and falling back to an ephemeral one. Writes
    /// server.json into the data dir so anything outside the app (CLIs,
    /// scripts) can find the running server, and advertises via Bonjour.
    public func start() async {
        let dir = Self.dataDir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let bound = try await Task.detached {
                do {
                    return try serverStart(dataDir: dir.path, port: Self.preferredPort)
                } catch {
                    return try serverStart(dataDir: dir.path, port: 0)
                }
            }.value
            port = bound
            peerId = serverPeerId()
            irohNodeId = serverIrohNodeId()
            friends = serverIrohPeers()
            writeServerInfo(to: dir, port: bound)
            bonjour.start(port: bound)
        } catch {
            lastError = String(describing: error)
        }
    }

    public func stop() {
        bonjour.stop()
        try? FileManager.default.removeItem(at: Self.dataDir.appendingPathComponent("server.json"))
        serverStop()
        port = nil
        peerId = nil
    }

    /// Saves a friend's iroh node id and dials them.
    public func addFriend(_ nodeId: String) throws {
        try serverAddIrohPeer(nodeId: nodeId)
        friends = serverIrohPeers()
    }

    private func writeServerInfo(to dir: URL, port: UInt16) {
        let info: [String: Any] = [
            "port": Int(port),
            "url": "ws://127.0.0.1:\(port)",
            "peerId": peerId ?? "",
            "irohNodeId": irohNodeId ?? "",
            "serviceName": "127.0.0.1:\(port)",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("server.json"))
        }
    }
}
