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
        // the system wants steady progress, or it takes the task for stuck
        background.observation = progress.observe(\.fractionCompleted) { progress, _ in
            background.report(progress.fractionCompleted)
        }
        return background
    }

    private init(count: Int) { self.count = count }

    private func subtitle(_ step: Int) -> String { String(localized: "\(step) of \(count)") }

    private func attach(_ task: BGContinuedProcessingTask, progress: Progress) {
        task.progress.totalUnitCount = 1000
        task.expirationHandler = { Task { @MainActor in progress.cancel() } } // also its stop button
        lock.lock()
        defer { lock.unlock() }
        if let finished { task.setTaskCompleted(success: finished); return }
        self.task = task
        task.progress.completedUnitCount = Int64(progress.fractionCompleted * 1000)
        task.updateTitle(Self.title, subtitle: subtitle(step))
    }

    private func report(_ fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        task?.progress.completedUnitCount = Int64(fraction * 1000)
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
        lock.lock()
        defer { lock.unlock() }
        finished = success
        task?.setTaskCompleted(success: success)
        task = nil
    }
}
#endif
