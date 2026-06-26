import SwiftUI
import SwiftData
import AppKit

/// The popover hanging off the status bar item — the control surface.
/// Three states: idle (start a session), running (live timer + stop), and
/// wrap-up (reflect on the session you just stopped).
struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var context

    @State private var agenda = ""
    @State private var wrapUpEntry: TimeEntry?

    // Today's sessions, newest first.
    @Query(sort: \TimeEntry.startedAt, order: .reverse) private var allEntries: [TimeEntry]
    private var todays: [TimeEntry] {
        let cal = Calendar.current
        return allEntries.filter { cal.isDateInToday($0.startedAt) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry = wrapUpEntry {
                WrapUpForm(entry: entry) { wrapUpEntry = nil }
            } else if let running = model.tracking.running {
                runningSection(running)
                Divider()
                todaySection
                footer
            } else {
                idleSection
                Divider()
                todaySection
                footer
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: - Idle

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start a session").font(.headline)
            TextField("Agenda — what are you working on?", text: $agenda, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit(startSession)
            Button(action: startSession) {
                Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(agenda.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Running

    private func runningSection(_ entry: TimeEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "record.circle").foregroundStyle(.red)
                Text(model.statusTitle).font(.title2).monospacedDigit().bold()
                Spacer()
            }
            if !entry.agenda.isEmpty {
                Text(entry.agenda).foregroundStyle(.secondary).lineLimit(2)
            }
            Button(role: .destructive, action: stopSession) {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Today list

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Today").font(.subheadline).bold()
                Spacer()
                Text(totalToday).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            if todays.isEmpty {
                Text("No sessions yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(todays.prefix(5)) { entry in
                    HStack(spacing: 6) {
                        Text(entry.startedAt, format: .dateTime.hour().minute())
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Text(entry.agenda.isEmpty ? "—" : entry.agenda).font(.caption).lineLimit(1)
                        Spacer()
                        if let r = entry.rating {
                            Text(String(repeating: "★", count: r)).font(.caption2).foregroundStyle(.yellow)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("History") { openHistory() }
            // SettingsLink opens the Settings scene; the simultaneous gesture
            // brings the app forward so the window isn't buried behind others.
            SettingsLink { Text("Settings") }
                .simultaneousGesture(TapGesture().onEnded { activateApp() })
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    // MARK: - Window activation
    //
    // This is an LSUIElement (accessory) app, so it never becomes frontmost on
    // its own. Opening a window without activating leaves it behind other apps,
    // which looks like "nothing happened." Activate on the next runloop tick so
    // the window exists before we pull the app forward.

    private func openHistory() {
        openWindow(id: "history")
        activateApp()
    }

    private func activateApp() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Actions

    private func startSession() {
        let trimmed = agenda.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.tracking.start(agenda: trimmed)
        agenda = ""
    }

    private func stopSession() {
        if let finished = model.tracking.stop() {
            wrapUpEntry = finished
        }
    }

    private var totalToday: String {
        let total = todays.reduce(0) { $0 + $1.duration }
        return AppModel.format(total)
    }
}
