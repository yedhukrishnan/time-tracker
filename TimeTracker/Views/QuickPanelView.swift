import SwiftUI

/// Content of the Spotlight-style quick panel. Context-aware:
/// - Idle: type an agenda, ↩ starts an open-ended session.
/// - Running: live timer with Pause/Resume (P) and Stop (S).
/// Esc dismisses in both states (see `.onExitCommand`; click-outside is
/// handled by the panel controller via resign-key).
///
/// Deliberately minimal — anything beyond the 2-second start/pause/stop
/// actions belongs in the menu bar popover, not here.
struct QuickPanelView: View {
    @Environment(AppModel.self) private var model
    var onDismiss: () -> Void

    @State private var agenda = ""
    @FocusState private var agendaFocused: Bool

    var body: some View {
        Group {
            if model.tracking.isTracking {
                runningContent
            } else {
                idleContent
            }
        }
        .padding(16)
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .onExitCommand(perform: onDismiss)
        // Esc, focus-free: .onExitCommand only fires when a *focused* responder
        // (like the idle text field) interprets Esc into cancelOperation. In the
        // running state nothing has focus, so route Esc through a window-level
        // keyboard shortcut instead — same mechanism as the P/S keys.
        .background {
            Button("", action: onDismiss)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Idle: start a session

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                TextField("What are you working on?", text: $agenda)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($agendaFocused)
                    .onSubmit(start)
            }
            hints("↩ start", "esc dismiss")
        }
        .onAppear {
            // Focus after the panel becomes key; setting it synchronously is a race.
            DispatchQueue.main.async { agendaFocused = true }
        }
    }

    private func start() {
        let trimmed = agenda.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.tracking.start(agenda: trimmed)
        agenda = ""
        onDismiss()
    }

    // MARK: - Running: status + pause/stop

    private var runningContent: some View {
        let paused = model.tracking.isPaused
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: paused ? "pause.circle.fill" : "record.circle")
                    .font(.title2)
                    .foregroundStyle(paused ? .orange : .red)
                Text(model.statusTitle)
                    .font(.title2).monospacedDigit().bold()
                if paused {
                    Text("Paused").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let running = model.tracking.running, !running.agenda.isEmpty {
                Text(running.agenda)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            hints("P \(paused ? "resume" : "pause")", "S stop", "esc dismiss")
        }
        // Keyboard-only actions: zero-size hidden buttons carry the shortcuts.
        // SwiftUI resolves .keyboardShortcut at the key-window level, so this
        // works without any view needing focus — more reliable than .onKeyPress,
        // which only fires on a *focused* view.
        .background {
            Group {
                Button("", action: togglePause).keyboardShortcut("p", modifiers: [])
                Button("", action: stop).keyboardShortcut("s", modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private func togglePause() {
        if model.tracking.isPaused { model.tracking.resume() }
        else { model.tracking.pause() }
    }

    /// Stop without the wrap-up form — the panel stays lightweight. The entry
    /// can be rated / annotated later from History.
    private func stop() {
        model.tracking.stop()
        onDismiss()
    }

    // MARK: - Shared

    private func hints(_ items: String...) -> some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.self) { Text($0) }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}
