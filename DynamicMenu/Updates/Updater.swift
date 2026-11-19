//
//  Updater.swift
//  DynamicMenu
//

import Sparkle
import SwiftUI

/// Checks for new versions with Sparkle. The feed address and the public key
/// that verifies each download live in the app's Info.plist (`SUFeedURL` and
/// `SUPublicEDKey`), so nothing here needs to know about either.
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = Updater()

    /// False while a check is already running.
    private(set) var canCheck = false

    /// Mirrors Sparkle's own setting, which it keeps in the user's defaults.
    var automaticallyChecks = false {
        didSet {
            guard automaticallyChecks != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override private init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        let updater = controller.updater
        canCheck = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.canCheck = change.newValue ?? false }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.automaticallyChecks = change.newValue ?? false }
            },
        ]
    }

    /// Call once the app has launched.
    func start() {
        #if DEBUG
        // For testing an update against a feed on this Mac. Release builds
        // cannot be pointed anywhere but the real feed.
        if ProcessInfo.processInfo.environment["DYNAMICMENU_CHECK_NOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.checkForUpdates() }
        }
        #endif
    }

    #if DEBUG
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["DYNAMICMENU_FEED_URL"]
    }
    #endif

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// DynamicMenu has no Dock icon, so Sparkle needs to say when it is allowed
    /// to bring an update window forward by itself.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        // A window opened by a background check would otherwise stay behind the
        // front app.
        if handleShowingUpdate { NSApp.activate() }
    }
}
