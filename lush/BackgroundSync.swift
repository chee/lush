#if os(iOS) || os(visionOS)
import BackgroundTasks
import UIKit

@MainActor
enum BackgroundSync {
    static let refreshIdentifier = "party.chee.patchwork.lush.sync.refresh"
    static let processingIdentifier = "party.chee.patchwork.lush.sync.processing"

    private static var assertion = UIBackgroundTaskIdentifier.invalid

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
            endAssertion()
        }
        Task { @MainActor in
            await NotesModel.shared.syncNow(budget: .seconds(15))
            endAssertion()
        }
    }

    private static func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }

    private static func run(_ task: BGTask, budget: Duration) async {
        schedule()
        let work = Task { @MainActor in
            await NotesModel.shared.syncNow(budget: budget)
        }
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: !work.isCancelled)
    }
}
#endif
