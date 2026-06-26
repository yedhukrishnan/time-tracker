import SwiftUI
import SwiftData

@main
struct TimeTrackerApp: App {
    private let container: ModelContainer
    @State private var model: AppModel

    init() {
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
                    // Monospaced font for the numeric timer. (The menu bar item can
                    // still reflow as overall width changes — known cosmetic issue.)
                    Text(model.statusTitle)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                }
            }
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
