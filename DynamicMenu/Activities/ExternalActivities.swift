//
//  ExternalActivities.swift
//  DynamicMenu
//
//  Lets other apps show an activity in the pill. See Docs/ExternalActivities.md.
//
//  An app posts a distributed notification whose `object` is a JSON string:
//
//    DynamicMenu.Activity.Update   {"id": "...", "title": "...", ...}
//    DynamicMenu.Activity.End      {"id": "..."}
//
//  The payload travels in `object`, not `userInfo`, because macOS strips
//  `userInfo` from notifications posted by sandboxed apps.
//

import AppKit
import SwiftUI
import Observation

/// A button the sender asks for in the expanded pill (pause, stop...).
nonisolated struct ExternalAction: Decodable, Sendable, Equatable, Identifiable {
    /// Sent back to the app when pressed.
    var id: String
    /// SF Symbol name.
    var symbol: String
    var label: String?
    /// If given, pressing opens this link (a deep link works even when the app is
    /// not running) instead of notifying the app.
    var url: String?
}

/// The JSON an app sends.
nonisolated struct ExternalActivityPayload: Decodable, Sendable, Equatable {
    /// Stable identifier chosen by the sender; updates with the same id replace
    /// the previous content.
    var id: String
    /// Name of the sending app, shown in Settings. Falls back to the `id`.
    var app: String?
    /// Bundle identifier of the sending app. The expanded pill's arrow opens it.
    var bundleID: String?
    /// A link that opens the sender at the right place (a deep link or a file).
    /// Takes precedence over `bundleID` for the arrow.
    var openURL: String?
    /// Up to three buttons shown in the expanded pill.
    var actions: [ExternalAction]?
    var title: String?
    /// SF Symbol name.
    var symbol: String?
    /// Short text for the compact slot, e.g. "3 min" or "2–1".
    var value: String?
    /// 0...1. Shown as a bar when expanded.
    var progress: Double?
    /// Seconds since 1970. Shown as a live countdown in place of `value`.
    var endDate: Double?
    /// Seconds since 1970. Shown as time counting up since then, in place of `value`
    /// (a task being timed).
    var startDate: Double?
    /// "#RRGGBB".
    var tint: String?
}

@Observable
final class ExternalActivities: NSObject {
    nonisolated static let updateName = Notification.Name("DynamicMenu.Activity.Update")
    nonisolated static let endName = Notification.Name("DynamicMenu.Activity.End")
    /// Posted by DynamicMenu when a button is pressed: {"id": "...", "action": "..."}.
    nonisolated static let actionName = Notification.Name("DynamicMenu.Activity.Action")

    /// Activities are dropped if their app stops updating them, so one that
    /// crashed cannot leave something on the pill forever.
    private static let staleAfter: TimeInterval = 8 * 60 * 60

    private(set) var activities: [ExternalActivity] = []

    @ObservationIgnored private var isObserving = false

    func start() {
        guard !isObserving else { return }
        isObserving = true
        let center = DistributedNotificationCenter.default()
        // DynamicMenu is never the frontmost app, and by default distributed
        // notifications wait until the receiver is. Ask for immediate delivery.
        center.addObserver(self, selector: #selector(received(_:)), name: Self.updateName,
                           object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(received(_:)), name: Self.endName,
                           object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private nonisolated func received(_ notification: Notification) {
        let isEnd = notification.name == Self.endName
        guard let json = notification.object as? String,
              let payload = try? JSONDecoder().decode(ExternalActivityPayload.self, from: Data(json.utf8))
        else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.apply(payload, isEnd: isEnd) }
        }
    }

    private func apply(_ payload: ExternalActivityPayload, isEnd: Bool) {
        let now = Date.now
        // Remember who sent it, so Settings can list the app.
        if !isEnd { ExternalApps.shared.noteSeen(payload) }
        activities.removeAll { now.timeIntervalSince($0.updatedAt) > Self.staleAfter }

        if isEnd {
            activities.removeAll { $0.id == "external." + payload.id }
        } else if let existing = activities.first(where: { $0.id == "external." + payload.id }) {
            existing.update(payload)
        } else {
            activities.append(ExternalActivity(payload))
        }
    }
}

@Observable
final class ExternalActivity: ActivityModule {
    let id: String
    /// The sending app, as Settings lists it.
    let appKey: String
    /// An app marked important in Settings ranks above Now Playing, so it takes
    /// the main pill; any other sits beside it.
    var priority: Int { ExternalApps.shared.isImportant(appKey) ? 85 : 30 }
    let isActive = true
    let activeSince = Date.now

    private(set) var payload: ExternalActivityPayload
    private(set) var updatedAt = Date.now

    init(_ payload: ExternalActivityPayload) {
        id = "external." + payload.id
        appKey = ExternalApps.key(for: payload)
        self.payload = payload
    }

    func start() {}

    func update(_ payload: ExternalActivityPayload) {
        self.payload = payload
        updatedAt = .now
    }

