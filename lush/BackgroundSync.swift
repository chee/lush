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

    /// Whether the process still has permission to work: frontmost, or
    /// holding a background assertion, or inside a BGTask. Everywhere else,
    /// iOS can suspend us at any moment — and a suspended process still
    /// reading and fsyncing inside its data container is one RunningBoard
    /// kills outright (`0xdead10cc`). The core parks its opportunistic work
    /// while this is false and picks it back up when it flips.
    ///
    /// Starts parked. A BGTask can launch the process straight into the
    /// background, where neither `didEnterBackground` nor `willEnterForeground`
    /// ever arrives; assuming frontmost would leave the core working through
    /// exactly the suspension this is meant to prevent. Nothing is lost by
    /// starting false — `syncCoreActivity` is a no-op until a core exists, and
    /// `applyCoreActivity` reads the real state the moment one does.
    private static var foreground = false
    private static var backgroundHolds = 0

    /// Push the current state onto a core that was built after the app had
    /// already moved, and so never saw the transition. Reads the application
    /// state rather than trusting the flag: on a background launch no
    /// transition notification was ever posted for the flag to have seen.
    static func applyCoreActivity() {
        foreground = UIApplication.shared.applicationState != .background
        syncCoreActivity()
    }

    private static func syncCoreActivity() {
        let active = foreground || backgroundHolds > 0
        NotesModel.shared.core?.setAppActive(active: active)
        NotesModel.shared.setBackfillActive(active)
    }

    private static func beginBackgroundHold() {
        backgroundHolds += 1
        syncCoreActivity()
    }

    private static func endBackgroundHold() {
        backgroundHolds = max(0, backgroundHolds - 1)
        syncCoreActivity()
    }

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
        foreground = false
        schedule()
        guard assertion == .invalid else {
            syncCoreActivity()
            // The foreground interlude's edits are still behind the save
            // debounce, and the stint already running would park the core
            // without ever writing them. Restart the work under the assertion
            // already held rather than taking a second one.
            startAssertionWork()
            return
        }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "lush.sync") {
            assertionWork?.cancel()
            assertionWork = nil
            assertionToken = nil
            endAssertion()
        }
        // Pair the hold with a real assertion: `endAssertion` is the only
        // release, and it no-ops when there was never one to end. Without an
        // assertion there is no background time to protect anyway — the flush
        // below is still worth starting, it just has to win a race.
        if assertion != .invalid {
            beginBackgroundHold()
        } else {
            syncCoreActivity()
        }
        startAssertionWork()
    }

    /// One round at a time: the round in flight is cancelled and awaited
    /// before the new one starts, so two `syncNow`s never overlap, and only
    /// the newest token is allowed to park the core.
    private static func startAssertionWork() {
        let previous = assertionWork
        previous?.cancel()
        let token = UUID()
        assertionToken = token
        assertionWork = Task { @MainActor in
            if let previous { await previous.value }
            // Durability first, and before the cancellation check: syncing is
            // work we can lose and pick up next launch, but an edit still held
            // by a debounce exists only in this process, and the system can
            // kill it while suspended without ever sending `willTerminate`.
            await NotesModel.shared.flushPendingWrites()
            guard !Task.isCancelled else { return }
            await NotesModel.shared.syncNow(budget: .seconds(15))
            guard !Task.isCancelled else { return }
            await NotesModel.shared.checkSmartNotebooks()
            guard assertionToken == token else { return }
            assertionWork = nil
            assertionToken = nil
            endAssertion()
        }
    }

    static func willEnterForeground() {
        foreground = true
        syncCoreActivity()
    }

    private static func endAssertion() {
        guard assertion != .invalid else { return }
        // park the core before giving the assertion back, not after: the
        // moment `endBackgroundTask` returns the process can be suspended,
        // and a core still reading and fsyncing through that is the one
        // RunningBoard kills (`0xdead10cc`)
        endBackgroundHold()
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }

    private static func run(_ task: BGTask, budget: Duration) async {
        schedule()
        // A BGTask is permission to run, so the core is allowed to work for
        // as long as it lasts — a background launch reaches this before the
        // prefetch walk has settled, and `checkSmartNotebooks` waits on it.
        beginBackgroundHold()
        defer { endBackgroundHold() }
        let completion = Completion(task)
        let work = Task { @MainActor in
            await NotesModel.shared.flushPendingWrites()
            guard !Task.isCancelled else { return }
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
