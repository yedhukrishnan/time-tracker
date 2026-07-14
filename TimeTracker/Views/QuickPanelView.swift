import SwiftUI

/// Content of the Spotlight-style quick panel.
///
/// **Design principle:** the panel is the *keyboard-first command surface* — a
/// command palette. Any action on the app's live state (start, stop, pause,
/// rename, tune intervals) is reachable here by typing. The menu bar popover
/// is the mouse/glance surface; History is the data surface. The corollary:
/// anything needing more than one line of input or more than a handful of
/// rows opens a window instead of growing the panel — `/history` opens the
/// History window rather than re-implementing it here.
///
/// Interaction grammar:
/// - Bare text ⏎ starts a session — and *switches task* if one is running
///   (the old session is stopped without wrap-up; annotate it later in History).
/// - `/` enters command mode: a filtered suggestion list appears (↑/↓ select,
///   tab completes, ⏎ runs). Commands: /start /stop /pause /resume /edit
///   /nudge N /check N /history /settings, with single-letter aliases.
/// - `/stop` flows into an inline wrap-up: summary ⏎ → rating (keys 1–5).
///   Both steps are skippable (esc) — a forced modal breeds resentment; the
///   entry stays editable in History.
/// - Esc backs out one level: clear text → close panel; edit → cancel;
///   wrap-up → skip.
struct QuickPanelView: View {
    @Environment(AppModel.self) private var model
    var onDismiss: () -> Void

    private enum Mode: Equatable {
        case command       // idle or running: type an agenda or a /command
        case editAgenda    // renaming the running session (`/edit`)
        case wrapSummary   // session just stopped: capture achievement
        case wrapRating    // ... then capture a 1–5 rating

        var wantsFieldFocus: Bool { self != .wrapRating }
    }

    @State private var mode: Mode = .command
    @State private var text = ""
    @State private var selection = 0          // index into `suggestions`
    @State private var errorText: String?
    @State private var stopped: TimeEntry?    // entry being wrapped up
    @State private var pendingRating: Int?    // previewed in the rating step; saved on ⏎
    @FocusState private var fieldFocused: Bool

    // MARK: - Commands

    private enum Command: String, CaseIterable, Identifiable {
        case start, stop, pause, resume, edit, nudge, check, history, settings

        var id: String { rawValue }

        var alias: String? {
            switch self {
            // "s" is context-dependent: start when idle, stop when running.
            // Safe because aliases resolve against `availableCommands`, and
            // the two states never offer both.
            case .start:   "s"
            case .stop:    "s"
            case .pause:   "p"
            case .resume:  "r"
            case .edit:    "e"
            case .nudge:   "n"
            case .check:   "c"
            // The window-openers have no aliases — they're not in the hot
            // path, and prefix matching ("/h", "/se") reaches them anyway.
            case .history: nil
            case .settings: nil
            }
        }

        var argHint: String? {
            switch self {
            case .start:         "agenda"
            case .nudge, .check: "minutes"
            default:             nil
            }
        }

        var help: String {
            switch self {
            case .start:   "Start a session"
            case .stop:    "Stop, then wrap up"
            case .pause:   "Pause the session"
            case .resume:  "Resume the session"
            case .edit:    "Edit the session name"
            case .nudge:   "Set idle-nudge interval"
            case .check:   "Set check-in interval"
            case .history: "Open the History window"
            case .settings: "Open Settings"
            }
        }
    }

    /// Commands that make sense in the current tracking state. Pause/resume
    /// are mutually exclusive, so only the applicable one is offered.
    private var availableCommands: [Command] {
        if model.tracking.isTracking {
            let pauseOrResume: Command = model.tracking.isPaused ? .resume : .pause
            return [.stop, pauseOrResume, .edit, .nudge, .check, .history, .settings]
        } else {
            return [.start, .nudge, .check, .history, .settings]
        }
    }

    /// Prefix-filtered suggestions, shown while the input starts with "/".
    private var suggestions: [Command] {
        guard mode == .command, text.hasPrefix("/") else { return [] }
        let head = commandHead
        guard !head.isEmpty else { return availableCommands }
        return availableCommands.filter {
            $0.rawValue.hasPrefix(head) || ($0.alias?.hasPrefix(head) ?? false)
        }
    }

