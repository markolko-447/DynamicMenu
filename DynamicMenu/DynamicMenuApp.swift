//
//  DynamicMenuApp.swift
//  DynamicMenu
//

import SwiftUI

@main
struct DynamicMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu()
        } label: {
            MenuBarIconView()
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--render-states") {
            let path = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("-")
                ? arguments[index + 1] : "~/Desktop/DynamicMenu States"
            let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            Task { await StateRenderer.run(to: folder) }
            return
        }
        if let index = arguments.firstIndex(of: "--render-clips") {
            let path = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("-")
                ? arguments[index + 1] : "~/Desktop/DynamicMenu Clips"
            let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if let wallpaper = arguments.firstIndex(of: "--wallpaper"), wallpaper + 1 < arguments.count {
                let path = (arguments[wallpaper + 1] as NSString).expandingTildeInPath
                ClipBackdrop.wallpaper = NSImage(contentsOfFile: path)
            }
            // --story-wallpaper: the scroll section's own wallpaper.
            if let story = arguments.firstIndex(of: "--story-wallpaper"), story + 1 < arguments.count {
                let path = (arguments[story + 1] as NSString).expandingTildeInPath
                ClipBackdrop.storyWallpaper = NSImage(contentsOfFile: path)
            }
            ClipRenderer.stillsOnly = arguments.contains("--stills-only")
            if let i = arguments.firstIndex(of: "--pair"), i + 1 < arguments.count {
                let parts = arguments[i + 1].split(separator: ":").map(String.init)
                if parts.count == 2 { ClipRenderer.pair = (parts[0], parts[1]) }
            }
            ClipRenderer.notch = arguments.contains("--notch")
            if let i = arguments.firstIndex(of: "--look"), i + 1 < arguments.count,
               let look = PillAppearance(rawValue: arguments[i + 1]) {
                ClipRenderer.look = look
            }
            if let stages = arguments.firstIndex(of: "--stages"), stages + 1 < arguments.count {
                ClipRenderer.onlyStages = Set(arguments[stages + 1].split(separator: ",").map(String.init))
            }
            Task { await ClipRenderer.run(to: folder) }
            return
        }

        ActivityCenter.shared.start()
        FileDragMonitor.shared.start()
        ScreenManager.shared.start()
        showPermissionsOnFirstLaunch()
        if arguments.contains("--demo") { DemoLoop.start() }
    }

    /// On a new Mac, open Settings on the Permissions page so everything the app
    /// needs is in view from the start.
    private func showPermissionsOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "hasLaunchedBefore") else { return }
        defaults.set(true, forKey: "hasLaunchedBefore")
        defaults.set(SettingsPage.permissions.rawValue, forKey: SettingsPage.storageKey)
        NSApp.activate()
        // The SwiftUI Settings scene answers this action.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

/// The status-item menu: quick per-display controls, plus Settings and Quit.
private struct StatusMenu: View {
    @Environment(\.openSettings) private var openSettings
    private var screens = ScreenManager.shared

    var body: some View {
        // Each display's mode and appearance, one submenu per display.
        ForEach(screens.displays) { display in
            Menu(display.name) {
                DisplayModePicker(display: display)
                    .pickerStyle(.inline)
                DisplayAppearancePicker(display: display)
                    .pickerStyle(.inline)
            }
        }

        Divider()

        Button("Settings…") {
            // No Dock icon: bring the app forward every time, or a window that
            // is already open stays behind the front app.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit DynamicMenu") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
