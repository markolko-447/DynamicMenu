//
//  MenuBarReserve.swift
//  DynamicMenu
//
//  Optional: keeps the menu bar's icons out from under the pill. macOS lays
//  status items out from the right and hides the ones that don't fit, and it knows
//  only the physical notch. An empty status item as wide as the pill's overhang
//  to the right of the notch takes that room, so the icons are laid out around it.
//  Apps' own menus on the left can't be reserved for; those belong to each app.
//

import AppKit
import Observation

@MainActor
final class MenuBarReserve {
    static let shared = MenuBarReserve()

    private var item: NSStatusItem?
    private var models: [PillModel] = []

    /// Called after every change of displays or of the setting.
    func update(models: [PillModel]) {
        self.models = models.filter { if case .notch = $0.style { true } else { false } }
        guard AppSettings.shared.reservesMenuBarSpace, !self.models.isEmpty else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            let created = NSStatusBar.system.statusItem(withLength: 0)
            created.button?.isEnabled = false
            created.behavior = []
            item = created
        }
        track()
    }

    /// How far the pill, and the bubble beside it, reach past the notch on the
    /// right. Mirrors the pill's own sizing: the compact pill's flare, a
    /// bubble as wide as its content plus margins (never narrower than tall), and
    /// the extra a hover adds, so the room is already there when it swells.
    private func overhang() -> CGFloat {
        let flare: CGFloat = 6
        let hover: CGFloat = 8
        var most: CGFloat = 0
        for model in models {
            let layout = model.layout
            let style = model.style
            guard layout.trailing > 0 || layout.bubble > 0 else { continue }
            var reach = layout.trailing + style.compactSideMargin + flare + hover
            if layout.bubble > 0 {
                let height = style.bubbleHeight(hovering: true)
                reach += PillStyle.bubbleSpacing + max(height, layout.bubble + style.compactMargin * 2)
            }
            most = max(most, reach)
        }
        return most.rounded(.up)
    }

    /// Re-reads the width whenever a pill's layout changes.
    private func track() {
        guard item != nil else { return }
        var width: CGFloat = 0
        withObservationTracking {
            width = overhang()
        } onChange: {
            Task { @MainActor in MenuBarReserve.shared.track() }
        }
        if item?.length != width { item?.length = width }
    }
}
