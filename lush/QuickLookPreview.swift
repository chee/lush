import SwiftUI
import QuickLook

#if os(iOS) || os(visionOS)
import UIKit

private struct PreviewItem: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct QuickLookScreen: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { _ in onDismiss() }
        )
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.url = url
        (controller.viewControllers.first as? QLPreviewController)?.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
#endif

extension View {
    /// The system's own media viewer for a file: the Quick Look panel on
    /// macOS, the full screen preview on iOS. Zooming, sharing and playback
    /// come with it.
    func mediaPreview(_ url: Binding<URL?>) -> some View {
        #if os(macOS)
        quickLookPreview(url)
        #else
        fullScreenCover(item: Binding(
            get: { url.wrappedValue.map(PreviewItem.init) },
            set: { url.wrappedValue = $0?.url }
        )) { item in
            QuickLookScreen(url: item.url) { url.wrappedValue = nil }
                .ignoresSafeArea()
        }
        #endif
    }
}
