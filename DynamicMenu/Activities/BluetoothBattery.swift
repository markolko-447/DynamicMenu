//
//  BluetoothBattery.swift
//  DynamicMenu
//
//  Battery levels of connected Bluetooth devices, such as AirPods. macOS has no
//  public API for them; the Bluetooth report from `system_profiler` lists the
//  levels of the connected devices, so that is read (off the main thread: it
//  takes a second or so).
//

import Foundation

struct BluetoothBattery: Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var main: Int?

    /// The single number for a small slot: the lower earbud, or the device itself.
    var summary: Int? {
        if let main { return main }
        let buds = [left, right].compactMap { $0 }
        return buds.min() ?? caseLevel
    }

    /// Every level there is, for the expanded view.
    var detail: String {
        var parts: [String] = []
        if let main { parts.append("\(main)%") }
        if let left { parts.append("L \(left)%") }
        if let right { parts.append("R \(right)%") }
        if let caseLevel { parts.append("Case \(caseLevel)%") }
        return parts.joined(separator: "  ·  ")
    }

    /// A connected Bluetooth device that reports a battery level.
    struct Device: Equatable {
        var name: String
        /// What it is, as macOS calls it ("Headphones", "Keyboard", "Mouse"...).
        var kind: String
        var battery: BluetoothBattery

        /// SF Symbol for the device.
        var symbol: String {
            let lowercased = name.lowercased()
            if lowercased.contains("airpods max") { return "airpods.max" }
            if lowercased.contains("airpods pro") { return "airpods.pro" }
            if lowercased.contains("airpods") { return "airpods" }
            switch kind.lowercased() {
            case "keyboard": return "keyboard.fill"
            case "mouse": return "computermouse.fill"
            case "trackpad": return "rectangle.and.hand.point.up.left.fill"
            case "gamepad": return "gamecontroller.fill"
            default: return "headphones"
            }
        }
    }

    /// The levels of the connected device called `name`, nil if it reports none.
    nonisolated static func read(deviceNamed name: String) async -> BluetoothBattery? {
        await connected().first { $0.name == name }?.battery
    }

    /// Every connected device that reports a battery level, earbuds and headphones
    /// first. Takes a second or so: it runs `system_profiler`.
    nonisolated static func connected() async -> [Device] {
        await Task.detached(priority: .utility) { () -> [Device] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
            else { return [] }

            func level(_ info: [String: Any], _ key: String) -> Int? {
                (info[key] as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
            }
            var devices: [Device] = []
            for controller in controllers {
                for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                    for (name, value) in entry {
                        guard let info = value as? [String: Any] else { continue }
                        let battery = BluetoothBattery(
                            left: level(info, "device_batteryLevelLeft"),
                            right: level(info, "device_batteryLevelRight"),
                            caseLevel: level(info, "device_batteryLevelCase"),
                            main: level(info, "device_batteryLevelMain"))
                        guard battery.summary != nil else { continue }
                        devices.append(Device(name: name, kind: info["device_minorType"] as? String ?? "", battery: battery))
                    }
                }
            }
            return devices.sorted { ($0.kind == "Headphones" ? 0 : 1, $0.name) < ($1.kind == "Headphones" ? 0 : 1, $1.name) }
        }.value
    }
}
