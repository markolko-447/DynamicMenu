//
//  MenuBarIcon.swift
//  DynamicMenu
//
//  The status-item symbol, drawn from the designer's artwork (the
//  MenuBarSeveral image, a pill with a bubble beside it) and mirroring the
//  real pill:
//    nothing running:      the pill alone, dimmed
//    one activity:         the pill alone
//    two or more:          the pill with its bubble
//  Template images, so macOS tints them for light, dark and the highlighted
//  menu bar like any system symbol.
//

import AppKit
import SwiftUI

enum MenuBarIconState: Equatable {
    case idle, one, several

    init(activeCount: Int) {
        self = switch activeCount {
        case 0: .idle
        case 1: .one
        default: .several
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: "DynamicMenu"
        case .one: "DynamicMenu, 1 activity"
        case .several: "DynamicMenu, several activities"
        }
    }
}

enum MenuBarIcon {
    /// Points. Menu bar items are 22 pt tall; system glyphs are about this high.
    private static let height: CGFloat = 15

    static func image(for state: MenuBarIconState) -> NSImage {
        let name = state == .several ? "MenuBarSeveral" : "MenuBarSingle"
        guard let artwork = NSImage(named: name), artwork.size.height > 0 else { return NSImage() }
        let size = CGSize(width: (artwork.size.width / artwork.size.height * height).rounded(), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            // Template images use only alpha, so the dimmed idle state stays a
            // proper menu bar glyph in every appearance.
            artwork.draw(in: rect, from: .zero, operation: .sourceOver, fraction: state == .idle ? 0.45 : 1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }
}

/// The status item's label. Re-renders when activities start or stop.
struct MenuBarIconView: View {
    private var activities = ActivityCenter.shared

    var body: some View {
        let state = MenuBarIconState(activeCount: activities.active.count)
        Image(nsImage: MenuBarIcon.image(for: state))
            .accessibilityLabel(state.accessibilityLabel)
    }
}
