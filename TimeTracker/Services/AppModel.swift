import Foundation
import SwiftData
import Observation

/// Top-level coordinator. Owns the controllers, holds the singleton settings,
/// wires the nudge engine to live state, and exposes display helpers to the UI.
///
/// One environment object keeps the view layer simple; the services stay
/// separately testable underneath.
@MainActor
@Observable
final class AppModel {
    let context: ModelContext
    let tracking: TrackingController
    let nudge: NudgeScheduler
    let sessionMonitor: SessionMonitor
    let quickPanel: QuickPanelController
    private let notificationRouter: NotificationRouter
    private(set) var settings: AppSettings

    /// Open the History / Settings windows. The quick panel lives in an NSPanel
    /// outside any SwiftUI scene, so it can't read `\.openWindow` /
    /// `\.openSettings` itself — these closures are wired by `OpenWindowBridge`
    /// (a view inside the MenuBarExtra scene).
    var openHistory: () -> Void = {}
    var openSettings: () -> Void = {}

    init(context: ModelContext) {
        self.context = context
        self.tracking = TrackingController(context: context)
        self.nudge = NudgeScheduler()
        self.sessionMonitor = SessionMonitor()
        self.quickPanel = QuickPanelController()
        self.notificationRouter = NotificationRouter()
        self.settings = AppModel.fetchOrCreateSettings(context)
    }

    /// Call once from the app entry point.
    func bootstrap() {
        dedupeSchedules()
        seedDefaultScheduleIfNeeded()

        notificationRouter.start()   // delegate + auth, before schedulers register

        nudge.isTrackingProvider = { [weak self] in self?.tracking.isTracking ?? false }
        nudge.settingsProvider = { [weak self] in self?.settings }
        nudge.schedulesProvider = { [weak self] in self?.allSchedules() ?? [] }
        nudge.onStartRequested = { [weak self] in
            guard let self, !self.tracking.isTracking else { return }
            self.tracking.start(agenda: "")
        }

        sessionMonitor.settingsProvider = { [weak self] in self?.settings }
        sessionMonitor.runningProvider = { [weak self] in self?.tracking.running }
        sessionMonitor.isPausedProvider = { [weak self] in self?.tracking.isPaused ?? false }
        sessionMonitor.onSubtractAway = { [weak self] seconds in
            self?.tracking.subtractAway(seconds: seconds)
        }
        sessionMonitor.onStopBackdated = { [weak self] date in
            self?.tracking.stop(at: date)
        }
        sessionMonitor.onStopRequested = { [weak self] in
            self?.tracking.stop()
        }

        // Rebuild both schedules whenever tracking state changes.
        tracking.onChange = { [weak self] in
            self?.nudge.reschedule()
            self?.sessionMonitor.reschedule()
        }
        nudge.start(router: notificationRouter)
        sessionMonitor.start(router: notificationRouter)

        // Global hotkey → Spotlight-style quick panel (command palette).
        quickPanel.start(model: self)

        LoginItem.setEnabled(settings.launchAtLogin)
    }

    // MARK: - Display helpers

    /// Status bar title: live timer while tracking, otherwise empty (icon only).
    var statusTitle: String {
        guard tracking.isTracking else { return "" }
        return Self.format(tracking.elapsed)
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        // Two-digit minutes so width stays constant across the 9→10 rollover too.
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Settings persistence passthrough

    func persist() {
        do { try context.save() } catch { print("AppModel save error: \(error)") }
    }

    func setLaunchAtLogin(_ on: Bool) {
        settings.launchAtLogin = on
        LoginItem.setEnabled(on)
        persist()
    }

    // MARK: - Quick-panel commands (`/nudge N`, `/check N`)
    //
    // 0 (or negative) disables the feature; a positive value enables it and
    // sets the interval, clamped to the same ranges as the Settings steppers
    // so the two surfaces can't disagree. The interval itself is left alone
    // when disabling, so re-enabling from Settings restores the old cadence.

    func setNudgeInterval(minutes: Int) {
        if minutes <= 0 {
            settings.nudgeEnabled = false
        } else {
            settings.nudgeIntervalMinutes = max(1, min(120, minutes))
            settings.nudgeEnabled = true
        }
        persist()
        nudge.reschedule()
    }

    func setCheckInInterval(minutes: Int) {
        if minutes <= 0 {
            settings.checkInEnabled = false
        } else {
            settings.checkInIntervalMinutes = max(5, min(180, minutes))
            settings.checkInEnabled = true
        }
        persist()
        sessionMonitor.reschedule()
    }

    // MARK: - Fetching

    func allSchedules() -> [WorkSchedule] {
        (try? context.fetch(FetchDescriptor<WorkSchedule>())) ?? []
    }

    /// Fetch the singleton settings, collapsing duplicates that two offline
    /// devices may have created before CloudKit reconciled. Keep the earliest by
    /// `createdAt` — a stable key both devices agree on, so they converge — and
    /// delete the rest.
    private static func fetchOrCreateSettings(_ context: ModelContext) -> AppSettings {
        let all = (try? context.fetch(FetchDescriptor<AppSettings>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))) ?? []
        if let keep = all.first {
            for extra in all.dropFirst() { context.delete(extra) }
            if all.count > 1 { try? context.save() }
            return keep
        }
        let fresh = AppSettings()
        context.insert(fresh)
        try? context.save()
        return fresh
    }

    /// Keep a single row per weekday, deleting sync-introduced duplicates. Keep
    /// the earliest-created so both devices converge on the same survivor.
    private func dedupeSchedules() {
        let all = (try? context.fetch(FetchDescriptor<WorkSchedule>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))) ?? []
        var seen = Set<Int>()
        var changed = false
        for schedule in all {
            if seen.insert(schedule.weekday).inserted == false {
                context.delete(schedule)
                changed = true
            }
        }
        if changed { persist() }
    }

    /// Seed Mon–Fri 09:00–18:00 the first time the app runs.
    private func seedDefaultScheduleIfNeeded() {
        guard allSchedules().isEmpty else { return }
        for weekday in 2...6 {   // Calendar: 2 = Monday … 6 = Friday
            context.insert(WorkSchedule(weekday: weekday))
        }
        persist()
    }
}
