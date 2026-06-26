import SwiftUI

/// Capture/edit the reflective fields of a session: what you achieved + a rating.
///
/// Used in two places: inline in the popover right after stopping, and as a sheet
/// in History for editing a past session. Edits are buffered locally and only
/// written back on Save, so Cancel/Skip leaves the entry untouched.
struct WrapUpForm: View {
    let entry: TimeEntry
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @State private var achievement: String
    @State private var rating: Int?

    init(entry: TimeEntry, onDone: @escaping () -> Void) {
        self.entry = entry
        self.onDone = onDone
        _achievement = State(initialValue: entry.achievement ?? "")
        _rating = State(initialValue: entry.rating)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.agenda.isEmpty ? "Session" : entry.agenda)
                    .font(.headline).lineLimit(1)
                Spacer()
                Text(AppModel.format(entry.duration)).foregroundStyle(.secondary).monospacedDigit()
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

    private func save() {
        entry.achievement = achievement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : achievement
        entry.rating = rating
        entry.touch()
        try? context.save()
        onDone()
    }
}
