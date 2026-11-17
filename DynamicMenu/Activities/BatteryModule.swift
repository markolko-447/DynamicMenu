//
//  BatteryModule.swift
//  DynamicMenu
//
//  Flashes the pill briefly when power is connected or removed, and when the
//  battery runs low.
//

import AppKit
import SwiftUI
import Observation
import IOKit.ps

@Observable
final class BatteryModule: ActivityModule {
    /// A singleton because the IOKit callback is a C function and cannot capture.
    static let shared = BatteryModule()

    let id = "battery"
    let priority = 100

    /// Nil on Macs without a battery.
    private(set) var percent: Int?
    private(set) var isPluggedIn = false
    private(set) var isCharging = false
    private(set) var isActive = false
    private(set) var activeSince = Date.distantPast

    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var isObserving = false

    private static let lowThreshold = 20

    var isLow: Bool { !isPluggedIn && (percent ?? 100) <= Self.lowThreshold }

    func start() {
        guard !isObserving else { return }
        isObserving = true
        read()
        let source = IOPSNotificationCreateRunLoopSource(batteryPowerSourceChanged, nil).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    fileprivate func powerSourceChanged() {
        let wasPluggedIn = isPluggedIn
        let previous = percent
        read()
        guard let percent else { return }

        let crossedLow = !isPluggedIn
            && (previous ?? 100) > Self.lowThreshold
            && percent <= Self.lowThreshold
        if wasPluggedIn != isPluggedIn || crossedLow {
            flash()
        }
    }

    private func flash() {
        dismissTask?.cancel()
        activeSince = .now
        isActive = true
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.isActive = false
        }
    }

    private func read() {
        percent = nil
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = info[kIOPSMaxCapacityKey] as? Int, capacity > 0
            else { continue }

            percent = current * 100 / capacity
            isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
            isPluggedIn = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return
        }
    }

    // MARK: - Presentation

    var tint: Color { isLow ? .red : .green }

    var symbol: String {
        if isPluggedIn { return "bolt.fill" }
        switch percent ?? 100 {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var statusText: String {
        if isCharging { return "Charging" }
        if isPluggedIn { return "Power Connected" }
        return isLow ? "Low Battery" : "On Battery"
    }

    var compactLeading: AnyView {
        AnyView(BatteryIcon(module: self))
    }

    var compactTrailing: AnyView {
        AnyView(BatteryPercent(module: self))
    }

    var minimal: AnyView {
        AnyView(BatteryIcon(module: self))
    }

    var expanded: AnyView {
        AnyView(BatteryExpandedView(module: self))
    }
}

/// IOKit calls this on the main run loop, the one the source was added to.
private nonisolated func batteryPowerSourceChanged(_ context: UnsafeMutableRawPointer?) {
    MainActor.assumeIsolated {
        BatteryModule.shared.powerSourceChanged()
    }
}

private struct BatteryIcon: View {
    let module: BatteryModule

    var body: some View {
        Image(systemName: module.symbol)
            .foregroundStyle(module.tint)
            .contentTransition(.symbolEffect(.replace))
            // The charging bolt breathes while it charges.
            .symbolEffect(.pulse, options: .repeating, isActive: module.isCharging)
    }
}

private struct BatteryPercent: View {
    let module: BatteryModule

    var body: some View {
        Text("\(module.percent ?? 0)%")
            .monospacedDigit()
            .foregroundStyle(module.tint)
    }
}

private struct BatteryExpandedView: View {
    let module: BatteryModule

    var body: some View {
        HStack(spacing: 16) {
            BatteryIcon(module: module)
                .font(.system(size: 34, weight: .semibold))
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                BatteryPercent(module: module)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Demo content (for the state renderer and --demo)

extension BatteryModule {
    static func demo(percent: Int, pluggedIn: Bool) -> BatteryModule {
        let module = BatteryModule()
        module.percent = percent
        module.isPluggedIn = pluggedIn
        module.isCharging = pluggedIn
        module.isActive = true
        module.activeSince = .now
        return module
    }
}
