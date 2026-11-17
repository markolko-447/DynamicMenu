//
//  FlashModule.swift
//  DynamicMenu
//
//  Short system alerts: volume, brightness, a device connecting, the Mac unlocking.
//  They share one module because only the newest matters and each lasts seconds.
//

import SwiftUI
import Observation

/// What one alert shows.
struct Flash: Equatable {
    /// Alerts of the same kind update in place instead of restarting the animation.
    var kind: String
    var symbol: String
    var tint: Color = .white
    var title: String
    /// Short text for the compact slot; falls back to `title`.
    var detail: String?
    /// Longer text for the expanded view; falls back to `detail`.
    var subtitle: String?
    /// 0...1 draws a level bar instead of text (volume, brightness).
    var level: Double?
}

@Observable
final class FlashModule: ActivityModule {
    let id = "flash"
    /// Above long-running activities, below a finished timer.
    let priority = 90

    /// Kept after the alert ends so it can animate out with its content.
    private(set) var current: Flash?
    private(set) var isActive = false
    private(set) var activeSince = Date.distantPast

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func start() {}

    func show(_ flash: Flash, for duration: Duration = .seconds(2.5)) {
        guard AppSettings.shared.allowsFlash(kind: flash.kind) else { return }
        if !isActive || current?.kind != flash.kind {
            activeSince = .now
        }
        current = flash
        isActive = true

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.isActive = false
        }
    }

    var compactLeading: AnyView { AnyView(FlashIcon(module: self)) }
    var compactTrailing: AnyView { AnyView(FlashValue(module: self)) }
    var minimal: AnyView { AnyView(FlashIcon(module: self)) }
    var expanded: AnyView { AnyView(FlashExpandedView(module: self)) }
}

private struct FlashIcon: View {
    let module: FlashModule

    var body: some View {
        if let flash = module.current {
            Image(systemName: flash.symbol)
                .foregroundStyle(flash.tint)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

private struct FlashValue: View {
    let module: FlashModule

    var body: some View {
        if let flash = module.current {
            if let level = flash.level {
                LevelBar(level: level, tint: flash.tint)
                    .frame(width: 46, height: 5)
            } else {
                Text(flash.detail ?? flash.title)
                    .foregroundStyle(flash.tint)
                    .lineLimit(1)
                    .frame(maxWidth: 120)
                    .fixedSize()
            }
        }
    }
}

private struct FlashExpandedView: View {
    let module: FlashModule

    var body: some View {
        if let flash = module.current {
            HStack(spacing: 14) {
                Image(systemName: flash.symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(flash.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text(flash.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    if let level = flash.level {
                        LevelBar(level: level, tint: flash.tint)
                            .frame(height: 6)
                    } else if let detail = flash.subtitle ?? flash.detail, detail != flash.title {
                        Text(detail)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// A capsule that fills from the left.
struct LevelBar: View {
    let level: Double
    let tint: Color

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.22))
            .overlay {
                Rectangle()
                    .fill(tint)
                    .scaleEffect(x: min(max(level, 0), 1), anchor: .leading)
            }
            .clipShape(Capsule())
            .animation(.spring(duration: 0.25, bounce: 0), value: level)
            .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
    }
}

// MARK: - Demo content (for the state renderer and --demo)

extension FlashModule {
    /// Shows `flash` until released, whatever the alert settings say.
    static func demo(_ flash: Flash) -> FlashModule {
        let module = FlashModule()
        module.current = flash
        module.isActive = true
        module.activeSince = .now
        return module
    }
}
