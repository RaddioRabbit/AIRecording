import SwiftUI
import AppKit

@main
struct AIRecordingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()

        // Regular app: show icon in Dock as well as menu bar
        NSApp.setActivationPolicy(.regular)
        Task { await KnowledgeSyncCoordinator.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await KnowledgeSyncCoordinator.shared.stop() }
        KnowledgeServiceManager.shared.stopService()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Handle file open if needed
    }
}
