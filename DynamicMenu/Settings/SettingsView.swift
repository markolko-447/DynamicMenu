//
//  SettingsView.swift
//  DynamicMenu
//

import SwiftUI

enum SettingsPage: String {
    case general, activities, displays, shelf, permissions

    static let storageKey = "settingsPage"
}

struct SettingsView: View {
    @AppStorage(SettingsPage.storageKey) private var page = SettingsPage.general

    var body: some View {
        TabView(selection: $page) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings() }
            Tab("Activities", systemImage: "square.stack.3d.up", value: .activities) { ActivitySettings() }
            Tab("Displays", systemImage: "display", value: .displays) { DisplaySettings() }
            Tab("Shelf", systemImage: "tray.full", value: .shelf) { ShelfSettings() }
            Tab("Permissions", systemImage: "hand.raised", value: SettingsPage.permissions) { PermissionSettings() }
        }
        .frame(width: 540, height: 500)
        // DynamicMenu has no Dock icon, so without this the window opens behind
        // whatever app is in front.
        .onAppear { NSApp.activate() }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable private var settings = AppSettings.shared
    private var permissions = Permissions.shared

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(
                    get: { permissions.state(of: .loginItem) == .granted },
                    set: { _ in permissions.request(.loginItem) }
                ))
                if permissions.state(of: .loginItem) == .needsApproval {
                    Button("Approve in Login Items…") { permissions.openSettings(for: .loginItem) }
                }
            }

            Section("Behaviour") {
                Toggle("Haptic Feedback", isOn: $settings.hapticsEnabled)
                Toggle(isOn: $settings.hidesIdlePill) {
                    Text("Hide Pill When Idle")
                    Text("On external displays, the pill draws in to a dot and disappears while nothing is running, and returns when something starts.")
                }
            }

            Section {
                Toggle(isOn: $settings.reservesMenuBarSpace) {
                    Text("Reserve Menu Bar Space")
                    Text("On a notch, keeps menu bar icons from sitting under the pill while an activity is showing. Apps' own menus on the left can't be reserved for.")
                }
            }

            Section {
                Button("Quit DynamicMenu") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .task { permissions.refresh() }
    }
}

// MARK: - Activities

private struct ActivitySettings: View {
    @Bindable private var settings = AppSettings.shared
    private let apps = ExternalApps.shared

    var body: some View {
        Form {
            Section("Activities") {
                ForEach(ActivityKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { settings.isEnabled(kind) },
                        set: { settings.setEnabled(kind, $0) }
                    )) {
                        Label {
                            Text(kind.label)
                            Text(kind.detail)
                        } icon: {
                            Image(systemName: kind.symbol)
                        }
                    }
                }
            }

