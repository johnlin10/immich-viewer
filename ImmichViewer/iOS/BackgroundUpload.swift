#if os(iOS)
import BackgroundTasks
import Foundation
import os

/// Keeps an upload going after the app is left (BGContinuedProcessingTask): the system shows its title and progress,
/// and its stop button cancels the upload. If the system refuses the task, the upload just runs in the foreground only.
final class BackgroundUpload: @unchecked Sendable {
    private let lock = NSLock() // the launch handler and KVO run on any queue
    private var task: BGContinuedProcessingTask?
    private var finished: Bool?  // set by finish(success:): the result, for a task that only arrives later
    private var count: Int
    private var step = 1
    private var observation: NSKeyValueObservation?
    private var heartbeat: Timer?
    /// The system ended it (its stop button, or it judged the task stuck) rather than the upload finishing or Cancel.
    private(set) var expired = false
    /// Units of the task's progress: fine enough that every few bytes sent move it.
    private static let units: Int64 = 1_000_000
    private static let title = String(localized: "Uploading to Immich")

    static func start(progress: Progress, count: Int) -> BackgroundUpload {
        let background = BackgroundUpload(count: count)
        let id = "\(Bundle.main.bundleIdentifier!).upload.\(UUID().uuidString)"
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            background.attach(task, progress: progress)
        }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: background.subtitle(1))
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch {
            Logger(subsystem: "local.ImmichViewer", category: "upload").error("background upload refused: \(error)")
        }
        // the system wants progress at a steady cadence, or it takes the task for stuck and ends it ("Task Failed"):
        // the bytes sent move it finely, and while an item sends none (copied out of Photos, downloaded from iCloud)
        // a beat every few seconds moves it by a unit, too little to see
        background.observation = progress.observe(\.fractionCompleted) { progress, _ in
            background.report(progress.fractionCompleted)
        }
        background.heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in background.beat() }
        return background
    }

    private init(count: Int) { self.count = count }

    private func subtitle(_ step: Int) -> String { String(localized: "\(step) of \(count)") }

    private func attach(_ task: BGContinuedProcessingTask, progress: Progress) {
        task.progress.totalUnitCount = Self.units
        task.expirationHandler = { [weak self] in // also its stop button
            self?.lock.withLock { self?.expired = true }
            Task { @MainActor in progress.cancel() }
        }
        lock.lock()
        defer { lock.unlock() }
        if let finished { task.setTaskCompleted(success: finished); return }
        self.task = task
        task.progress.completedUnitCount = Int64(progress.fractionCompleted * Double(Self.units))
        task.updateTitle(Self.title, subtitle: subtitle(step))
    }

    private func report(_ fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let task else { return }
        task.progress.completedUnitCount = max(task.progress.completedUnitCount, Int64(fraction * Double(Self.units)))
        lastReport = .now
    }

    private var lastReport = Date.now

    private func beat() {
        lock.lock()
        defer { lock.unlock() }
        guard let task, Date.now.timeIntervalSince(lastReport) >= 4,
              task.progress.completedUnitCount < Self.units - 1 else { return }
        task.progress.completedUnitCount += 1
        lastReport = .now
    }

    /// The item it is on, from 1.
    func step(_ n: Int) {
        lock.lock()
        defer { lock.unlock() }
        step = n
        task?.updateTitle(Self.title, subtitle: subtitle(n))
    }

    func finish(success: Bool) {
        observation = nil
        heartbeat?.invalidate()
        lock.lock()
        defer { lock.unlock() }
        finished = success
        task?.setTaskCompleted(success: success)
        task = nil
    }
}
#endif
