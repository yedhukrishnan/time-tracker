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
    private(set) var settings: AppSettings

    init(context: ModelContext) {
        self.context = context
        self.tracking = TrackingController(context: context)
        self.nudge = NudgeScheduler()
        self.settings = AppModel.fetchOrCreateSettings(context)
    }

    /// Call once from the app entry point.
    func bootstrap() {
        seedDefaultScheduleIfNeeded()

        nudge.isTrackingProvider = { [weak self] in self?.tracking.isTracking ?? false }
        nudge.settingsProvider = { [weak self] in self?.settings }
        nudge.schedulesProvider = { [weak self] in self?.allSchedules() ?? [] }
        nudge.onStartRequested = { [weak self] in
            guard let self, !self.tracking.isTracking else { return }
            self.tracking.start(agenda: "")
        }
        nudge.start()

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

    // MARK: - Fetching

    func allSchedules() -> [WorkSchedule] {
        (try? context.fetch(FetchDescriptor<WorkSchedule>())) ?? []
    }

    private static func fetchOrCreateSettings(_ context: ModelContext) -> AppSettings {
        if let existing = try? context.fetch(FetchDescriptor<AppSettings>()).first {
            return existing
        }
        let fresh = AppSettings()
        context.insert(fresh)
        try? context.save()
        return fresh
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
