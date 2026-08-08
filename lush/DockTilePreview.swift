#if os(macOS)
import AppKit
import CoreText

enum DockTilePreview {
    static let appGroupIdentifier = "group.party.chee.patchwork.lush"
    static let imageName = "DockTileImage.png"

    static func update(title: String, body: String) {
        guard let app = NSApp else { return }
        guard let image = render(title: title, body: body, app: app) else { return }
        let view = NSImageView()
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        app.dockTile.contentView = view
        app.dockTile.display()
        write(image)
    }

    static func clear() {
        if let app = NSApp {
            app.dockTile.contentView = nil
            app.dockTile.display()
        }
        if let url = fileURL() { try? FileManager.default.removeItem(at: url) }
    }

    private static let ruleFractions: [CGFloat] = [0.451, 0.584, 0.713]
    private static let rulePitch: CGFloat = 0.131

    private static func render(title: String, body: String, size: CGFloat = 512, app: NSApplication) -> NSImage? {
        guard let base = app.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) else { return nil }

        let ink = NSColor(srgbRed: 0.42, green: 0.24, blue: 0.30, alpha: 0.95)
        let fontSize = 0.078 * size
        let titleFont = NSFont(name: "Merriweather-Bold", size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
        let bodyFont = NSFont(name: "Merriweather", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)

        let text = NSMutableAttributedString()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            text.append(NSAttributedString(
                string: trimmedTitle,
                attributes: [.font: titleFont, .foregroundColor: ink]
            ))
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            text.append(NSAttributedString(
                string: text.length > 0 ? "\n" + trimmed : trimmed,
                attributes: [.font: bodyFont, .foregroundColor: ink.withAlphaComponent(0.8)]
            ))
        }
        guard text.length > 0 else { return nil }

        let leftX = 0.18 * size
        let lineWidth = 0.68 * size
        let bottomLimit = 0.13 * size

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        base.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0.16 * size, y: 0.08 * size, width: 0.70 * size, height: 0.66 * size))
            let anchorX = leftX
            let anchorY = ruleBaseline(0, size: size)
            ctx.translateBy(x: anchorX, y: anchorY)
            ctx.rotate(by: -4 * .pi / 180)
            ctx.translateBy(x: -anchorX, y: -anchorY)
            let typesetter = CTTypesetterCreateWithAttributedString(text)
            var start = 0
            var lineIndex = 0
            let total = text.length
            while start < total {
                let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(lineWidth))
                if count == 0 { break }
                let baseline = ruleBaseline(lineIndex, size: size)
                if baseline < bottomLimit { break }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                ctx.textPosition = CGPoint(x: leftX, y: baseline)
                CTLineDraw(line, ctx)
                start += count
                lineIndex += 1
            }
            ctx.restoreGState()
        }
        image.unlockFocus()
        return image
    }

    private static func ruleBaseline(_ index: Int, size: CGFloat) -> CGFloat {
        let fraction = index < ruleFractions.count
            ? ruleFractions[index]
            : ruleFractions[ruleFractions.count - 1] + CGFloat(index - ruleFractions.count + 1) * rulePitch
        return (1 - fraction) * size + 0.012 * size
    }

    private static func fileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(imageName)
    }

    private static func write(_ image: NSImage) {
        guard let url = fileURL(),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }
}
#endif
