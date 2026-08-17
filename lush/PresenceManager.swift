import Foundation
import SwiftUI

/// Speaks automerge-repo's Presence protocol over the core's ephemeral
/// channel: `__presence`-marked CBOR messages inside the repo's ephemeral
/// envelope. Peers keyed by envelope senderId; heartbeat 2s, ttl 10s.
@MainActor @Observable
final class PresenceManager {
    struct Peer: Identifiable {
        let senderId: String
        var channels: [String: CBOR.Value] = [:]
        var lastActiveAt = Date()
        var lastUpdateAt = Date()

        var id: String { senderId }
        var contactUrl: String? { channels["contactUrl"]?.stringValue }
        var name: String? { channels["name"]?.stringValue }
        var color: String? { channels["color"]?.stringValue }
        var avatarUrl: String? { channels["avatarUrl"]?.stringValue }
        var focused: Bool { channels["focused"]?.boolValue ?? true }
        var cursor: (anchor: String, head: String)? {
            guard let cursor = channels["cursor"],
                  let anchor = cursor["anchor"]?.stringValue,
                  let head = cursor["head"]?.stringValue
            else { return nil }
            return (anchor, head)
        }
    }

    @ObservationIgnored weak var model: NotesModel?

    private(set) var docUrl: String?
    private(set) var peers: [String: Peer] = [:]
    private(set) var enabled = true

    @ObservationIgnored private let senderId: String = {
        let key = "lushPresenceSenderId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = "lush-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
    @ObservationIgnored private let sessionId = UUID().uuidString.lowercased()
    @ObservationIgnored private var count: UInt64 = 0
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotDebounce: Task<Void, Never>?
    @ObservationIgnored private var ticksSinceSnapshot = 0
    @ObservationIgnored private var focused = true
    @ObservationIgnored private var cursorValue: CBOR.Value?
    @ObservationIgnored private var peersObservers: [UUID: () -> Void] = [:]

    func addPeersObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        peersObservers[id] = observer
        return id
    }

    func removePeersObserver(_ id: UUID) {
        peersObservers.removeValue(forKey: id)
    }

    private func notifyPeersChanged() {
        for observer in peersObservers.values { observer() }
    }

    var orderedPeers: [Peer] {
        var byContact: [String: Peer] = [:]
        var anonymous: [Peer] = []
        let ownContact = model?.presenceContactUrl
        for peer in peers.values {
            guard let contact = peer.contactUrl else {
                anonymous.append(peer)
                continue
            }
            if contact == ownContact { continue }
            if let existing = byContact[contact], existing.lastUpdateAt >= peer.lastUpdateAt {
                continue
            }
            byContact[contact] = peer
        }
        return (byContact.values + anonymous).sorted { $0.senderId < $1.senderId }
    }

    // MARK: session

    func join(_ url: String) {
        guard enabled else {
            docUrl = url
            return
        }
        guard docUrl != url else { return }
        leave()
        docUrl = url
        peers = [:]
        notifyPeersChanged()
        sendSnapshot()
        startHeartbeat()
    }

