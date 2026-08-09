import CoreGraphics
import Foundation
import SwiftUI

/// Scratchpads are documents of their own: a note keeps one at `@lush.pad`, and
/// the account keeps the pocket pad. Text parked on a pad has left the note —
/// the paragraphs are cut out and their spans travel with the pad item.
enum PadKind: String {
    case text
    case ink
}

extension PadItem {
    var padKind: PadKind { PadKind(rawValue: kind) ?? .text }

    var origin_: String? { origin?.isEmpty == false ? origin : nil }

    var rect: CGRect {
        CGRect(x: x, y: y, width: max(60, w), height: max(0, h))
    }

    var spans: [SpanNode] {
        padKind == .text ? SpanNode.decodeList(data) : []
    }

    var stroke: InkStroke? {
        padKind == .ink ? InkStroke(json: data) : nil
    }
}

@Observable @MainActor
final class PadStore {
    private(set) var items: [String: [PadItem]] = [:]
    /// Note url → its pad url, once known.
    private(set) var notePads: [String: String] = [:]
    private(set) var pocketPadUrl: String?
    /// Bumped when a pad's contents change, for views that render from
    /// attributed strings rather than the items themselves.
    private(set) var version = 0

    let cache = AssetCache()
    @ObservationIgnored weak var model: NotesModel?
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var ensuring: Set<String> = []

    private static let localPocketKey = "pocketPadUrl"

    func attach(_ model: NotesModel) {
        self.model = model
    }

    // MARK: pads

    func notePad(for noteUrl: String) -> String? {
        if let known = notePads[noteUrl] { return known }
        guard let core = model?.core else { return nil }
        Task { @MainActor [weak self] in
            let url = await Task.detached { core.notePad(url: noteUrl) }.value
            guard let self, let url else { return }
            self.notePads[noteUrl] = url
            self.track(url)
            self.load(url)
        }
        return nil
    }

    @discardableResult
    func ensureNotePad(for noteUrl: String) async -> String? {
        if let known = notePads[noteUrl] { return known }
        guard let core = model?.core else { return nil }
        let url = await Task.detached { try? core.ensureNotePad(url: noteUrl) }.value
        guard let url else { return nil }
        notePads[noteUrl] = url
        load(url)
        return url
    }

    /// The pocket pad: the account's when logged in, otherwise one this device
    /// made and remembers.
    @discardableResult
    func ensurePocketPad() async -> String? {
        if let pocketPadUrl { return pocketPadUrl }
        guard let core = model?.core else { return nil }
        if let configUrl = model?.accountConfigUrl {
            if let url = await Task.detached({ try? core.ensurePocketPad(configUrl: configUrl) }).value {
                pocketPadUrl = url
                track(url)
                load(url)
                return url
            }
        }
        if let stored = UserDefaults.standard.string(forKey: Self.localPocketKey) {
            pocketPadUrl = stored
            track(stored)
            load(stored)
            return stored
        }
        guard let url = await Task.detached({ try? core.createPad(title: "Pocket Pad") }).value else {
            return nil
        }
        UserDefaults.standard.set(url, forKey: Self.localPocketKey)
        pocketPadUrl = url
        load(url)
        return url
    }

    // MARK: items

    func items(of padUrl: String?) -> [PadItem] {
        guard let padUrl else { return [] }
        if items[padUrl] == nil { load(padUrl) }
        return items[padUrl] ?? []
    }

    func load(_ padUrl: String) {
        guard let core = model?.core, !loading.contains(padUrl) else { return }
        loading.insert(padUrl)
        Task { @MainActor [weak self] in
            let fresh = await Task.detached { core.padItems(url: padUrl) }.value
            guard let self else { return }
            self.loading.remove(padUrl)
            guard fresh != self.items[padUrl] else { return }
            self.items[padUrl] = fresh
            self.version &+= 1
            await self.fetchAssets(in: fresh)
        }
    }

    func docChanged(url: String) {
        guard items[url] != nil else { return }
        load(url)
    }

