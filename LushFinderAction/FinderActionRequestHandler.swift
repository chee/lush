import Foundation

final class FinderActionRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
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
