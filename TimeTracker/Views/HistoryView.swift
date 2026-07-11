import SwiftUI
import SwiftData

/// The data surface — review and edit past sessions. Grouped by day, newest
/// first, with per-day totals. Everything is editable after the fact (the
/// mutability decision): click a card to edit, hover or right-click to delete.
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

    /// True when filters are hiding entries that do exist.
    private var isFiltering: Bool { minRating > 0 || !searchText.isEmpty }

    var body: some View {
        Group {
            if grouped.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // The filter bar floats above the scroll content on a material, so
        // cards visibly slide beneath it — cheap depth without extra chrome.
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
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

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            searchField
            Spacer()
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            ratingFilter
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search sessions", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.05)))
        .frame(maxWidth: 240)
    }

    private var ratingFilter: some View {
        Menu {
            Picker("Minimum rating", selection: $minRating) {
                Text("Any rating").tag(0)
                ForEach(1...5, id: \.self) { n in
                    Text("\(String(repeating: "★", count: n))\(n < 5 ? " and up" : "")").tag(n)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: minRating > 0 ? "star.fill" : "line.3.horizontal.decrease")
                    .font(.system(size: 11))
                if minRating > 0 {
                    Text("\(minRating)+").font(.caption.weight(.medium))
                }
            }
            .foregroundStyle(minRating > 0 ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Filter by minimum rating")
    }

    /// "12 sessions · 8h 34m" for whatever the filters currently show.
    private var summary: String {
        let total = filtered.reduce(0) { $0 + $1.duration }
        let noun = filtered.count == 1 ? "session" : "sessions"
        return "\(filtered.count) \(noun) · \(AppModel.format(total))"
    }

    // MARK: - Session list

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(grouped, id: \.day) { group in
                    Section {
                        VStack(spacing: 6) {
                            ForEach(group.items) { entry in
                                SessionRow(entry: entry,
                                           onEdit: { editing = entry },
                                           onDelete: { pendingDelete = entry })
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                        .padding(.bottom, 18)
                    } header: {
                        dayHeader(day: group.day, items: group.items)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func dayHeader(day: Date, items: [TimeEntry]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(dayLabel(day))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(dayTotal(items))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)   // stays legible while cards scroll underneath
    }

    /// "Today" / "Yesterday" for recency, otherwise the full date (with year
    /// only when it isn't this year's).
    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = cal.component(.year, from: day) == cal.component(.year, from: .now)
        let style: Date.FormatStyle = sameYear
            ? .dateTime.weekday(.wide).month().day()
            : .dateTime.weekday(.wide).month().day().year()
        return day.formatted(style)
    }

    private func dayTotal(_ items: [TimeEntry]) -> String {
        AppModel.format(items.reduce(0) { $0 + $1.duration })
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Group {
            if isFiltering {
                ContentUnavailableView {
                    Label("No matching sessions", systemImage: "magnifyingglass")
                } description: {
                    Text("Try a different search or rating filter.")
                } actions: {
                    Button("Clear Filters") { searchText = ""; minRating = 0 }
                }
            } else {
                ContentUnavailableView("No sessions yet", systemImage: "clock",
                                       description: Text("Tracked sessions will appear here."))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func performDelete(_ entry: TimeEntry) {
        context.delete(entry)
        try? context.save()
        pendingDelete = nil
    }
}

// MARK: - Session row

/// One session as a quiet card: agenda leads, achievement and time range
/// support, duration sits in a capsule on the right. Hover raises the card
/// slightly and reveals a delete affordance (swipe-to-delete doesn't exist
/// outside List, so hover + context menu cover deletion).
private struct SessionRow: View {
    let entry: TimeEntry
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.agenda.isEmpty ? "Untitled session" : entry.agenda)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let a = entry.achievement, !a.isEmpty {
                    Text(a)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(timeRange)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                Text(AppModel.format(entry.duration))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                if let r = entry.rating {
                    HStack(spacing: 1.5) {
                        ForEach(0..<r, id: \.self) { _ in
                            Image(systemName: "star.fill")
                        }
                    }
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                }
            }
            if hovering {
                DeleteButton(action: onDelete)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.075 : 0.04)))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture(perform: onEdit)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }

    /// Hover-revealed delete affordance. The icon stays small, but the hit
    /// target is a full 24×24pt circle that highlights on its own hover so
    /// it's both easy to aim at and clearly separate from tap-to-edit.
    private struct DeleteButton: View {
        var action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Delete session")
        }
    }

    private var timeRange: String {
        let f = Date.FormatStyle.dateTime.hour().minute()
        let start = entry.startedAt.formatted(f)
        let end = entry.endedAt?.formatted(f) ?? "…"
        return "\(start) – \(end)"
    }
}