    func add(_ item: PadItem, to padUrl: String) {
        items[padUrl, default: []].append(item)
        version &+= 1
        guard let core = model?.core else { return }
        Task.detached { try? core.padPutItem(url: padUrl, item: item) }
    }

    func move(_ id: String, in padUrl: String, to rect: CGRect) {
        guard let index = items[padUrl]?.firstIndex(where: { $0.id == id }) else { return }
        items[padUrl]?[index].x = rect.origin.x
        items[padUrl]?[index].y = rect.origin.y
        items[padUrl]?[index].w = rect.width
        items[padUrl]?[index].h = rect.height
        version &+= 1
        guard let core = model?.core else { return }
        Task.detached {
            try? core.padMoveItem(
                url: padUrl,
                itemId: id,
                x: rect.origin.x,
                y: rect.origin.y,
                w: rect.width,
                h: rect.height
            )
        }
    }

    func setData(_ id: String, in padUrl: String, data: String) {
        guard let index = items[padUrl]?.firstIndex(where: { $0.id == id }),
              items[padUrl]?[index].data != data
        else { return }
        items[padUrl]?[index].data = data
        version &+= 1
        guard let core = model?.core else { return }
        Task.detached { try? core.padSetData(url: padUrl, itemId: id, data: data) }
    }

    func remove(_ id: String, from padUrl: String) {
        items[padUrl]?.removeAll { $0.id == id }
        version &+= 1
        guard let core = model?.core else { return }
        Task.detached { try? core.padRemoveItem(url: padUrl, itemId: id) }
    }

    /// Move an item between pads, keeping its id so a return trip is a no-op.
    func transfer(_ item: PadItem, from padUrl: String, to targetUrl: String) {
        guard padUrl != targetUrl else { return }
        remove(item.id, from: padUrl)
        var moved = item
        moved.y = freeRow(in: targetUrl, height: item.h)
        add(moved, to: targetUrl)
    }

    // MARK: making items

    func textItem(
        spans: [SpanNode],
        origin: String?,
        in padUrl: String,
        at point: CGPoint? = nil,
        width: CGFloat = 184
    ) -> PadItem {
        let height = RichText.measuredHeight(of: spans, width: width - 16, cache: cache)
        let y = point?.y ?? freeRow(in: padUrl, height: height)
        return PadItem(
            id: UUID().uuidString,
            kind: PadKind.text.rawValue,
            x: max(0, point?.x ?? 8),
            y: max(0, y),
            w: width,
            h: min(max(28, ceil(height) + 22), 320),
            data: SpanNode.encodeList(spans),
            origin: origin,
            created: Int64(Date().timeIntervalSince1970)
        )
    }

    func inkItem(stroke: InkStroke, origin: String?) -> PadItem {
        let bounds = stroke.bounds
        return PadItem(
            id: UUID().uuidString,
            kind: PadKind.ink.rawValue,
            x: bounds.origin.x,
            y: bounds.origin.y,
            w: bounds.width,
            h: bounds.height,
            data: stroke.translated(by: CGVector(dx: -bounds.origin.x, dy: -bounds.origin.y)).json,
            origin: origin,
            created: Int64(Date().timeIntervalSince1970)
        )
    }

    /// The first row down the left edge nothing already occupies.
    func freeRow(in padUrl: String, height: CGFloat) -> CGFloat {
        let taken = (items[padUrl] ?? []).map(\.rect)
        var y: CGFloat = 8
        while taken.contains(where: { $0.origin.y < y + max(24, height) && $0.maxY > y }) {
            y += 24
        }
        return y
    }

    // MARK: assets

