import SwiftUI
import SwiftData
import AppKit

/// Invisible view that hands the `openWindow` action to AppModel. The quick
/// panel is hosted in an NSPanel outside any SwiftUI scene, so it cannot read
/// `\.openWindow` from its own environment; the status-item label (always
/// instantiated) captures the action once and stores it on the model.
private struct OpenWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let model: AppModel

    var body: some View {
        Color.clear
            .onAppear {
                model.openHistory = {
                    // Accessory app: activate first or the window opens behind.
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "history")
                }
                model.openSettings = {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
    }
}

@main
struct TimeTrackerApp: App {
    private let container: ModelContainer
    @State private var model: AppModel

    init() {
        // Single-instance guard. Two instances (installed copy + DMG copy, or
        // login item + Xcode debug build) would share one SQLite store, and
        // Core Data dies unrecoverably when the store changes underneath it.
        // Enforce "one process per store" before the ModelContainer opens it:
        // if another instance of this bundle id is already running, yield to
        // it and quit. `exit` (not NSApp.terminate) because NSApp isn't set
        // up yet this early in init.
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first {
            existing.activate()
            exit(0)
        }

        let schema = Schema([TimeEntry.self, WorkSchedule.self, AppSettings.self])
        // `.automatic` enables CloudKit mirroring when entitlements are present,
        // and falls back to a local store otherwise (so it runs before you set
        // up an Apple Developer account / CloudKit container).
        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        let appModel = AppModel(context: container.mainContext)
        appModel.bootstrap()   // start the nudge engine, seed defaults, sync login item
        _model = State(initialValue: appModel)
    }

    var body: some Scene {
        // The status bar item. `.window` style gives us a rich popover.
        MenuBarExtra {
            MenuBarContentView()
                .environment(model)
                .modelContainer(container)
        } label: {
            // Custom monochrome crosshair (template image), explicitly sized to
            // match neighbouring menu bar icons. Show the live elapsed time as a
            // separate Text while tracking — a MenuBarExtra label drops a Label's
            // title, so the timer must be its own view.
            HStack(spacing: 4) {
                Image("MenuBarIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                if model.tracking.isTracking {
                    if model.tracking.isPaused {
                        Image(systemName: "pause.fill").font(.system(size: 10))
                    }
                    // Monospaced font for the numeric timer. (The menu bar item can
                    // still reflow as overall width changes — known cosmetic issue.)
                    Text(model.statusTitle)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                }
            }
            // The label is the only SwiftUI view guaranteed to exist for the
            // app's whole lifetime, so it hosts the openWindow bridge.
            .background(OpenWindowBridge(model: model))
        }
        .menuBarExtraStyle(.window)

        // Full data-surface window, opened on demand from the popover.
        Window("History", id: "history") {
            HistoryView()
                .environment(model)
                .modelContainer(container)
                .frame(minWidth: 520, minHeight: 420)
        }
        .windowResizability(.contentSize)

        // Standard Settings scene (⌘, and the popover's Settings button).
        Settings {
            SettingsView()
                .environment(model)
                .modelContainer(container)
        }
    }
}
