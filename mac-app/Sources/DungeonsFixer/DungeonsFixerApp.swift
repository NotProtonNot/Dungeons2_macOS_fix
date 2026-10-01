import AppKit
import SwiftUI

@main
struct DungeonsFixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Dungeons II Fixer", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Dungeons II Fixer") { showAbout() }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Refresh Bottles") { model.refresh() }
                    .keyboardShortcut("r")
            }
            CommandGroup(replacing: .help) {
                Link("About the Fix (NotProton)", destination: URL(string: "https://github.com/NotProtonNot/Dungeons2_macOS_fix")!)
            }
        }
    }

    private func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Original Minecraft Dungeons II fix by Kubas556.\nMac compatibility and xgameruntime.dll by NotProton (github.com/NotProtonNot/Dungeons2_macOS_fix).\n\nNot affiliated with Mojang, Microsoft or CodeWeavers.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run straight from `swift run`, outside an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