    /// Alone in a document there is nobody to keep a 2s heartbeat alive for —
    /// peers announce themselves with a snapshot when they arrive, so being
    /// slow to speak costs nothing until one does.
    private var heartbeatInterval: Duration {
        peers.isEmpty ? .seconds(30) : .seconds(2)
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                if !AppActivity.isActive {
                    await AppActivity.waitUntilActive()
                    guard !Task.isCancelled else { break }
                    // peers pruned us on their ttl while we were away
                    self?.sendSnapshot()
                }
                guard let interval = self?.heartbeatInterval else { break }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                self?.heartbeatTick()
            }
        }
    }

    func leave() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        snapshotDebounce?.cancel()
        if docUrl != nil {
            send(.map([("type", .string("goodbye"))]))
        }
        docUrl = nil
        peers = [:]
        notifyPeersChanged()
    }

    func setEnabled(_ enabled: Bool, url: String?) {
        guard self.enabled != enabled else { return }
        if !enabled {
            leave()
            self.enabled = false
            docUrl = url
            return
        }
        self.enabled = true
        docUrl = nil
        if let url {
            join(url)
        }
    }

    func focusChanged(_ isFocused: Bool) {
        guard focused != isFocused else { return }
        focused = isFocused
        broadcast(channel: "focused", value: .bool(isFocused))
    }

    func caretChanged(anchor: String, head: String) {
        let value = CBOR.Value.map([("anchor", .string(anchor)), ("head", .string(head))])
        cursorValue = value
        broadcast(channel: "cursor", value: value)
    }

    private func heartbeatTick() {
        prune()
        ticksSinceSnapshot += 1
        // heartbeats only bump lastUpdateAt on the JS side; a periodic
        // snapshot keeps lastActiveAt fresh so we survive their ttl prune
        if ticksSinceSnapshot >= 3 {
            sendSnapshot()
        } else {
            send(.map([("type", .string("heartbeat"))]))
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-10)
        let stale = peers.filter { $0.value.lastActiveAt < cutoff }.map(\.key)
        guard !stale.isEmpty else { return }
        for key in stale { peers.removeValue(forKey: key) }
        notifyPeersChanged()
    }

    // MARK: outbound

    private func localState() -> CBOR.Value {
        var state: [(String, CBOR.Value)] = []
        if let contactUrl = model?.presenceContactUrl {
            state.append(("contactUrl", .string(contactUrl)))
        }
        state.append(("name", .string(model?.contactName ?? "Anonymous")))
        state.append(("color", .string(Self.stableColor(for: model?.presenceContactUrl ?? senderId))))
        state.append(("focused", .bool(focused)))
        if let cursorValue {
            state.append(("cursor", cursorValue))
        }
        return .map(state)
    }

    private func sendSnapshot() {
        ticksSinceSnapshot = 0
        send(.map([
            ("type", .string("snapshot")),
            ("state", localState()),
        ]))
    }

    private func broadcast(channel: String, value: CBOR.Value) {
        send(.map([
            ("type", .string("update")),
            ("channel", .string(channel)),
            ("value", value),
        ]))
    }

    private func send(_ presenceMessage: CBOR.Value) {
        guard enabled, let docUrl, let core = model?.core else { return }
        let inner = CBOR.encode(.map([("__presence", presenceMessage)]))
        count += 1
        let envelope = CBOR.encode(.map([
            ("type", .string("ephemeral")),
            ("senderId", .string(senderId)),
            ("targetId", .string(senderId)),
            ("count", .uint(count)),
            ("sessionId", .string(sessionId)),
            ("documentId", .string(String(docUrl.dropFirst("automerge:".count)))),
            ("data", .bytes(inner)),
        ]))
        do {
            try core.publishEphemeral(url: docUrl, payload: envelope)
        } catch {
            if !loggedPublishFailure {
                loggedPublishFailure = true
                model?.appendSyncEvent("presence publish failed: \(error)")
            }
        }
    }

    @ObservationIgnored private var loggedPublishFailure = false

    // MARK: inbound

    func receive(url: String, payload: Data) {
        guard enabled,
              url == docUrl,
              let envelope = try? CBOR.decode(payload),
              envelope["type"]?.stringValue == "ephemeral",
              let sender = envelope["senderId"]?.stringValue,
              sender != senderId,
              let data = envelope["data"]?.bytesValue,
              let inner = try? CBOR.decode(data),
              let message = inner["__presence"]
        else { return }
        let now = Date()
        let isNew = peers[sender] == nil
        let wasAlone = peers.isEmpty
        var peer = peers[sender] ?? Peer(senderId: sender)
        switch message["type"]?.stringValue {
        case "snapshot":
            if case .map(let pairs)? = message["state"] {
                peer.channels = Dictionary(pairs.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
            }
            peer.lastActiveAt = now
            peer.lastUpdateAt = now
        case "update":
            if let channel = message["channel"]?.stringValue, let value = message["value"] {
                peer.channels[channel] = value
            }
            peer.lastActiveAt = now
            peer.lastUpdateAt = now
        case "heartbeat":
            // never CREATE a peer from a heartbeat — it has no state, and a
            // pruned peer would come back as a permanent anonymous ghost
            guard !isNew else { return }
            peer.lastActiveAt = now
            peer.lastUpdateAt = now
        case "goodbye":
            peers.removeValue(forKey: sender)
            notifyPeersChanged()
            return
        default:
            return
        }
        peers[sender] = peer
        notifyPeersChanged()
        if wasAlone {
            // back to a real heartbeat before their ttl prunes us
            startHeartbeat()
        }
        if isNew {
            // introduce ourselves to the newcomer shortly, like the JS side
            snapshotDebounce?.cancel()
            snapshotDebounce = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.sendSnapshot()
            }
        }
    }

    static func stableColor(for key: String) -> String {
        var hash: UInt32 = 2166136261
        for byte in key.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        return "hsl(\(hash % 360), 65%, 45%)"
    }

    static func platformColor(_ css: String?) -> PColor {
        guard let css else { return .gray }
        if css.hasPrefix("hsl") {
            let numbers = css
                .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .filter { !$0.isEmpty }
                .compactMap(Double.init)
            if numbers.count >= 3 {
                return PColor(
                    hue: numbers[0] / 360,
                    saturation: numbers[1] / 100,
                    brightness: min(1, numbers[2] / 100 + 0.25),
                    alpha: 1
                )
            }
        }
        if css.hasPrefix("#"), let value = UInt32(css.dropFirst(), radix: 16) {
            return PColor(rgb: Int(value))
        }
        return .gray
    }

    static func swatch(_ css: String?) -> Color {
        guard let css else { return .gray }
        if css.hasPrefix("hsl") {
            let numbers = css
                .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .filter { !$0.isEmpty }
                .compactMap(Double.init)
            if numbers.count >= 3 {
                return Color(
                    hue: numbers[0] / 360,
                    saturation: numbers[1] / 100,
                    brightness: min(1, numbers[2] / 100 + 0.25)
                )
            }
        }
        if css.hasPrefix("#"), let value = UInt32(css.dropFirst(), radix: 16) {
            return Color(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        }
        return .gray
    }
}
