import SwiftUI
import SwiftData

/// The data surface — review and edit past sessions. Grouped by day, newest
/// first, with per-day totals. Everything is editable after the fact (the
/// mutability decision): tap a row to edit, or delete.
struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TimeEntry.startedAt, order: .reverse) private var entries: [TimeEntry]

    @State private var editing: TimeEntry?
    @State private var pendingDelete: TimeEntry?   // set when a delete is awaiting confirmation
    @State private var minRating: Int = 0          // 0 = any
    @State private var searchText: String = ""

    private var filtered: [TimeEntry] {
        entries.filter { e in
            guard e.endedAt != nil else { return false }            // hide the running session
            if minRating > 0, (e.rating ?? 0) < minRating { return false }
            if !searchText.isEmpty {
                let hay = (e.agenda + " " + (e.achievement ?? "")).lowercased()
                if !hay.contains(searchText.lowercased()) { return false }
            }
            return true
        }
    }

    /// (day, sessions) pairs, newest day first.
    private var grouped: [(day: Date, items: [TimeEntry])] {
        let cal = Calendar.current
        let buckets = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.startedAt) }
        return buckets.keys.sorted(by: >).map { ($0, buckets[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if grouped.isEmpty {
                ContentUnavailableView("No sessions", systemImage: "clock",
                                       description: Text("Tracked sessions will appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(grouped, id: \.day) { group in
                        Section {
                            ForEach(group.items) { entry in
                                row(entry).contentShape(Rectangle())
                                    .onTapGesture { editing = entry }
                                    .contextMenu {
                                        Button("Edit…") { editing = entry }
                                        Button("Delete…", role: .destructive) { pendingDelete = entry }
                                    }
                            }
                            // Swipe-to-delete routes through confirmation rather than
                            // deleting immediately.
                            .onDelete { offsets in
                                if let i = offsets.first { pendingDelete = group.items[i] }
                            }
                        } header: {
                            HStack {
                                Text(group.day, format: .dateTime.weekday(.wide).month().day())
                                Spacer()
                                Text(dayTotal(group.items)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { entry in
            WrapUpForm(entry: entry, isEditing: true) { editing = nil }
        }
        .alert("Delete session?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { entry in
            Button("Delete", role: .destructive) { performDelete(entry) }
            Button("Cancel", role: .cancel) { }
        } message: { entry in
            Text("“\(entry.agenda.isEmpty ? "This session" : entry.agenda)” will be permanently deleted. This can't be undone.")
        }
    }

    private var toolbar: some View {
        HStack {
            TextField("Search agenda or achievement", text: $searchText)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            Spacer()
            Picker("Min rating", selection: $minRating) {
                Text("Any").tag(0)
                ForEach(1...5, id: \.self) { Text("★ \($0)+").tag($0) }
            }
            .pickerStyle(.menu).fixedSize()
        }
        .padding(10)
    }

    private func row(_ entry: TimeEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeRange(entry)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Text(entry.agenda.isEmpty ? "—" : entry.agenda).font(.body).lineLimit(1)
                if let a = entry.achievement, !a.isEmpty {
                    Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(AppModel.format(entry.duration)).font(.caption).monospacedDigit()
                if let r = entry.rating {
                    Text(String(repeating: "★", count: r)).font(.caption).foregroundStyle(.yellow)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func timeRange(_ e: TimeEntry) -> String {
        let f = Date.FormatStyle.dateTime.hour().minute()
        let start = e.startedAt.formatted(f)
        let end = e.endedAt?.formatted(f) ?? "…"
        return "\(start)–\(end)"
    }

    private func dayTotal(_ items: [TimeEntry]) -> String {
        AppModel.format(items.reduce(0) { $0 + $1.duration })
    }

    private func performDelete(_ entry: TimeEntry) {
        context.delete(entry)
        try? context.save()
        pendingDelete = nil
    }
}