    /// Cards can hold images; without their bytes the attachment renders blank.
    private func fetchAssets(in items: [PadItem]) async {
        guard let model else { return }
        let urls: Set<String> = Set(items.flatMap(\.spans).compactMap { node in
            guard case .block(let block) = node,
                  block.isEmbedBlock,
                  let url = block.embedUrl,
                  url.hasPrefix("automerge:"),
                  cache.images[url] == nil, cache.names[url] == nil
            else { return nil }
            return url
        })
        guard !urls.isEmpty else { return }
        for url in urls {
            guard let data = await model.assetBytes(url) else { continue }
            if let image = PImage(data: data) {
                cache.images[url] = image
            } else if let info = await model.assetInfo(url) {
                cache.names[url] = info.name.isEmpty ? "attachment" : info.name
            }
        }
        version &+= 1
    }

    /// Sync + track a pad that arrived by url rather than being made here.
    private func track(_ padUrl: String) {
        guard let core = model?.core else { return }
        Task.detached { core.prefetchNotes(urls: [padUrl]) }
    }
}

// MARK: - ink

struct InkPoint: Equatable {
    var x: CGFloat
    var y: CGFloat
    /// 0…1. Real pressure from a pencil or tablet; speed-derived otherwise.
    var pressure: CGFloat
}

/// One freehand stroke. Points are stored relative to the item's own origin so
/// dragging a stroke around the pad is a geometry change and nothing else.
struct InkStroke: Equatable {
    var color: String
    var size: CGFloat
    var points: [InkPoint]

    init(color: String, size: CGFloat, points: [InkPoint]) {
        self.color = color
        self.size = size
        self.points = points
    }

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flat = raw["points"] as? [[Double]]
        else { return nil }
        color = raw["color"] as? String ?? "#000000"
        size = raw["size"] as? Double ?? 3
        points = flat.map {
            InkPoint(
                x: $0.count > 0 ? $0[0] : 0,
                y: $0.count > 1 ? $0[1] : 0,
                pressure: $0.count > 2 ? $0[2] : 0.5
            )
        }
    }

    var json: String {
        let flat = points.map { [round($0.x * 100) / 100, round($0.y * 100) / 100, round($0.pressure * 100) / 100] }
        let raw: [String: Any] = ["color": color, "size": size, "points": flat]
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let pad = size
        return CGRect(
            x: minX - pad,
            y: minY - pad,
            width: (maxX - minX) + pad * 2,
            height: (maxY - minY) + pad * 2
        )
    }

    func translated(by vector: CGVector) -> InkStroke {
        InkStroke(
            color: color,
            size: size,
            points: points.map { InkPoint(x: $0.x + vector.dx, y: $0.y + vector.dy, pressure: $0.pressure) }
        )
    }

    func scaled(x sx: CGFloat, y sy: CGFloat) -> InkStroke {
        InkStroke(
            color: color,
            size: size,
            points: points.map { InkPoint(x: $0.x * sx, y: $0.y * sy, pressure: $0.pressure) }
        )
    }
}

