//
//  ScreenManager.swift
//  DynamicMenu
//
//  Keeps one pill panel per eligible display, rebuilt whenever displays change.
//

import AppKit
import Observation

@Observable
final class ScreenManager {
    static let shared = ScreenManager()

    private(set) var displays: [DisplayInfo] = []

    @ObservationIgnored private var panels: [CGDirectDisplayID: PillPanelEntry] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { ScreenManager.shared.refresh() }
        }
        refresh()
    }

    func setOverride(_ mode: ModeOverride, for display: DisplayInfo) {
        var updated = display
        updated.override = mode
        updated.saveOverride()
        refresh()
    }

    /// Displays connect, disconnect and change resolution rarely, but macOS also
    /// posts "screen parameters changed" for things that change nothing visible
    /// (a camera app opening, a colour profile). Rebuilding a pill for those made
    /// it vanish and grow back from scratch, so a pill is only rebuilt when its
    /// display's frame, style or identity really changed.
    func refresh() {
        var infos: [DisplayInfo] = []
        var kept: [CGDirectDisplayID: PillPanelEntry] = [:]
        for screen in NSScreen.screens {
            guard let info = DisplayInfo(screen: screen) else { continue }
            infos.append(info)
            guard let style = info.style else { continue }
            let signature = "\(screen.frame)|\(style)|\(info.uuid)"
            if let existing = panels[info.id], existing.signature == signature {
                kept[info.id] = existing
            } else {
                panels[info.id]?.panel.close()
                kept[info.id] = PillPanelEntry(
                    signature: signature,
                    panel: PillPanel(screen: screen, style: style, displayUUID: info.uuid))
            }
        }
        // Displays that went away (or no longer get a pill).
        for (id, entry) in panels where kept[id] == nil { entry.panel.close() }
        panels = kept
        displays = infos
        refreshReserve()
    }

    func refreshReserve() {
        MenuBarReserve.shared.update(models: panels.values.compactMap(\.panel.model))
    }
}

/// A pill window with what it was built for.
private struct PillPanelEntry {
    let signature: String
    let panel: PillPanel
}
