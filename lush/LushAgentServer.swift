import Foundation
import Network
import os
@preconcurrency import Dispatch

#if os(macOS)
@MainActor
final class LushAgentServer {
    static let shared = LushAgentServer()

    private weak var model: NotesModel?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "party.chee.patchwork.lush.agents")
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    func start(model: NotesModel) {
        guard listener == nil else { return }
        self.model = model
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            let token = self.token
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    Self.writeConnectionFile(port: port, token: token)
                case .failed(let error):
                    Self.log.error("listener failed: \(error.localizedDescription, privacy: .public)")
                    fallthrough
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    Task { @MainActor [weak self, weak listener] in
                        guard let self, self.listener === listener else { return }
                        self.listener = nil
                    }
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            Self.log.error("listener setup failed: \(error.localizedDescription, privacy: .public)")
            listener = nil
        }
    }

    private nonisolated func accept(_ connection: NWConnection) {
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        connection.start(queue: queue)
        read(connection, timeout: timeout)
    }

    private nonisolated func read(
        _ connection: NWConnection,
        data: Data = Data(),
        timeout: DispatchWorkItem
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, complete, error in
            guard let self else {
                timeout.cancel()
                connection.cancel()
                return
            }
            var received = data
            if let chunk { received.append(chunk) }
            switch HTTPRequest.parse(received) {
            case .request(let request):
                timeout.cancel()
                Task { @MainActor in
                    let response = await self.route(request)
                    self.send(response, through: connection)
                }
            case .needMoreData where error == nil && !complete && received.count < 1_048_576:
                self.read(connection, data: received, timeout: timeout)
            default:
                timeout.cancel()
                self.send(.json(status: 400, value: ["error": "Invalid request."]), through: connection)
            }
        }
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.authorization == "Bearer \(token)" else {
            return .json(status: 401, value: ["error": "Invalid agent token."])
        }
        guard let model, let core = model.core else {
            return .json(status: 503, value: ["error": "Lush is still starting."])
        }

        do {
            switch (request.method, request.path) {
            case ("GET", "/v1/status"):
                return .json(status: 200, value: [
                    "protocol": "lush-agent-v1",
                    "roots": model.rootFolderUrls,
                    "selected_note": model.selectedNoteUrl as Any,
                ])
            case ("GET", "/v1/notes"):
                let query = request.query["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let folder = request.query["folder"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty {
                    let filter = SearchFilter(
                        scope: folder?.isEmpty == false ? folder : nil,
                        tags: [],
                        whenFrom: nil,
                        whenTo: nil
                    )
                    let hits = await Task.detached {
                        core.searchNotes(query: query, filter: filter)
                    }.value
                    return .json(status: 200, value: ["notes": hits.map {
                        ["url": $0.url, "title": $0.name, "snippet": $0.snippet]
                    }])
                }
                let notes = await Task.detached { core.recentNotes(limit: 100) }.value
                return .json(status: 200, value: ["notes": notes.map {
                    ["url": $0.url, "title": $0.name, "modified": $0.modified] as [String: Any]
                }])
            case ("GET", "/v1/folder"):
                guard let url = request.query["url"] else {
                    return .json(status: 400, value: ["error": "Missing folder URL."])
                }
                let entries = await core.folderEntriesOf(url: url)
                return .json(status: 200, value: ["entries": entries.map {
                    ["url": $0.url, "title": $0.name, "kind": $0.kind]
                }])
            case ("GET", "/v1/note"):
                guard let url = request.query["url"] else {
                    return .json(status: 400, value: ["error": "Missing note URL."])
                }
                try? await core.openNote(url: url)
                defer { try? core.closeNote(url: url) }
                async let title = core.noteTitle(url: url)
                async let snapshot = core.noteSpansSnapshot(url: url)
                let value = try await snapshot
                let spans = try Self.jsonArray(value.spansJson)
                return .json(status: 200, value: [
                    "url": url,
                    "title": await title,
                    "text": Self.plainText(spans),
                    "spans": spans,
                    "heads": value.heads,
                ])
            case ("POST", "/v1/notes"):
                let body = try request.jsonBody()
                let title = body["title"] as? String ?? ""
                let folder = body["folder_url"] as? String
                let atTop = model.newNoteAtTop(in: folder)
                let url = try await Task.detached {
                    if let folder, !folder.isEmpty {
                        return try core.createNoteIn(folderUrl: folder, title: title, atTop: atTop)
                    }
                    return try core.createNote(title: title, atTop: atTop)
                }.value
                if let spans = body["spans"] as? [Any] {
                    _ = try await Task.detached {
                        try Self.update(core: core, url: url, spans: spans, heads: nil)
                    }.value
                } else if let text = body["text"] as? String, !text.isEmpty {
                    let spans = Self.textSpans(text)
                    _ = try await Task.detached {
                        try Self.update(core: core, url: url, spans: spans, heads: nil)
                    }.value
                }
                model.refreshNotes()
                return .json(status: 201, value: ["url": url, "open_url": Self.openURL(url)])
            case ("PUT", "/v1/note"):
                guard let url = request.query["url"] else {
                    return .json(status: 400, value: ["error": "Missing note URL."])
                }
                let body = try request.jsonBody()
                let heads = body["heads"] as? [String]
                let spans: [Any]
                if let value = body["spans"] as? [Any] {
                    spans = value
                } else if let text = body["text"] as? String {
                    spans = Self.textSpans(text)
                } else {
                    return .json(status: 400, value: ["error": "Missing text or spans."])
                }
                let newHeads = try await Task.detached {
                    try Self.update(core: core, url: url, spans: spans, heads: heads)
                }.value
                if let title = body["title"] as? String {
                    try await Task.detached { try core.renameNote(url: url, title: title) }.value
                }
                model.refreshNotes()
                return .json(status: 200, value: ["url": url, "heads": newHeads, "open_url": Self.openURL(url)])
            default:
                return .json(status: 404, value: ["error": "Unknown endpoint."])
            }
        } catch {
            return .json(status: 500, value: ["error": error.localizedDescription])
        }
    }

    private nonisolated static func update(core: Core, url: String, spans: [Any], heads: [String]?) throws -> [String] {
        let data = try JSONSerialization.data(withJSONObject: spans)
        let json = String(decoding: data, as: UTF8.self)
        return try core.updateNoteSpans(url: url, spansJson: json, heads: heads)
    }

    private static func jsonArray(_ value: String) throws -> [Any] {
        guard let data = value.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return array
    }

    private static func textSpans(_ text: String) -> [Any] {
        [
            ["type": "block", "value": ["type": "paragraph", "parents": []]],
            ["type": "text", "value": text],
        ]
    }

    private static func plainText(_ spans: [Any]) -> String {
        var pieces: [String] = []
        for span in spans {
            guard let value = span as? [String: Any], let type = value["type"] as? String else { continue }
            if type == "block", !pieces.isEmpty, pieces.last != "\n" {
                pieces.append("\n")
            } else if type == "text", let text = value["value"] as? String {
                pieces.append(text)
            }
        }
        return pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func openURL(_ url: String) -> String {
        var components = URLComponents()
        components.scheme = "lush"
        components.host = "show"
        components.queryItems = [URLQueryItem(name: "doc", value: url)]
        return components.url?.absoluteString ?? ""
    }

    private nonisolated func send(_ response: HTTPResponse, through connection: NWConnection) {
        connection.send(content: response.data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private nonisolated static let log = Logger(subsystem: "party.chee.patchwork.lush", category: "agent-server")

    private nonisolated static func connectionFileDirectories() -> [URL] {
        let fm = FileManager.default
        let home: URL
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        } else {
            home = fm.homeDirectoryForCurrentUser
        }
        var directories = [
            home.appendingPathComponent(
                "Library/Containers/party.chee.patchwork.lush/Data/Library/Application Support/Lush",
                isDirectory: true
            ),
            home.appendingPathComponent("Library/Application Support/Lush", isDirectory: true),
        ]
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directories.append(support.appendingPathComponent("Lush", isDirectory: true))
        }
        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private nonisolated static func writeConnectionFile(port: UInt16, token: String) {
        let value: [String: Any] = [
            "protocol": "lush-agent-v1",
            "url": "http://127.0.0.1:\(port)",
            "token": token,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            log.error("connection file serialization failed")
            return
        }
        let fm = FileManager.default
        var wroteAny = false
        for directory in connectionFileDirectories() {
            let file = directory.appendingPathComponent("agent.json")
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: file, options: [.atomic])
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                wroteAny = true
                log.info("connection file written for port \(port) at \(file.path, privacy: .public)")
            } catch {
                log.error("connection file write failed at \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if !wroteAny {
            log.fault("no connection file written for port \(port)")
        }
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let authorization: String?
    let body: Data

    func jsonBody() throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw HTTPRequestError.invalidJSON
        }
        return value
    }
}

