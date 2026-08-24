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

    /// Where the server keeps its key, peers and sedimentree. The host app
    /// points this at the core's own directory so both open one storage rather
    /// than keeping a second copy of every doc.
    public static var dataDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SubductionServer", isDirectory: true)

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
            let identity = await Task.detached { () -> (String?, String?, [String]) in
                (serverPeerId(), serverIrohNodeId(), serverIrohPeers())
            }.value
            peerId = identity.0
            irohNodeId = identity.1
            friends = identity.2
            writeServerInfo(to: dir, port: bound)
            bonjour.start(port: bound)
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Async so the blocking shutdown stays off the main actor and a later
    /// `start()` cannot bind a port the server has not given back yet.
    public func stop() async {
        bonjour.stop()
        let info = Self.dataDir.appendingPathComponent("server.json")
        await Task.detached {
            try? FileManager.default.removeItem(at: info)
            serverStop()
        }.value
        port = nil
        peerId = nil
        irohNodeId = nil
        friends = []
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
