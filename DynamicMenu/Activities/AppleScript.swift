//
//  AppleScript.swift
//  DynamicMenu
//

import Foundation

/// Runs AppleScript off the main thread. The first script sent to an app makes macOS
/// ask the user for Automation permission; a refusal simply returns nil here.
nonisolated enum AppleScript {
    struct Output: Sendable {
        var string: String?
        var data: Data?
    }

    /// Serial, so scripts never run concurrently (NSAppleScript is not thread-safe).
    private static let queue = DispatchQueue(label: "DynamicMenu.AppleScript", qos: .userInitiated)

    @discardableResult
    static func run(_ source: String) async -> Output? {
        let target = targetBundleID(in: source)
        return await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let target {
                    // Remember the answer per app, so the Permissions page can show
                    // it even while that app is closed (macOS only answers then).
                    let code = error?[NSAppleScript.errorNumber] as? Int
                    if code == notPermitted {
                        AutomationRecord.set(.denied, for: target)
                    } else if error == nil {
                        AutomationRecord.set(.granted, for: target)
                    }
                }
                guard error == nil, let result else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Output(string: result.stringValue, data: result.data))
            }
        }
    }

    /// errAEEventNotPermitted: the user refused Automation for this app.
    private static let notPermitted = -1743

    /// The app a script addresses with `tell application id "…"`.
    static func targetBundleID(in source: String) -> String? {
        guard let start = source.range(of: "application id \""),
              let end = source[start.upperBound...].firstIndex(of: "\"")
        else { return nil }
        return String(source[start.upperBound..<end])
    }
}

/// The last Automation answer seen for each app the app has scripted.
nonisolated enum AutomationRecord {
    enum State: String { case granted, denied }

    private static let key = "automationStates"

    static func set(_ state: State, for bundleID: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all[bundleID] = state.rawValue
        UserDefaults.standard.set(all, forKey: key)
    }

    static func state(for bundleID: String) -> State? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[bundleID].flatMap(State.init)
    }

    /// Every app the app has tried to script.
    static var apps: [String] {
        Array((UserDefaults.standard.dictionary(forKey: key) ?? [:]).keys).sorted()
    }
}
