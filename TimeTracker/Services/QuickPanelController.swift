import AppKit
import SwiftUI
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global hotkey for the quick panel. ⌘⇧Return by default; customizable in
    /// Settings → General via `KeyboardShortcuts.Recorder`.
    static let toggleQuickPanel = Self(
        "toggleQuickPanel",
        default: .init(.return, modifiers: [.command, .shift])
    )
}

/// Owns the Spotlight-style quick panel: a borderless, non-activating floating
/// panel summoned by a global hotkey from any app.
///
/// Non-activating matters: the panel takes *key* status (so it receives
/// typing) without activating the app, so the user's current app keeps focus
/// visually and gets it back the instant the panel closes.
@MainActor
final class QuickPanelController: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var panel: NSPanel?

    /// Call once from `AppModel.bootstrap`.
    func start(model: AppModel) {
        self.model = model
        KeyboardShortcuts.onKeyDown(for: .toggleQuickPanel) { [weak self] in
            self?.toggle()
        }
    }

    func toggle() {
        if let panel, panel.isVisible { hide() } else { show() }
    }

    func show() {
        guard let model else { return }
        // Rebuild each time: the content's height differs between idle and
        // running states, and rebuilding sizes the panel to the current state.
        hide()
        let panel = makePanel(model: model)
        self.panel = panel
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        panel.delegate = nil          // avoid resign-key re-entrancy during teardown
        panel.orderOut(nil)
        self.panel = nil
    }

    /// Click-outside (or any other key-window change) dismisses, like Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - Construction

    private func makePanel(model: AppModel) -> NSPanel {
        let content = QuickPanelView(onDismiss: { [weak self] in self?.hide() })
            .environment(model)
        let hosting = NSHostingView(rootView: content)

        let panel = KeyablePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.isOpaque = false
        panel.backgroundColor = .clear      // SwiftUI material provides the chrome
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false     // we're an accessory app; never "active"
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        return panel
    }

    /// Center horizontally, upper third of the screen — where Spotlight sits.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        let x = vf.midX - size.width / 2
        let y = vf.minY + vf.height * 0.7 - size.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Borderless windows refuse key status by default; the panel needs it so the
/// agenda field (and single-key shortcuts) receive typing.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
