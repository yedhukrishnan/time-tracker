import SwiftUI

/// Capture or edit a session's fields. Two modes:
///   - quick wrap-up (default): just the reflective fields — achievement + rating —
///     shown inline in the popover right after stopping (compact).
///   - full edit (`isEditing: true`): a grouped form that also edits the agenda and
///     the start/end times, used as a sheet in History.
///
/// Edits are buffered in local state and only written back on Save, so Cancel/Skip
/// leaves the entry untouched.
struct WrapUpForm: View {
    let entry: TimeEntry
    var isEditing: Bool = false
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @State private var agenda: String
    @State private var achievement: String
    @State private var rating: Int?
    @State private var startedAt: Date
    @State private var endedAt: Date

    init(entry: TimeEntry, isEditing: Bool = false, onDone: @escaping () -> Void) {
        self.entry = entry
        self.isEditing = isEditing
        self.onDone = onDone
        _agenda = State(initialValue: entry.agenda)
        _achievement = State(initialValue: entry.achievement ?? "")
        _rating = State(initialValue: entry.rating)
        _startedAt = State(initialValue: entry.startedAt)
        _endedAt = State(initialValue: entry.endedAt ?? .now)
    }

    var body: some View {
        if isEditing { editLayout } else { quickLayout }
    }

    // MARK: - Full edit (History sheet)

    private var editLayout: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit session").font(.headline)
                Spacer()
                Text(AppModel.format(previewDuration))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section("Agenda") {
                    TextField("What were you working on?", text: $agenda, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section("Time") {
                    DatePicker("Start", selection: $startedAt,
                               displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: $endedAt, in: startedAt...,
                               displayedComponents: [.date, .hourAndMinute])
                }
                Section("Reflection") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What did you get done?")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $achievement)
                            .frame(minHeight: 72)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }
                    LabeledContent("Rating") { StarRating(rating: $rating) }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onDone)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 540)
    }

    // MARK: - Quick wrap-up (popover)

    private var quickLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(headerTitle).font(.headline).lineLimit(1)
                Spacer()
                Text(AppModel.format(previewDuration))
                    .foregroundStyle(.secondary).monospacedDigit()
            }

            Text("What did you get done?").font(.subheadline)
            TextEditor(text: $achievement)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Text("Rating").font(.subheadline)
                StarRating(rating: $rating)
                Spacer()
            }

            HStack {
                Spacer()
                Button("Skip", role: .cancel, action: onDone)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 320)
    }

    // MARK: - Helpers

    private var headerTitle: String {
        entry.agenda.isEmpty ? "Session" : entry.agenda
    }

    /// Live duration preview while editing times; the saved value otherwise.
    private var previewDuration: TimeInterval {
        guard isEditing else { return entry.duration }
        return max(0, endedAt.timeIntervalSince(startedAt) - entry.pausedSeconds)
    }

    private func save() {
        if isEditing {
            entry.agenda = agenda.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.startedAt = startedAt
            entry.endedAt = max(endedAt, startedAt)   // never end before start
        }
        entry.achievement = achievement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : achievement
        entry.rating = rating
        entry.touch()
        try? context.save()
        onDone()
    }
}