extension HTTPRequest {
    enum Parse {
        case request(HTTPRequest)
        case needMoreData
        case malformed
    }

    init?(data: Data) {
        guard case .request(let request) = Self.parse(data) else { return nil }
        self = request
    }

    static func parse(_ data: Data) -> Parse {
        let separator = Data("\r\n\r\n".utf8)
        guard let boundary = data.range(of: separator) else { return .needMoreData }
        guard let header = String(data: data[..<boundary.lowerBound], encoding: .utf8)
        else { return .malformed }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ").map(String.init) ?? []
        guard first.count >= 2,
              let components = URLComponents(string: "http://127.0.0.1\(first[1])")
        else { return .malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2, !pair[0].isEmpty else { return .malformed }
            headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= 1_048_576 else { return .malformed }
        let bodyStart = boundary.upperBound
        let bodyEnd = bodyStart + length
        guard bodyEnd >= bodyStart else { return .malformed }
        guard data.count >= bodyEnd else { return .needMoreData }
        return .request(HTTPRequest(
            method: first[0],
            path: components.path,
            query: Dictionary((components.queryItems ?? []).compactMap {
                guard let value = $0.value else { return nil }
                return ($0.name, value)
            }, uniquingKeysWith: { first, _ in first }),
            authorization: headers["authorization"],
            body: data.subdata(in: bodyStart..<bodyEnd)
        ))
    }
}

enum HTTPRequestError: LocalizedError {
    case invalidJSON

    var errorDescription: String? { "The request body is not a JSON object." }
}

struct HTTPResponse {
    let data: Data

    static func json(status: Int, value: Any) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = switch status {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 503: "Service Unavailable"
        default: "Internal Server Error"
        }
        var header = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        header.append(body)
        return HTTPResponse(data: header)
    }
}
#else
@MainActor
final class LushAgentServer {
    static let shared = LushAgentServer()
    func start(model: NotesModel) {}
}
#endif
