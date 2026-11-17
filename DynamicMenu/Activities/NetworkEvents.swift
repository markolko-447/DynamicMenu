//
//  NetworkEvents.swift
//  DynamicMenu
//
//  Short alerts when the connection changes: Wi-Fi, Personal Hotspot, wired,
//  offline, and VPN.
//

import Foundation
import SwiftUI
import Network
import SystemConfiguration

final class NetworkEvents {
    private enum Link: Equatable {
        case offline, wifi, hotspot, wired, other
    }

    private let flash: FlashModule
    private let monitor = NWPathMonitor()
    private var link: Link?
    private var vpnActive: Bool?

    init(flash: FlashModule) {
        self.flash = flash
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let link = Self.link(for: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.update(link: link) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "DynamicMenu.Network"))
    }

    private nonisolated static func link(for path: NWPath) -> Link {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.wifi) {
            // macOS marks an iPhone's hotspot as an expensive Wi-Fi network.
            return path.isExpensive ? .hotspot : .wifi
        }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }

    private func update(link newLink: Link) {
        let vpn = Self.isVPNPrimary()
        // The first report is the state at launch, not a change.
        let isFirstReport = link == nil
        let linkChanged = newLink != link
        let vpnChanged = vpn != vpnActive
        link = newLink
        vpnActive = vpn
        guard !isFirstReport else { return }

        if vpnChanged {
            flash.show(Flash(kind: "vpn", symbol: vpn ? "lock.shield.fill" : "lock.open",
                             tint: vpn ? .blue : .white, title: "VPN", detail: vpn ? "Connected" : "Off"))
        } else if linkChanged {
            switch newLink {
            case .wifi:
                flash.show(Flash(kind: "network", symbol: "wifi", tint: .blue, title: "Wi-Fi", detail: "Connected"))
            case .hotspot:
                flash.show(Flash(kind: "network", symbol: "personalhotspot", tint: .green,
                                 title: "Personal Hotspot", detail: "Connected"))
            case .wired:
                flash.show(Flash(kind: "network", symbol: "cable.connector", title: "Ethernet", detail: "Connected"))
            case .offline:
                flash.show(Flash(kind: "network", symbol: "wifi.slash", tint: .red,
                                 title: "No Connection", detail: "Offline"))
            case .other:
                break
            }
        }
    }

    /// A VPN is "on" when traffic's primary route is a tunnel interface. Checking
    /// the primary route, not merely whether a tunnel exists, avoids counting the
    /// tunnels macOS keeps for its own services.
    private static func isVPNPrimary() -> Bool {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interface = global["PrimaryInterface"] as? String
        else { return false }
        return ["utun", "ipsec", "ppp", "tun", "tap"].contains { interface.hasPrefix($0) }
    }
}
