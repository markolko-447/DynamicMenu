//
//  Permissions.swift
//  DynamicMenu
//
//  Every permission the app relies on, its current state, and how to ask for it.
//  The list is fixed, so a new Mac shows everything the app will need up front.
//

import AppKit
import EventKit
import Observation
import ServiceManagement

enum PermissionState: Equatable {
    case granted
    case denied
    case notAsked
    /// macOS wants the user to approve it somewhere else first.
    case needsApproval

    var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Not Allowed"
        case .notAsked: "Not Asked Yet"
        case .needsApproval: "Needs Approval"
        }
    }
}

/// The folders macOS asks about one by one.
enum ProtectedFolder: String, CaseIterable, Hashable {
    case downloads, desktop, documents

    nonisolated var url: URL {
        let directory: FileManager.SearchPathDirectory = switch self {
        case .downloads: .downloadsDirectory
        case .desktop: .desktopDirectory
        case .documents: .documentDirectory
        }
        return FileManager.default.urls(for: directory, in: .userDomainMask)[0]
    }

    var title: String {
        switch self {
        case .downloads: "Downloads Folder"
        case .desktop: "Desktop Folder"
        case .documents: "Documents Folder"
        }
    }

    var purpose: String {
        switch self {
        case .downloads: "Download and AirDrop progress, and shelf files from Downloads or its Dock stack."
        case .desktop: "Shelf files you drop from the Desktop."
        case .documents: "Shelf files you drop from Documents."
        }
    }

    /// The protected folder a file lives in, if any.
    static func containing(_ file: URL) -> ProtectedFolder? {
        let path = file.standardizedFileURL.path
        return allCases.first { path.hasPrefix($0.url.standardizedFileURL.path + "/") }
    }

    /// Notes that the app has used this folder. macOS asks the first time an app
    /// reads a protected folder and has no way to check silently before that, so
    /// only folders the app has touched are checked.
    func markUsed() {
        var used = Set(UserDefaults.standard.stringArray(forKey: "foldersUsed") ?? [])
        guard used.insert(rawValue).inserted else { return }
        UserDefaults.standard.set(Array(used), forKey: "foldersUsed")
    }

    var wasUsed: Bool {
        (UserDefaults.standard.stringArray(forKey: "foldersUsed") ?? []).contains(rawValue)
    }

    /// Reads the folder. Shows the system prompt the first time.
    nonisolated func canRead() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }
}

enum Permission: Hashable, Identifiable {
    case calendars
    case folder(ProtectedFolder)
    /// Sending Apple Events to the app with this bundle identifier.
    case automation(String)
    case loginItem

    var id: String {
        switch self {
        case .calendars: "calendars"
        case .folder(let folder): "folder." + folder.rawValue
        case .automation(let app): "automation." + app
        case .loginItem: "loginItem"
        }
    }

    var title: String {
        switch self {
        case .calendars: "Calendars"
        case .folder(let folder): folder.title
        case .automation(let app): Self.appName(app)
        case .loginItem: "Open at Login"
        }
    }

    var purpose: String {
        switch self {
        case .calendars: "Shows your next event shortly before it starts."
        case .folder(let folder): folder.purpose
        case .automation(let app):
            app == Permissions.musicBundleID
                ? "Favourite and Suggest Less for songs in Music."
                : "Controls \(Self.appName(app)) from the pill."
        case .loginItem: "Starts DynamicMenu when you log in."
        }
    }

    var symbol: String {
        switch self {
        case .calendars: "calendar"
        case .folder(.downloads): "arrow.down.circle.fill"
        case .folder(.desktop): "menubar.dock.rectangle"
        case .folder(.documents): "doc.fill"
        case .automation: "gearshape.2.fill"
        case .loginItem: "power"
        }
    }

