import SwiftUI
import AppKit
import ServiceManagement

@main
struct XrealAnchorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var engine = AnchorEngine.shared

    var body: some Scene {
        MenuBarExtra {
            ControlPanel()
                .environmentObject(AnchorEngine.shared)
                .environmentObject(Settings.shared)
        } label: {
            Image(systemName: engine.isActive ? "sunglasses.fill" : "sunglasses")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let hotkeys = Hotkeys()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let engine = AnchorEngine.shared
        hotkeys.register(ShortcutAction.allCases) { engine.perform($0) }
        engine.launch()

        // `kill`/Ctrl-C should still put the displays back the way they were.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AnchorEngine.shared.shutdown()
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("launch at login failed: \(error)")
        }
    }
}
