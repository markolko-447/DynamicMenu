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
        ActivityCenter.shared.start()
        FileDragMonitor.shared.start()
        ScreenManager.shared.start()
        Updater.shared.start()
        showPermissionsOnFirstLaunch()
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
    private var updater = Updater.shared

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

        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)

        Divider()

        Button("Quit DynamicMenu") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
