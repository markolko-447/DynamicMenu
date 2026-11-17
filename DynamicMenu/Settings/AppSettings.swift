//
//  AppSettings.swift
//  DynamicMenu
//
//  User preferences, stored in UserDefaults. Appearance lives in
//  AppearanceSettings and per-display modes in DisplayInfo; this holds the rest.
//

import Foundation
import Observation
import ServiceManagement

/// Activities that can be switched off as a whole.
enum ActivityKind: String, CaseIterable, Identifiable {
    case media, timers, calendar, battery, privacy, transfers, shelf, apps

    var id: String { rawValue }

    var label: String {
        switch self {
        case .media: "Now Playing"
        case .timers: "Timers"
        case .calendar: "Calendar"
        case .battery: "Battery"
        case .privacy: "Camera & Microphone"
        case .transfers: "Downloads & AirDrop"
        case .shelf: "File Shelf"
        case .apps: "Other Apps"
        }
    }

    var detail: String {
        switch self {
        case .media: "Music, Spotify, videos in the browser and any other player."
        case .timers: "Timers you start in the Clock app."
        case .calendar: "Your next event, shortly before it starts."
        case .battery: "Charger connected or removed, and low battery."
        case .privacy: "While any app uses the camera or microphone."
        case .transfers: "Progress of files arriving in Downloads."
        case .shelf: "Files you drop on the pill to use later."
        case .apps: "Activities other Mac apps send to DynamicMenu."
        }
    }

    var symbol: String {
        switch self {
        case .media: "music.note"
        case .timers: "timer"
        case .calendar: "calendar"
        case .battery: "battery.75percent"
        case .privacy: "video.fill"
        case .transfers: "arrow.down.circle.fill"
        case .shelf: "tray.full.fill"
        case .apps: "app.badge"
        }
    }

    /// The kind an activity module belongs to; nil for alerts, which are
    /// switched off per alert instead.
    static func of(_ module: any ActivityModule) -> ActivityKind? {
        let id = module.id
        if id.hasPrefix("nowPlaying") { return .media }
        if id.hasPrefix("external.") { return .apps }
        switch id {
        case "timer": return .timers
        case "calendar": return .calendar
        case "battery": return .battery
        case "privacy": return .privacy
        case "transfers": return .transfers
        case "shelf": return .shelf
        default: return nil
        }
    }
}

/// Short alerts that can be switched off individually.
enum AlertKind: String, CaseIterable, Identifiable {
    case volume, output, network, lock, lowPower

    var id: String { rawValue }

    var label: String {
        switch self {
        case .volume: "Volume & Brightness"
        case .output: "Audio Devices"
        case .network: "Wi-Fi, Hotspot & VPN"
        case .lock: "Unlock & Caps Lock"
        case .lowPower: "Low Power Mode"
        }
    }

    var symbol: String {
        switch self {
        case .volume: "speaker.wave.2.fill"
        case .output: "airpods"
        case .network: "wifi"
        case .lock: "lock.open.fill"
        case .lowPower: "battery.50percent"
        }
    }

    /// The `Flash.kind` values this switch covers.
    var flashKinds: Set<String> {
        switch self {
        case .volume: ["volume", "brightness"]
        case .output: ["output", "bluetooth"]
        case .network: ["network", "vpn"]
        case .lock: ["lock", "capsLock"]
        case .lowPower: ["lowPower"]
        }
    }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Activity kinds the user switched off.
    var disabledActivities: Set<String> {
        didSet { defaults.set(Array(disabledActivities), forKey: "disabledActivities") }
    }

    /// Alert kinds the user switched off.
    var disabledAlerts: Set<String> {
        didSet { defaults.set(Array(disabledAlerts), forKey: "disabledAlerts") }
    }

    /// How long paused media stays on the pill.
    var mediaLingerSeconds: Int {
        didSet { defaults.set(mediaLingerSeconds, forKey: "mediaLingerSeconds") }
    }

    /// How early a calendar event appears.
    var calendarLeadMinutes: Int {
        didSet { defaults.set(calendarLeadMinutes, forKey: "calendarLeadMinutes") }
    }

    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: "hapticsEnabled") }
    }

    /// On external displays, let the pill shrink away while nothing is running.
    var hidesIdlePill: Bool {
        didSet { defaults.set(hidesIdlePill, forKey: "hidesIdlePill") }
    }

    /// On a notch, keep the menu bar's icons out from under the pill.
    var reservesMenuBarSpace: Bool {
        didSet {
            defaults.set(reservesMenuBarSpace, forKey: "reservesMenuBarSpace")
            ScreenManager.shared.refreshReserve()
        }
    }

    private init() {
        reservesMenuBarSpace = defaults.object(forKey: "reservesMenuBarSpace") as? Bool ?? false
        disabledActivities = Set(defaults.stringArray(forKey: "disabledActivities") ?? [])
        disabledAlerts = Set(defaults.stringArray(forKey: "disabledAlerts") ?? [])
        mediaLingerSeconds = defaults.object(forKey: "mediaLingerSeconds") as? Int ?? 30
        calendarLeadMinutes = defaults.object(forKey: "calendarLeadMinutes") as? Int ?? 15
        hapticsEnabled = defaults.object(forKey: "hapticsEnabled") as? Bool ?? true
        hidesIdlePill = defaults.object(forKey: "hidesIdlePill") as? Bool ?? true
    }

    func isEnabled(_ kind: ActivityKind) -> Bool { !disabledActivities.contains(kind.rawValue) }

    func setEnabled(_ kind: ActivityKind, _ enabled: Bool) {
        if enabled { disabledActivities.remove(kind.rawValue) } else { disabledActivities.insert(kind.rawValue) }
    }

    func isEnabled(_ kind: AlertKind) -> Bool { !disabledAlerts.contains(kind.rawValue) }

    func setEnabled(_ kind: AlertKind, _ enabled: Bool) {
        if enabled { disabledAlerts.remove(kind.rawValue) } else { disabledAlerts.insert(kind.rawValue) }
    }

    /// Whether an alert of this `Flash.kind` may show.
    func allowsFlash(kind: String) -> Bool {
        guard let alert = AlertKind.allCases.first(where: { $0.flashKinds.contains(kind) }) else { return true }
        return isEnabled(alert)
    }

    /// Whether this module may appear on the pill.
    func allows(_ module: any ActivityModule) -> Bool {
        guard let kind = ActivityKind.of(module) else { return true }
        return isEnabled(kind)
    }
}