    /// The app's own icon, for automation rows.
    var appIcon: NSImage? {
        guard case .automation(let app) = self,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    fileprivate var settingsAnchor: String {
        switch self {
        case .calendars: "Privacy_Calendars"
        case .folder: "Privacy_FilesAndFolders"
        case .automation: "Privacy_Automation"
        case .loginItem: ""
        }
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

@Observable
final class Permissions {
    static let shared = Permissions()

    nonisolated static let musicBundleID = "com.apple.Music"

    private(set) var states: [Permission: PermissionState] = [:]

    /// Groups as shown in Settings, in order.
    var sections: [(title: String, items: [Permission])] {
        // Music is the app DynamicMenu scripts; any other app it has tried to
        // script is listed as well.
        let scripted = ([Self.musicBundleID] + AutomationRecord.apps)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return [
            ("Activities", [.calendars, .folder(.downloads)]),
            ("File Shelf", [.folder(.desktop), .folder(.documents)]),
            ("Control Other Apps", scripted.map(Permission.automation)),
            ("Startup", [.loginItem]),
        ]
    }

    func state(of permission: Permission) -> PermissionState {
        states[permission] ?? .notAsked
    }

    /// Re-reads every permission without showing any prompt.
    func refresh() {
        var updated: [Permission: PermissionState] = [:]
        for permission in sections.flatMap(\.items) {
            updated[permission] = currentState(of: permission)
        }
        if updated != states { states = updated }
    }

    private func currentState(of permission: Permission) -> PermissionState {
        switch permission {
        case .calendars:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }

        case .folder(let folder):
            guard folder.wasUsed else { return .notAsked }
            return folder.canRead() ? .granted : .denied

        case .automation(let app):
            // macOS answers only while the app is running; otherwise show the
            // last answer the app saw.
            if let live = Self.automationState(of: app, ask: false), live != .notAsked {
                AutomationRecord.set(live == .granted ? .granted : .denied, for: app)
                return live
            }
            return switch AutomationRecord.state(for: app) {
            case .granted: .granted
            case .denied: .denied
            case nil: .notAsked
            }

        case .loginItem:
            switch SMAppService.mainApp.status {
            case .enabled: return .granted
            case .requiresApproval: return .needsApproval
            default: return .notAsked
            }
        }
    }

    /// Asks macOS where an app may ask; otherwise opens System Settings there.
    func request(_ permission: Permission) {
        let state = state(of: permission)
        switch permission {
        case .calendars where state == .notAsked:
            Task {
                _ = try? await EKEventStore().requestFullAccessToEvents()
                ActivityCenter.shared.calendar.reload()
                refresh()
            }

        case .folder(let folder) where state == .notAsked:
            folder.markUsed()
            Task.detached {
                _ = folder.canRead()
                await MainActor.run { Permissions.shared.refresh() }
            }

        case .automation(let app) where state == .notAsked:
            askForAutomation(app)

        case .loginItem:
            toggleLoginItem()

        default:
            openSettings(for: permission)
        }
    }

    func openSettings(for permission: Permission) {
        if permission == .loginItem {
            SMAppService.openSystemSettingsLoginItems()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS can only ask about an app that is running, so start it in the
    /// background first if needed.
    private func askForAutomation(_ app: String) {
        Task {
            if NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                try? await Task.sleep(for: .seconds(1))
            }
            let state = await Task.detached { Self.automationState(of: app, ask: true) }.value
            if let state, state != .notAsked {
                AutomationRecord.set(state == .granted ? .granted : .denied, for: app)
            }
            refresh()
        }
    }

    private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            // Usually means macOS wants the user to approve it in Login Items.
            SMAppService.openSystemSettingsLoginItems()
        }
        refresh()
    }

    /// The Automation answer for an app, or nil if it is not running.
    /// Shows the system prompt only when `ask` is true.
    private nonisolated static func automationState(of app: String, ask: Bool) -> PermissionState? {
        guard let descriptor = NSAppleEventDescriptor(bundleIdentifier: app).aeDesc else { return nil }
        switch AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return nil
        }
    }
}
