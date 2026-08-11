#if os(iOS) || os(visionOS)
import BackgroundTasks
import UIKit

@MainActor
enum BackgroundSync {
    static let refreshIdentifier = "party.chee.patchwork.lush.sync.refresh"
    static let processingIdentifier = "party.chee.patchwork.lush.sync.processing"

    private static var assertion = UIBackgroundTaskIdentifier.invalid
    private static var assertionWork: Task<Void, Never>?
    private static var assertionToken: UUID?

    private final class Completion: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var completed = false

        init(_ task: BGTask) {
            self.task = task
        }

        func finish(success: Bool) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            lock.unlock()
            task.setTaskCompleted(success: success)
        }
    }

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            Task { @MainActor in await run(task, budget: .seconds(20)) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { task in
            Task { @MainActor in await run(task, budget: .seconds(120)) }
        }
    }

    static func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        let processing = BGProcessingTaskRequest(identifier: processingIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)

        for request in [refresh, processing] as [BGTaskRequest] {
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                NSLog("lush: couldn't schedule \(request.identifier): \(error.localizedDescription)")
            }
        }
    }

    static func didEnterBackground() {
        schedule()
        guard assertion == .invalid else { return }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "lush.sync") {
            assertionWork?.cancel()
            assertionWork = nil
            assertionToken = nil
            endAssertion()
        }
        let token = UUID()
        assertionToken = token
        let work = Task { @MainActor in
            await NotesModel.shared.syncNow(budget: .seconds(15))
            guard !Task.isCancelled else { return }
            await NotesModel.shared.checkSmartNotebooks()
            guard assertionToken == token else { return }
            assertionWork = nil
            assertionToken = nil
            endAssertion()
        }
        assertionWork = work
    }

    private static func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }

    private static func run(_ task: BGTask, budget: Duration) async {
        schedule()
        let completion = Completion(task)
        let work = Task { @MainActor in
            await NotesModel.shared.syncNow(budget: budget)
            guard !Task.isCancelled else { return }
            await NotesModel.shared.checkSmartNotebooks()
        }
        task.expirationHandler = {
            work.cancel()
            completion.finish(success: false)
        }
        await work.value
        completion.finish(success: !work.isCancelled)
    }
}
#endif
