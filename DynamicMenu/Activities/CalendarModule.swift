//
//  CalendarModule.swift
//  DynamicMenu
//
//  The next calendar event, from fifteen minutes before it starts until five
//  minutes after, with a Join button when the event carries a meeting link.
//

import AppKit
import SwiftUI
import Observation
import EventKit

@Observable
final class CalendarModule: ActivityModule {
    let id = "calendar"
    let priority = 45

    private(set) var title = ""
    private(set) var startDate = Date.distantFuture
    private(set) var endDate = Date.distantFuture
    private(set) var location: String?
    private(set) var joinURL: URL?
    private(set) var isActive = false
    private(set) var activeSince = Date.distantPast

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var eventID: String?

    private static var leadTime: TimeInterval { TimeInterval(AppSettings.shared.calendarLeadMinutes * 60) }
    private static let lingerTime: TimeInterval = 5 * 60

    /// Starts again, e.g. after the user granted calendar access in Settings.
    func reload() {
        refreshTask?.cancel()
        refreshTask = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        start()
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            // Without permission the module stays silent.
            guard let self, (try? await self.store.requestFullAccessToEvents()) == true else { return }

            self.observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: self.store, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            while !Task.isCancelled {
                self.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func join() {
        guard let joinURL else { return }
        NSWorkspace.shared.open(joinURL)
    }

    /// Shows the event in Calendar, or just opens Calendar if it cannot be found.
    func openInCalendar() {
        if let eventID,
           let encoded = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"),
           NSWorkspace.shared.open(url) {
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func refresh() {
        let now = Date.now
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-Self.lingerTime),
            end: now.addingTimeInterval(Self.leadTime),
            calendars: nil)
        let next = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now.addingTimeInterval(-Self.lingerTime) }
            .min { $0.startDate < $1.startDate }

        guard let next else {
            isActive = false
            eventID = nil
            return
        }
        if next.eventIdentifier != eventID || !isActive {
            eventID = next.eventIdentifier
            activeSince = now
        }
        title = next.title ?? "Event"
        startDate = next.startDate
        endDate = next.endDate
        location = next.location.flatMap { $0.isEmpty ? nil : $0 }
        joinURL = Self.meetingLink(in: next)
        isActive = true
    }

    /// The event's own URL, or the first link found in its location or notes.
    private static func meetingLink(in event: EKEvent) -> URL? {
        if let url = event.url, url.scheme?.hasPrefix("http") == true { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .first { $0.scheme?.hasPrefix("http") == true }
    }

    // MARK: - Presentation

    var compactLeading: AnyView {
        AnyView(Image(systemName: "calendar").foregroundStyle(.red))
    }

    var compactTrailing: AnyView {
        AnyView(EventCountdown(module: self).foregroundStyle(.red))
    }

    var minimal: AnyView {
        AnyView(EventCountdown(module: self).foregroundStyle(.red))
    }

    var expanded: AnyView {
        AnyView(CalendarExpandedView(module: self))
    }
}

/// Counts down to the start, then reads "Now".
private struct EventCountdown: View {
    let module: CalendarModule

    var body: some View {
        TimelineView(.periodic(from: .distantPast, by: 1)) { context in
            let now = context.date
            if module.startDate > now {
                Text(timerInterval: now...module.startDate, countsDown: true)
                    .monospacedDigit()
            } else {
                Text("Now")
            }
        }
    }
}

private struct CalendarExpandedView: View {
    let module: CalendarModule

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(module.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(module.startDate...module.endDate)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                if let location = module.location, module.joinURL == nil {
                    Text(location)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if module.joinURL != nil {
                Button(action: module.join) {
                    Label("Join", systemImage: "video.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(.green, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                EventCountdown(module: module)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.red)
            }

            // Same as the timer's Open Clock button.
            Button(action: module.openInCalendar) {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open in Calendar")
        }
    }
}
