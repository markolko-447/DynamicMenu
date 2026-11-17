//
//  ActivityModule.swift
//  DynamicMenu
//
//  The contract every activity source implements, and the arbiter that picks
//  which one the pill shows.
//

import SwiftUI

/// One source of pill content (timer, battery, now playing…).
///
/// Modules are `@Observable`, and the views they return read their state directly,
/// so the pill re-renders and animates whenever a module changes.
protocol ActivityModule: AnyObject {
    var id: String { get }
    /// Higher wins. Short alerts sit above long-running activities.
    var priority: Int { get }
    var isActive: Bool { get }
    /// Breaks priority ties: the most recently started activity wins.
    var activeSince: Date { get }

    /// Begin observing the system. Called once at launch.
    func start()

    /// Left slot of the compact pill. Keep it to an icon or a few characters.
    var compactLeading: AnyView { get }
    /// Right slot of the compact pill.
    var compactTrailing: AnyView { get }
    /// Shown when several activities share the pill: the smallest recognisable
    /// form, ideally live information rather than a logo. Aim for a circle.
    var minimal: AnyView { get }
    /// Content of the expanded pill.
    var expanded: AnyView { get }
}

final class ActivityCenter {
    static let shared = ActivityCenter()

    let timer = TimerModule()
    let battery = BatteryModule.shared
    /// One Now Playing session per app.
    let media = MediaCenter()
    let calendar = CalendarModule()
    let privacy = PrivacyModule()
    let transfers = TransfersModule()
    let shelf = ShelfModule()
    /// Activities posted by other apps.
    let external = ExternalActivities()
    /// Short alerts (volume, brightness, devices…), fed by `events`.
    let flash = FlashModule()

    private let events: SystemEvents
    private let network: NetworkEvents
    private let modules: [any ActivityModule]

    private init() {
        events = SystemEvents(flash: flash)
        network = NetworkEvents(flash: flash)
        modules = [battery, flash, transfers, timer, calendar, shelf, privacy]
    }

    func start() {
        modules.forEach { $0.start() }
        media.start()
        events.start()
        network.start()
        external.start()
    }

    /// Everything running right now, most important first.
    var active: [any ActivityModule] {
        (modules + media.sessions + external.activities)
            .filter { $0.isActive && AppSettings.shared.allows($0) }
            .sorted { ($0.priority, $0.activeSince) > ($1.priority, $1.activeSince) }
    }
}
