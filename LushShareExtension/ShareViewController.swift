import Cocoa

class ShareViewController: NSViewController {
    private var started = false

    override func loadView() {
        let label = NSTextField(labelWithString: "Added to Lush")
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 72))
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started, let context = extensionContext else { return }
        started = true
        Task {
            do {
                if let url = try await SharedHandoff.write(from: context) {
                    _ = await context.open(url)
                }
                context.completeRequest(returningItems: nil)
            } catch {
                context.cancelRequest(withError: error)
            }
        }
    }
}
