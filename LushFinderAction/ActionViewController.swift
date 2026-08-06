import Cocoa

class ActionViewController: NSViewController {
    private let handler = FinderActionRequestHandler()
    private var started = false

    override func loadView() {
        let label = NSTextField(labelWithString: "Adding to Lush…")
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
        handler.beginRequest(with: context)
    }
}