    var tint: Color {
        guard let hex = payload.tint?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
              hex.count == 6, let value = UInt32(hex, radix: 16)
        else { return .white }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// Falls back to a generic symbol if the name is not a real SF Symbol.
    var symbol: String {
        guard let name = payload.symbol,
              NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        else { return "app.fill" }
        return name
    }

    /// What the arrow opens: the link, else the app by identifier, else the app by
    /// name if it is running. Nil when none can be found, and the arrow is hidden.
    private var target: (() -> Void)? {
        if let link = payload.openURL, let url = URL(string: link) {
            return { NSWorkspace.shared.open(url) }
        }
        if let bundleID = payload.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
        }
        if let name = payload.app,
           let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            return { running.activate() }
        }
        return nil
    }

    var canOpen: Bool { target != nil }

    /// A button was pressed: open its link, or tell the app which one.
    func perform(_ action: ExternalAction) {
        if let link = action.url, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
            return
        }
        let message: [String: String] = ["id": payload.id, "action": action.id]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            ExternalActivities.actionName, object: String(decoding: data, as: UTF8.self),
            userInfo: nil, deliverImmediately: true)
    }

    func open() { target?() }

    var compactLeading: AnyView { AnyView(Image(systemName: symbol).foregroundStyle(tint)) }
    var compactTrailing: AnyView { AnyView(ExternalValue(activity: self)) }
    var minimal: AnyView { AnyView(Image(systemName: symbol).foregroundStyle(tint)) }
    var expanded: AnyView { AnyView(ExternalExpandedView(activity: self)) }
}

private struct ExternalValue: View {
    let activity: ExternalActivity

    var body: some View {
        Group {
            if let end = activity.payload.endDate.map(Date.init(timeIntervalSince1970:)), end > .now {
                Text(timerInterval: Date.now...end, countsDown: true)
                    .monospacedDigit()
            } else if let start = activity.payload.startDate.map(Date.init(timeIntervalSince1970:)), start < .now {
                if let frozen = DemoClock.now {
                    // Stopped time, for recordings.
                    let elapsed = max(0, frozen.timeIntervalSince(start).rounded())
                    Text(Duration.seconds(elapsed),
                         format: .time(pattern: elapsed >= 3600 ? .hourMinuteSecond : .minuteSecond))
                        .monospacedDigit()
                } else {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
            } else if let value = activity.payload.value {
                Text(value)
            } else if let progress = activity.payload.progress {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(activity.tint)
        .lineLimit(1)
        .frame(maxWidth: 110)
        .fixedSize()
    }
}

private struct ExternalExpandedView: View {
    let activity: ExternalActivity

    var body: some View {
        let actions = Array((activity.payload.actions ?? []).prefix(3))
        VStack(spacing: 12) {
            // First row: what it is, and the arrow that opens the app.
            HStack(spacing: 14) {
                Image(systemName: activity.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(activity.tint)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(activity.payload.title ?? activity.payload.app ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    ExternalValue(activity: activity)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    if let progress = activity.payload.progress {
                        LevelBar(level: progress, tint: activity.tint)
                            .frame(height: 6)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
                // Opens the app that sent it, like the timer's arrow opens Clock.
                if activity.canOpen {
                    Button {
                        activity.open()
                    } label: {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(activity.payload.app ?? "App")")
                }
            }

            // Second row: the app's own buttons, as words.
            if !actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(actions) { action in
                        Button {
                            activity.perform(action)
                        } label: {
                            Text(action.label ?? action.id.capitalized)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(.white.opacity(0.18), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Apps that have sent activities

/// The apps that have sent an activity, remembered so Settings can list them and
/// the user can mark the ones that matter.
@Observable
final class ExternalApps {
    static let shared = ExternalApps()

    struct Entry: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var symbol: String
        var important = false
        var lastSeen = Date.now
    }

    private static let key = "externalApps"
    private(set) var entries: [Entry]

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        entries = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// Activities of one app share a key: the sender's name if it gave one, else its id.
    nonisolated static func key(for payload: ExternalActivityPayload) -> String {
        payload.app ?? payload.id
    }

    func isImportant(_ key: String) -> Bool {
        entries.first { $0.id == key }?.important ?? false
    }

    func setImportant(_ important: Bool, for key: String) {
        guard let index = entries.firstIndex(where: { $0.id == key }) else { return }
        entries[index].important = important
        save()
    }

    func forget(_ key: String) {
        entries.removeAll { $0.id == key }
        save()
    }

    func noteSeen(_ payload: ExternalActivityPayload) {
        let key = Self.key(for: payload)
        let name = payload.app ?? Self.readableName(of: payload.id)
        let symbol = payload.symbol ?? "app.fill"
        if let index = entries.firstIndex(where: { $0.id == key }) {
            // Rewriting on every update would hammer UserDefaults; a minute is plenty.
            let stale = Date.now.timeIntervalSince(entries[index].lastSeen) > 60
            guard stale || entries[index].symbol != symbol || entries[index].name != name else { return }
            entries[index].name = name
            entries[index].symbol = symbol
            entries[index].lastSeen = .now
        } else {
            entries.append(Entry(id: key, name: name, symbol: symbol))
        }
        save()
    }

    /// "com.example.export" → "Export".
    private static func readableName(of id: String) -> String {
        let last = id.split(separator: ".").last.map(String.init) ?? id
        return last.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