            Section {
                if apps.entries.isEmpty {
                    Text("Apps that send activities to DynamicMenu appear here the first time they do.")
                        .foregroundStyle(.secondary)
                }
                ForEach(apps.entries) { app in
                    Toggle(isOn: Binding(
                        get: { app.important },
                        set: { apps.setImportant($0, for: app.id) }
                    )) {
                        Label {
                            Text(app.name)
                            Text(app.important ? "Important: shown in the pill, above music"
                                               : "Shown beside the pill")
                        } icon: {
                            Image(systemName: app.symbol)
                        }
                    }
                    .contextMenu { Button("Forget \(app.name)") { apps.forget(app.id) } }
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("An important app takes the main pill, above Now Playing. Others show beside it.")
            }

            Section("Alerts") {
                ForEach(AlertKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { settings.isEnabled(kind) },
                        set: { settings.setEnabled(kind, $0) }
                    )) {
                        Label(kind.label, systemImage: kind.symbol)
                    }
                }
            }

            Section("Timing") {
                Picker("Paused media stays for", selection: $settings.mediaLingerSeconds) {
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                }
                Picker("Show events", selection: $settings.calendarLeadMinutes) {
                    Text("5 minutes before").tag(5)
                    Text("10 minutes before").tag(10)
                    Text("15 minutes before").tag(15)
                    Text("30 minutes before").tag(30)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Displays

private struct DisplaySettings: View {
    private var screens = ScreenManager.shared

    var body: some View {
        Form {
            ForEach(screens.displays) { display in
                Section {
                    DisplayModePicker(display: display)
                    DisplayAppearancePicker(display: display)
                } header: {
                    Label(display.name, systemImage: display.detected == .plain ? "display" : "laptopcomputer")
                }
            }
            Section {
            } footer: {
                Text("Automatic uses the notch on a built-in display that has one, a pill everywhere else, and stays off a display that already shows Apple's own pill. Glass is for pills; a notch has to stay black to meet the camera housing.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Notch, pill or off for one display. Used in Settings and the menu bar menu.
struct DisplayModePicker: View {
    let display: DisplayInfo
    private var screens = ScreenManager.shared

    init(display: DisplayInfo) {
        self.display = display
    }

    var body: some View {
        Picker("Mode", selection: Binding(
            get: { display.override },
            set: { screens.setOverride($0, for: display) }
        )) {
            ForEach(ModeOverride.allCases) { mode in
                Text(mode == .automatic ? "Automatic (\(display.detected.label))" : mode.label).tag(mode)
            }
        }
    }
}

/// Solid, gradient or glass for one display. Used in Settings and the menu bar menu.
struct DisplayAppearancePicker: View {
    let display: DisplayInfo
    private var appearance = AppearanceSettings.shared

    init(display: DisplayInfo) {
        self.display = display
    }

    var body: some View {
        let choices = PillAppearance.choices(for: display.style)
        Picker("Appearance", selection: Binding(
            get: {
                let current = appearance.appearance(for: display.uuid)
                return choices.contains(current) ? current : .gradient
            },
            set: { appearance.setAppearance($0, for: display.uuid) }
        )) {
            ForEach(choices) { Text($0.label).tag($0) }
        }
        .disabled(display.style == nil)
    }
}

// MARK: - Shelf

private struct ShelfSettings: View {
    @Bindable private var shelf = ActivityCenter.shared.shelf

    var body: some View {
        Form {
            Section {
                Toggle("Keep Files After Dragging Out", isOn: $shelf.keepsFilesAfterDragOut)
            } footer: {
                Text("When off, a file leaves the shelf once you drop it in another app. Dropping it back on the pill or cancelling the drag keeps it.")
            }

            Section {
                LabeledContent("Files on Shelf", value: "\(shelf.files.count)")
                Button("Clear Shelf", role: .destructive) { shelf.clear() }
                    .disabled(shelf.files.isEmpty)
            } footer: {
                Text("Files from Finder stay where they are; the shelf only remembers them. Content from Mail, Photos or a web page is copied, and the copy is deleted when it leaves the shelf.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    private var permissions = Permissions.shared

    var body: some View {
        Form {
            Section {
                Text("Everything DynamicMenu needs, and what each one is for. Allow the ones for the features you use.")
                    .foregroundStyle(.secondary)
            }
            ForEach(permissions.sections, id: \.title) { section in
                if !section.items.isEmpty {
                    Section(section.title) {
                        ForEach(section.items) { permission in
                            PermissionRow(permission: permission, state: permissions.state(of: permission))
                        }
                    }
                }
            }
            Section {
            } footer: {
                Text("Some permissions can only be changed in System Settings. This page updates when you come back.")
            }
        }
        .formStyle(.grouped)
        // Changes made in System Settings arrive without any notice, so check
        // while the page is open.
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let state: PermissionState

    private var permissions: Permissions { .shared }

    var body: some View {
        HStack(spacing: 12) {
            if let icon = permission.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: permission.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Label(state.label, systemImage: statusSymbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .fixedSize()

            Button(buttonTitle) { permissions.request(permission) }
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch state {
        case .granted: .green
        case .denied: .red
        case .notAsked, .needsApproval: .orange
        }
    }

    private var statusSymbol: String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notAsked, .needsApproval: "questionmark.circle.fill"
        }
    }

    private var buttonTitle: String {
        switch (permission, state) {
        case (.loginItem, .granted): "Turn Off"
        case (.loginItem, _): "Turn On"
        case (_, .notAsked): "Allow…"
        default: "Open Settings…"
        }
    }
}
