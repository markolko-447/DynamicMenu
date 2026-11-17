//
//  DisplayInfo.swift
//  DynamicMenu
//
//  What kind of top edge a screen has, and which presentation we give it.
//

import AppKit

/// What the hardware of a screen looks like, as far as we can tell.
enum DetectedMode: Equatable {
    /// Built-in display with a camera housing. Sizes are in points.
    case notch(width: CGFloat, height: CGFloat)
    /// Plain rectangle: external monitors and notchless built-in displays.
    case plain
    /// Built-in display that already has a system-drawn pill. We stay off it.
    case builtInPill

    var label: String {
        switch self {
        case .notch: "Notch"
        case .plain: "Pill"
        case .builtInPill: "Off, built-in pill"
        }
    }
}

/// The user's per-display choice, stored by display UUID.
enum ModeOverride: String, CaseIterable, Identifiable {
    case automatic, notch, pill, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .notch: "Notch"
        case .pill: "Pill"
        case .off: "Off"
        }
    }
}

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let detected: DetectedMode
    let menuBarHeight: CGFloat
    var override: ModeOverride

    init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        id = number.uint32Value
        uuid = Self.uuidString(for: id)
        name = screen.localizedName
        detected = Self.detect(screen: screen, displayID: id)

        let reserved = screen.frame.maxY - screen.visibleFrame.maxY
        // `reserved` is 0 when the menu bar auto-hides; fall back to its nominal thickness.
        menuBarHeight = reserved > 0 ? reserved : NSStatusBar.system.thickness

        override = UserDefaults.standard.string(forKey: Self.defaultsKey(uuid))
            .flatMap(ModeOverride.init(rawValue:)) ?? .automatic
    }

    /// The style to draw on this display, or nil to stay off it.
    var style: PillStyle? {
        switch (override, detected) {
        case (.off, _), (.automatic, .builtInPill):
            return nil

        case (.automatic, .notch(let width, let height)), (.notch, .notch(let width, let height)):
            return .notch(width: width, height: height)

        case (.notch, _):
            // A drawn notch on a screen that has none.
            return .notch(width: 190, height: menuBarHeight)

        case (.pill, .notch(_, let height)):
            // Float the pill just under the camera housing.
            return .pill(height: 28, topInset: height + 5)

        case (.automatic, .plain), (.pill, _):
            // The pill lives inside the menu bar so it never covers window content.
            let height = max(menuBarHeight - 6, 18)
            return .pill(height: height, topInset: (menuBarHeight - height) / 2)
        }
    }

    func saveOverride() {
        UserDefaults.standard.set(override.rawValue, forKey: Self.defaultsKey(uuid))
    }

    // MARK: - Detection

    private static func detect(screen: NSScreen, displayID: CGDirectDisplayID) -> DetectedMode {
        guard CGDisplayIsBuiltin(displayID) != 0 else { return .plain }

        if BuiltInPill.isPresent { return .builtInPill }

        let inset = screen.safeAreaInsets.top
        guard inset > 0 else { return .plain }

        // A notch leaves two unobscured strips beside it. A top inset without
        // them is not a notch: the display's own pill, which needs no help.
        guard let left = screen.auxiliaryTopLeftArea, !left.isEmpty,
              let right = screen.auxiliaryTopRightArea, !right.isEmpty
        else { return .builtInPill }

        // The housing is whatever the two unobscured strips leave uncovered.
        let width = screen.frame.width - left.width - right.width
        return width > 0 ? .notch(width: width, height: inset) : .plain
    }

    private static func uuidString(for displayID: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return "display-\(displayID)"
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func defaultsKey(_ uuid: String) -> String { "displayMode.\(uuid)" }
}

/// Macs whose built-in display already shows Apple's own pill.
///
/// AppKit exposes no public flag for this (NSScreen only reports the safe area and the
/// two auxiliary strips), so it is matched by model identifier. The list is empty until
/// the identifiers are confirmed on real hardware; until then use the per-display
/// "Off" override in the status menu.
enum BuiltInPill {
    static let modelIdentifiers: Set<String> = []

    static let isPresent: Bool = modelIdentifiers.contains(modelIdentifier)

    private static var modelIdentifier: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
