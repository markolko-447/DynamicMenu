//
//  TimerModule.swift
//  DynamicMenu
//
//  Shows the system Clock app's timers. DynamicMenu has no timer of its own.
//
//  macOS has no public API for Clock's timers. The timer daemon mirrors its state
//  into the `com.apple.mobiletimerd` preferences domain, which this module reads.
//  That format is undocumented and could change in any macOS update; every field
//  is therefore read defensively, and a failed read just means no timer is shown.
//

import AppKit
import SwiftUI
import Observation

@Observable
final class TimerModule: ActivityModule {
    let id = "timer"

    /// When the running timer fires. Nil if none is running.
    private(set) var end: Date?
    /// Time left on a paused timer. Nil if none is paused.
    private(set) var pausedRemaining: TimeInterval?
    /// True for a few seconds after a timer runs out.
    private(set) var isFinished = false
    private(set) var activeSince = Date.distantPast

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?

    var isActive: Bool { end != nil || pausedRemaining != nil || isFinished }
    /// A finished timer is an alert and jumps ahead of everything else.
    var priority: Int { isFinished ? 110 : 50 }

    func start() {
        guard pollTask == nil else { return }
        // The daemon posts no notification we can subscribe to, so poll. A
        // preferences read is a cheap in-memory lookup.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.read()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func openClock() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.clock") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Reading Clock's state

    private static let domain = "com.apple.mobiletimerd" as CFString
    private static let runningState = 3
    private static let pausedState = 2

    private func read() {
        CFPreferencesAppSynchronize(Self.domain)
        let root = CFPreferencesCopyAppValue("MTTimers" as CFString, Self.domain) as? [String: Any]
        let timers = (root?["MTTimers"] as? [[String: Any]] ?? []).compactMap { $0["$MTTimer"] as? [String: Any] }

        var soonestEnd: Date?
        var paused: TimeInterval?
        for timer in timers {
            let state = timer["MTTimerState"] as? Int
            let fireTime = timer["MTTimerFireTime"]
            if state == Self.runningState, let date = Self.firstValue(of: Date.self, in: fireTime), date > .now {
                soonestEnd = min(soonestEnd ?? date, date)
            } else if state == Self.pausedState, let remaining = Self.firstValue(of: Double.self, in: fireTime) {
                paused = paused ?? remaining
            }
        }
        apply(end: soonestEnd, pausedRemaining: soonestEnd == nil ? paused : nil)
    }

    private func apply(end newEnd: Date?, pausedRemaining newPaused: TimeInterval?) {
        guard newEnd != end || newPaused != pausedRemaining else { return }

        // A running timer that disappears right at its fire time has finished;
        // one that disappears earlier was cancelled.
        let ranOut = newEnd == nil && newPaused == nil
            && (end.map { $0.timeIntervalSinceNow < 1.5 } ?? false)
        if !isActive { activeSince = .now }
        end = newEnd
        pausedRemaining = newPaused

        if ranOut {
            isFinished = true
            finishTask?.cancel()
            finishTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.isFinished = false
            }
        } else if newEnd != nil || newPaused != nil {
            finishTask?.cancel()
            isFinished = false
        }
    }

    /// The fire time is a nested dictionary whose keys differ by timer kind, so
    /// search it for the first value of the wanted type.
    private static func firstValue<T>(of type: T.Type, in value: Any?) -> T? {
        if let match = value as? T { return match }
        guard let dictionary = value as? [String: Any] else { return nil }
        for nested in dictionary.values {
            if let match = firstValue(of: type, in: nested) { return match }
        }
        return nil
    }

    // MARK: - Presentation

    var compactLeading: AnyView {
        AnyView(TimerIcon(module: self))
    }

    var compactTrailing: AnyView {
        AnyView(TimerReadout(module: self).foregroundStyle(isFinished ? .red : .orange))
    }

    /// Like the system Timer, the minimal view shows the time, not just an icon.
    var minimal: AnyView {
        AnyView(TimerReadout(module: self).foregroundStyle(isFinished ? .red : .orange))
    }

    var expanded: AnyView {
        AnyView(TimerExpandedView(module: self))
    }
}

/// The clock in the compact pill. When the timer runs out it turns red and
/// rings: a bell-like wiggle that repeats until the alert goes away.
private struct TimerIcon: View {
    let module: TimerModule

    var body: some View {
        Image(systemName: module.isFinished ? "alarm.fill" : "timer")
            .foregroundStyle(module.isFinished ? .red : .orange)
            .symbolEffect(.wiggle.byLayer, options: .repeating, isActive: module.isFinished)
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct TimerReadout: View {
    let module: TimerModule

    var body: some View {
        if let end = module.end {
            Text(timerInterval: Date.now...max(end, .now), countsDown: true)
                .monospacedDigit()
        } else if let remaining = module.pausedRemaining {
            Text(Duration.seconds(remaining), format: .time(pattern: remaining >= 3600 ? .hourMinuteSecond : .minuteSecond))
                .monospacedDigit()
                .opacity(0.6)
        } else {
            Text("Done")
        }
    }
}

private struct TimerExpandedView: View {
    let module: TimerModule

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Label(module.pausedRemaining != nil ? "Timer Paused" : (module.isFinished ? "Time's Up" : "Timer"), systemImage: module.isFinished ? "alarm.fill" : "timer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                TimerReadout(module: module)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(module.isFinished ? .red : .orange)
            }
            Spacer(minLength: 0)
            // Clock offers no way to pause or cancel from outside, so the one
            // action is to open it.
            Button {
                module.openClock()
            } label: {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Clock")
        }
    }
}