    private var clampedSelection: Int {
        suggestions.isEmpty ? 0 : min(selection, suggestions.count - 1)
    }

    private var selectedSuggestion: Command? {
        suggestions.isEmpty ? nil : suggestions[clampedSelection]
    }

    /// First token after "/", lowercased ("/nu 5" → "nu").
    private var commandHead: String {
        let body = text.dropFirst()
        return (body.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "").lowercased()
    }

    /// Everything after the first token, trimmed ("/nudge 5" → "5").
    private var commandArg: String {
        let body = text.dropFirst()
        let parts = body.split(separator: " ", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch mode {
            case .command:     commandContent
            case .editAgenda:  editContent
            case .wrapSummary: wrapSummaryContent
            case .wrapRating:  wrapRatingContent
            }
        }
        .padding(16)
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .onExitCommand(perform: handleEscape)
        // Esc, focus-free: .onExitCommand only fires when a *focused* responder
        // interprets Esc into cancelOperation. In the rating step nothing has
        // focus, so also route Esc through a window-level keyboard shortcut.
        .background {
            Button("", action: handleEscape)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear {
            // Focus after the panel becomes key; setting it synchronously is a race.
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: mode) {
            DispatchQueue.main.async { fieldFocused = mode.wantsFieldFocus }
        }
        .onChange(of: text) {
            selection = 0
            errorText = nil
        }
    }

    // MARK: - Command mode

    private var commandContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.tracking.isTracking { statusRow }
            inputField(
                prompt: model.tracking.isTracking
                    ? "Switch task, or / for commands"
                    : "What are you working on?  ( / for commands )",
                onSubmit: runCommandLine
            )
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            if !suggestions.isEmpty { suggestionList }
            if model.tracking.isTracking {
                hints("↩ switch task", "/ commands", "esc close")
            } else {
                hints("↩ start", "/ commands", "esc close")
            }
        }
    }

    private var statusRow: some View {
        let paused = model.tracking.isPaused
        return HStack(spacing: 8) {
            Image(systemName: paused ? "pause.circle.fill" : "record.circle")
                .font(.title3)
                .foregroundStyle(paused ? .orange : .red)
            Text(model.statusTitle)
                .font(.title3).monospacedDigit().bold()
            if paused {
                Text("Paused").font(.caption).foregroundStyle(.secondary)
            }
            if let running = model.tracking.running, !running.agenda.isEmpty {
                Text(running.agenda)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, command in
                HStack(spacing: 8) {
                    Text("/\(command.rawValue)")
                        .font(.body.monospaced())
                    if let alias = command.alias {
                        Text("/\(alias)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    if let hint = command.argHint {
                        Text("‹\(hint)›")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(command.help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    index == clampedSelection ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
                .onTapGesture { run(command, arg: commandArg) }
            }
        }
    }

    private func runCommandLine() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Bare text: start a session (switching task if one is running).
        guard trimmed.hasPrefix("/") else {
            model.tracking.start(agenda: trimmed)
            dismissClean()
            return
        }

        // Exact name/alias match wins; otherwise fall back to the highlighted
        // suggestion, so "/nu 5" ⏎ runs /nudge 5 without spelling it out.
        let head = commandHead
        let exact = availableCommands.first { $0.rawValue == head || $0.alias == head }
        guard let command = exact ?? selectedSuggestion else {
            errorText = "Unknown command: /\(head)"
            return
        }
        run(command, arg: commandArg)
    }

    private func run(_ command: Command, arg: String) {
        switch command {
        case .start:
            guard !arg.isEmpty else { complete(command); return }
            model.tracking.start(agenda: arg)
            dismissClean()

        case .stop:
            guard let entry = model.tracking.stop() else { dismissClean(); return }
            stopped = entry
            text = ""
            mode = .wrapSummary

        case .pause:
            model.tracking.pause()
            dismissClean()

        case .resume:
            model.tracking.resume()
            dismissClean()

        case .edit:
            text = model.tracking.running?.agenda ?? ""
            mode = .editAgenda

        case .nudge, .check:
            if arg.isEmpty {
                complete(command)
            } else if let minutes = Int(arg) {
                if command == .nudge { model.setNudgeInterval(minutes: minutes) }
                else { model.setCheckInInterval(minutes: minutes) }
                dismissClean()
            } else {
                errorText = "/\(command.rawValue) takes minutes, e.g. /\(command.rawValue) 15"
            }

        case .history:
            model.openHistory()
            dismissClean()

        case .settings:
            model.openSettings()
            dismissClean()
        }
    }

    /// Fill the field with the command's full form, ready for its argument.
    private func complete(_ command: Command) {
        text = "/\(command.rawValue) "
    }

    // MARK: - Edit mode (`/edit`)

    private var editContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename session").font(.caption).foregroundStyle(.secondary)
            inputField(prompt: "Session name", onSubmit: commitRename)
            hints("↩ save", "esc cancel")
        }
    }

    private func commitRename() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.tracking.rename(agenda: trimmed)
        dismissClean()
    }

    // MARK: - Wrap-up (after `/stop`)

    private var wrapSummaryContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            wrapHeader
            inputField(prompt: "What did you get done?", onSubmit: commitSummary)
            hints("↩ next: rating", "esc skip")
        }
    }

    private var wrapRatingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            wrapHeader
            HStack(spacing: 10) {
                Text("Rate it").font(.subheadline)
                // Keys/clicks only *preview* the rating (filled stars); nothing
                // is saved until ⏎, so a mistyped digit is correctable.
                StarRating(rating: $pendingRating)
                if pendingRating != nil {
                    Text("press ↩ to save")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            hints("1–5 rate", "↩ save", "esc skip")
        }
        // No field is focused here, so bare digit keys work as window-level
        // shortcuts — same hidden-button mechanism the old P/S keys used.
        .background {
            Group {
                ForEach(1...5, id: \.self) { star in
                    // Same toggle semantics as clicking a star: repeating the
                    // current value clears it.
                    Button("") { pendingRating = (pendingRating == star) ? nil : star }
                        .keyboardShortcut(KeyEquivalent(Character("\(star)")), modifiers: [])
                }
                Button("") { finishWrapUp(rating: pendingRating) }
                    .keyboardShortcut(.defaultAction)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private var wrapHeader: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
            Text(stopped.map { $0.agenda.isEmpty ? "Session" : $0.agenda } ?? "Session")
                .font(.title3).bold()
                .lineLimit(1)
            Spacer()
            Text(AppModel.format(stopped?.duration ?? 0))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func commitSummary() {
        if let entry = stopped {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                entry.achievement = trimmed
                entry.touch()
                model.persist()
            }
        }
        text = ""
        pendingRating = nil
        mode = .wrapRating
    }

    private func finishWrapUp(rating: Int?) {
        if let entry = stopped, let rating {
            entry.rating = rating
            entry.touch()
            model.persist()
        }
        stopped = nil
        pendingRating = nil
        dismissClean()
    }

    // MARK: - Shared

    private func inputField(prompt: String, onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.title2)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($fieldFocused)
                .onSubmit(onSubmit)
                // Arrow/tab keys steer the suggestion list; when it isn't
                // showing, .ignored lets the field editor keep them.
                .onKeyPress(.upArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    moveSelection(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard let command = selectedSuggestion else { return .ignored }
                    complete(command)
                    return .handled
                }
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        selection = (clampedSelection + delta + suggestions.count) % suggestions.count
    }

    /// Esc backs out one level rather than always closing (Spotlight behavior).
    private func handleEscape() {
        switch mode {
        case .command:
            if text.isEmpty { onDismiss() } else { text = "" }
        case .editAgenda:
            text = ""
            mode = .command
        case .wrapSummary, .wrapRating:
            // The session already stopped; wrap-up is skippable by design —
            // the entry can still be annotated later from History. Esc
            // discards the previewed rating; only ⏎ saves it.
            stopped = nil
            pendingRating = nil
            text = ""
            onDismiss()
        }
    }

    private func dismissClean() {
        text = ""
        mode = .command
        onDismiss()
    }

    private func hints(_ items: String...) -> some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.self) { Text($0) }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}