/// A pen nib, not a pipe: the stroke is filled as an outline whose width comes
/// from pressure and slows-down, so ends taper and hard turns stay sharp. The
/// shape follows the same recipe as perfect-freehand — thin the line as it
/// speeds up, smooth the input, then walk both sides of the spine.
enum Freehand {
    static func outline(_ stroke: InkStroke, streamline: CGFloat = 0.5) -> Path {
        let points = smoothed(stroke.points, streamline: streamline)
        guard points.count > 1 else {
            guard let only = points.first else { return Path() }
            let radius = stroke.size / 2 * (0.4 + 0.6 * only.pressure)
            return Path(ellipseIn: CGRect(
                x: only.x - radius,
                y: only.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        let radii = radii(points, size: stroke.size)
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for i in points.indices {
            let previous = points[max(0, i - 1)]
            let next = points[min(points.count - 1, i + 1)]
            var dx = next.x - previous.x
            var dy = next.y - previous.y
            let length = max(0.0001, sqrt(dx * dx + dy * dy))
            dx /= length
            dy /= length
            let radius = radii[i]
            left.append(CGPoint(x: points[i].x - dy * radius, y: points[i].y + dx * radius))
            right.append(CGPoint(x: points[i].x + dy * radius, y: points[i].y - dx * radius))
        }
        var path = Path()
        path.move(to: left[0])
        curve(&path, through: left.dropFirst())
        // round the far end, come back up the other side, round the near end
        let tip = points[points.count - 1]
        path.addArc(
            center: CGPoint(x: tip.x, y: tip.y),
            radius: max(0.2, radii[radii.count - 1]),
            startAngle: .radians(angle(from: CGPoint(x: tip.x, y: tip.y), to: left[left.count - 1])),
            endAngle: .radians(angle(from: CGPoint(x: tip.x, y: tip.y), to: right[right.count - 1])),
            clockwise: false
        )
        curve(&path, through: right.reversed().dropFirst())
        let start = points[0]
        path.addArc(
            center: CGPoint(x: start.x, y: start.y),
            radius: max(0.2, radii[0]),
            startAngle: .radians(angle(from: CGPoint(x: start.x, y: start.y), to: right[0])),
            endAngle: .radians(angle(from: CGPoint(x: start.x, y: start.y), to: left[0])),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }

    /// Midpoint quadratics: every point becomes a control point, so the line
    /// through hand-jittery samples stays smooth without overshooting them.
    private static func curve(_ path: inout Path, through points: some Collection<CGPoint>) {
        var previous: CGPoint?
        for point in points {
            if let previous {
                path.addQuadCurve(
                    to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2),
                    control: previous
                )
            }
            previous = point
        }
        if let previous { path.addLine(to: previous) }
    }

    private static func angle(from: CGPoint, to: CGPoint) -> Double {
        atan2(to.y - from.y, to.x - from.x)
    }

    /// Pull each sample toward the one before it — the input is noisy at the
    /// scale a nib cares about.
    private static func smoothed(_ points: [InkPoint], streamline: CGFloat) -> [InkPoint] {
        guard let first = points.first else { return [] }
        var out: [InkPoint] = [first]
        for point in points.dropFirst() {
            let previous = out[out.count - 1]
            let t = 1 - streamline
            let next = InkPoint(
                x: previous.x + (point.x - previous.x) * t,
                y: previous.y + (point.y - previous.y) * t,
                pressure: previous.pressure + (point.pressure - previous.pressure) * 0.4
            )
            if abs(next.x - previous.x) > 0.05 || abs(next.y - previous.y) > 0.05 || out.count == 1 {
                out.append(next)
            }
        }
        return out
    }

    /// Width per point: pressure, thinned by speed, and tapered at both ends so
    /// a stroke starts and finishes on a point rather than a stub.
    private static func radii(_ points: [InkPoint], size: CGFloat) -> [CGFloat] {
        var lengths: [CGFloat] = []
        var total: CGFloat = 0
        for i in points.indices {
            let previous = points[max(0, i - 1)]
            let step = hypot(points[i].x - previous.x, points[i].y - previous.y)
            total += step
            lengths.append(total)
        }
        let taper = min(total / 3, size * 3)
        return points.indices.map { i in
            let speed = i == 0 ? 0 : lengths[i] - lengths[i - 1]
            let thinning = max(0.35, 1 - min(1, speed / 12) * 0.45)
            var radius = size / 2 * (0.35 + 0.65 * points[i].pressure) * thinning
            if taper > 0.001 {
                let fromStart = min(1, lengths[i] / taper)
                let fromEnd = min(1, (total - lengths[i]) / taper)
                radius *= sqrt(min(fromStart, fromEnd)) * 0.7 + 0.3
            }
            return max(0.2, radius)
        }
    }
}

extension Color {
    /// `#rrggbb` / `#rrggbbaa`, the form ink strokes store.
    init(hex: String) {
        var text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if text.count == 6 { text += "ff" }
        let value = UInt32(text, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 24) & 0xff) / 255,
            green: Double((value >> 16) & 0xff) / 255,
            blue: Double((value >> 8) & 0xff) / 255,
            opacity: Double(value & 0xff) / 255
        )
    }
}
