import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ColumnsInlineView: View {
    let box: ColumnsBox
    let cache: AssetCache
    let onEdit: () -> Void
    @State private var columnCount: Int

    init(box: ColumnsBox, cache: AssetCache, onEdit: @escaping () -> Void) {
        self.box = box
        self.cache = cache
        self.onEdit = onEdit
        _columnCount = State(initialValue: box.columns.count)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { index in
                if index > 0 {
                    Divider()
                        .padding(.horizontal, 8)
                }
                ColumnEditor(box: box, index: index, cache: cache, onEdit: onEdit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("Add Column") {
                    box.raw = nil
                    box.columns.append([.block(.paragraph)])
                    columnCount = box.columns.count
                    onEdit()
                }
                Button("Remove Last Column") {
                    guard box.columns.count > 1 else { return }
                    box.raw = nil
                    box.columns.removeLast()
                    columnCount = box.columns.count
                    onEdit()
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(.background))
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(3)
        }
    }
}

@MainActor
final class ColumnEditorBridge: NSObject {
    let box: ColumnsBox
    let index: Int
    let onEdit: () -> Void

    init(box: ColumnsBox, index: Int, onEdit: @escaping () -> Void) {
        self.box = box
        self.index = index
        self.onEdit = onEdit
    }

    func storageChanged(_ storage: NSTextStorage) {
        guard index < box.columns.count else { return }
        box.raw = nil
        box.columns[index] = RichText.spans(from: storage)
        onEdit()
    }
}

#if os(macOS)
struct ColumnEditor: NSViewRepresentable {
    let box: ColumnsBox
    let index: Int
    let cache: AssetCache
    let onEdit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: ColumnEditorBridge(box: box, index: index, onEdit: onEdit))
    }

    func makeNSView(context: Context) -> NSTextView {
        let storage = NSTextStorage()
        let layoutManager = ListMarkerLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.typingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width, .height]
        if index < box.columns.count {
            storage.setAttributedString(
                RichText.attributed(from: box.columns[index], cache: cache)
            )
        }
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let bridge: ColumnEditorBridge

        init(bridge: ColumnEditorBridge) {
            self.bridge = bridge
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else { return }
            bridge.storageChanged(storage)
        }
    }
}
#else
struct ColumnEditor: UIViewRepresentable {
    let box: ColumnsBox
    let index: Int
    let cache: AssetCache
    let onEdit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: ColumnEditorBridge(box: box, index: index, onEdit: onEdit))
    }

    func makeUIView(context: Context) -> UITextView {
        let storage = NSTextStorage()
        let layoutManager = ListMarkerLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = UITextView(frame: .zero, textContainer: container)
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        textView.typingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        textView.delegate = context.coordinator
        if index < box.columns.count {
            storage.setAttributedString(
                RichText.attributed(from: box.columns[index], cache: cache)
            )
        }
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let bridge: ColumnEditorBridge

        init(bridge: ColumnEditorBridge) {
            self.bridge = bridge
        }

        func textViewDidChange(_ textView: UITextView) {
            bridge.storageChanged(textView.textStorage)
        }
    }
}
#endif
