import SwiftUI
import SwiftData
import AppKit

/// Settings: work hours, the nudge, general options, and about.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkSchedule.weekday) private var schedules: [WorkSchedule]

    var body: some View {
        TabView {
            workHoursTab.tabItem { Label("Work Hours", systemImage: "calendar") }
            nudgeTab.tabItem { Label("Nudge", systemImage: "bell") }
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 360)
        .onAppear(perform: ensureAllWeekdaysExist)
    }

    // MARK: - Work hours

    private var workHoursTab: some View {
        Form {
            Text("Nudges only fire during enabled windows.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(orderedSchedules) { schedule in
                WeekdayRow(schedule: schedule, onChange: save)
            }
        }
        .formStyle(.grouped)
    }

    // Mon-first ordering for display (Calendar is Sun-first).
    private var orderedSchedules: [WorkSchedule] {
        let order = [2, 3, 4, 5, 6, 7, 1] // Mon…Sun
        return order.compactMap { wd in schedules.first { $0.weekday == wd } }
    }

    // MARK: - Nudge

    private var nudgeTab: some View {
        @Bindable var settings = model.settings
        return Form {
            Toggle("Enable nudges", isOn: $settings.nudgeEnabled)
                .onChange(of: settings.nudgeEnabled) { save() }

            Stepper(value: $settings.nudgeIntervalMinutes, in: 1...120, step: 1) {
                Text("Every \(settings.nudgeIntervalMinutes) min")
            }
            .onChange(of: settings.nudgeIntervalMinutes) { save() }
            .disabled(!settings.nudgeEnabled)

            VStack(alignment: .leading, spacing: 4) {
                Text("Message")
                TextField("Reminder text", text: $settings.nudgeMessage, axis: .vertical)
                    .lineLimit(2...4)
                    .onChange(of: settings.nudgeMessage) { save() }
            }
            .disabled(!settings.nudgeEnabled)
        }
        .formStyle(.grouped)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(
                get: { model.settings.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Text("Keeps the app running so nudges fire when your day starts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: - About

    private var aboutTab: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Time Tracker").font(.headline)
                        Text("Version \(appVersion)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("A native macOS menu bar time tracker.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Developer") {
                LabeledContent("Name", value: "Yedhu Krishnan")
                LabeledContent("Email") {
                    Link("dev@yedhu.me", destination: URL(string: "mailto:dev@yedhu.me")!)
                }
            }
            Section {
                Text("© 2026 Yedhu Krishnan")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    // MARK: - Helpers

    private func save() {
        do { try context.save() } catch { print("Settings save error: \(error)") }
    }

    /// Make sure a row exists for all 7 weekdays so the UI can bind directly.
    /// Days not seeded by default (Sat/Sun) are created disabled.
    private func ensureAllWeekdaysExist() {
        let present = Set(schedules.map(\.weekday))
        for wd in 1...7 where !present.contains(wd) {
            context.insert(WorkSchedule(weekday: wd, isEnabled: false))
        }
        save()
    }
}

/// One editable weekday row.
private struct WeekdayRow: View {
    @Bindable var schedule: WorkSchedule
    var onChange: () -> Void

    var body: some View {
        HStack {
            Toggle(weekdayName, isOn: $schedule.isEnabled)
                .toggleStyle(.switch)
                .frame(width: 130, alignment: .leading)
                .onChange(of: schedule.isEnabled) { onChange() }

            Spacer()

            DatePicker("", selection: minutesBinding(\.startMinutes), displayedComponents: .hourAndMinute)
                .labelsHidden().disabled(!schedule.isEnabled)
            Text("to").foregroundStyle(.secondary)
            DatePicker("", selection: minutesBinding(\.endMinutes), displayedComponents: .hourAndMinute)
                .labelsHidden().disabled(!schedule.isEnabled)
        }
    }

    private var weekdayName: String {
        Calendar.current.weekdaySymbols[schedule.weekday - 1]
    }

    /// Bridge an Int minutes-from-midnight property to a `Date` for DatePicker.
    private func minutesBinding(_ keyPath: ReferenceWritableKeyPath<WorkSchedule, Int>) -> Binding<Date> {
        Binding(
            get: {
                let mins = schedule[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: mins / 60, minute: mins % 60, second: 0, of: Date()) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                schedule[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                onChange()
            }
        )
    }
}
