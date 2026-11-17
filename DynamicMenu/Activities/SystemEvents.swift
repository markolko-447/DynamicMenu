//
//  SystemEvents.swift
//  DynamicMenu
//
//  Watches the system for short-lived events and turns each into a Flash.
//

import AppKit
import SwiftUI
import CoreAudio

final class SystemEvents {
    private let flash: FlashModule

    private var outputDevice: AudioDeviceID?
    private var lastBrightness: Float?
    private var lastCapsLock = false
    private var pollTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(flash: FlashModule) {
        self.flash = flash
    }

    func start() {
        guard pollTask == nil else { return }
        observeAudio()
        observeNotifications()
        startPolling()
    }

    // MARK: - Volume and audio output

    private func observeAudio() {
        // The default output can change (AirPods connect), so watch the system
        // object for that and move the volume listeners to the new device.
        AudioHardware.listen(AudioObjectID(kAudioObjectSystemObject),
                             kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.outputDeviceChanged(announce: true)
        }
        outputDeviceChanged(announce: false)
    }

    private func outputDeviceChanged(announce: Bool) {
        guard let device = AudioHardware.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
              device != outputDevice
        else { return }
        outputDevice = device

        for selector in [AudioHardware.virtualMainVolume, kAudioDevicePropertyMute] {
            AudioHardware.listen(device, selector, scope: kAudioDevicePropertyScopeOutput) { [weak self] in
                // Listeners stay attached to devices that are no longer the
                // default; ignore those.
                guard self?.outputDevice == device else { return }
                self?.volumeChanged()
            }
        }

        if announce, let name = AudioHardware.name(of: device) {
            let transport = AudioHardware.read(device, kAudioDevicePropertyTransportType, as: UInt32(0))
            let symbol = Self.symbol(forOutput: name, transport: transport)
            flash.show(Flash(kind: "output", symbol: symbol, title: name, detail: "Connected"), for: .seconds(3))

            // Bluetooth headphones report their battery a moment after they
            // connect; show it in place of "Connected" as soon as it is known.
            let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE
            if isBluetooth {
                Task { [weak self] in
                    for attempt in 0..<3 {
                        if let battery = await BluetoothBattery.read(deviceNamed: name) {
                            guard self?.outputDevice == device, let percent = battery.summary else { return }
                            self?.flash.show(Flash(kind: "output", symbol: symbol, tint: percent <= 20 ? .red : .white,
                                                   title: name, detail: "\(percent)%", subtitle: battery.detail),
                                             for: .seconds(4))
                            return
                        }
                        guard attempt < 2 else { return }
                        try? await Task.sleep(for: .seconds(1.5))
                    }
                }
            }
        }
    }

    private func volumeChanged() {
        guard let device = outputDevice else { return }
        let volume = AudioHardware.read(device, AudioHardware.virtualMainVolume,
                                        scope: kAudioDevicePropertyScopeOutput, as: Float32(0)) ?? 0
        let muted = (AudioHardware.read(device, kAudioDevicePropertyMute,
                                        scope: kAudioDevicePropertyScopeOutput, as: UInt32(0)) ?? 0) != 0
        let level = muted ? 0 : Double(volume)

        let symbol = switch level {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
        flash.show(Flash(kind: "volume", symbol: symbol, title: muted ? "Muted" : "Volume", level: level),
                   for: .seconds(1.6))
    }

    private static func symbol(forOutput name: String, transport: UInt32?) -> String {
        let lowercased = name.lowercased()
        if lowercased.contains("airpods max") { return "airpods.max" }
        if lowercased.contains("airpods pro") { return "airpods.pro" }
        if lowercased.contains("airpods") { return "airpods" }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeAirPlay: return "airplay.audio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        default: return "hifispeaker.fill"
        }
    }

    /// Like an iPhone after unlocking: the battery of the connected AirPods, or of
    /// another Bluetooth device. Shown once the "Unlocked" alert has had its moment.
    private func showBluetoothBatteries() {
        Task { [weak self] in
            async let devices = BluetoothBattery.connected()
            try? await Task.sleep(for: .seconds(1.8))
            guard let device = await devices.first, let percent = device.battery.summary else { return }
            self?.flash.show(Flash(kind: "bluetooth", symbol: device.symbol, tint: percent <= 20 ? .red : .white,
                                   title: device.name, detail: "\(percent)%", subtitle: device.battery.detail),
                             for: .seconds(4))
        }
    }

    // MARK: - Unlock, Low Power Mode

    private func observeNotifications() {
        let distributed = DistributedNotificationCenter.default()

        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flash.show(Flash(kind: "lock", symbol: "lock.open.fill", title: "Unlocked"), for: .seconds(2))
                self?.showBluetoothBatteries()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let isOn = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.flash.show(Flash(kind: "lowPower", symbol: "battery.50percent", tint: isOn ? .yellow : .green,
                                       title: "Low Power Mode", detail: isOn ? "On" : "Off"))
            }
        })
    }

    // MARK: - Brightness and Caps Lock

    /// Neither posts a notification an ordinary app can receive, so both are
    /// sampled a few times a second. Each sample is a cheap in-process read.
    private func startPolling() {
        lastCapsLock = NSEvent.modifierFlags.contains(.capsLock)
        lastBrightness = Brightness.current()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                self?.poll()
            }
        }
    }

    private func poll() {
        let capsLock = NSEvent.modifierFlags.contains(.capsLock)
        if capsLock != lastCapsLock {
            lastCapsLock = capsLock
            flash.show(Flash(kind: "capsLock", symbol: capsLock ? "capslock.fill" : "capslock",
                             title: "Caps Lock", detail: capsLock ? "On" : "Off"), for: .seconds(1.6))
        }

        if let brightness = Brightness.current() {
            // A brightness key moves a sixteenth at a time. Automatic adjustment
            // to room light drifts far more slowly and should not raise an alert.
            if let last = lastBrightness, abs(brightness - last) >= 0.03 {
                flash.show(Flash(kind: "brightness", symbol: brightness > 0.5 ? "sun.max.fill" : "sun.min.fill",
                                 title: "Brightness", level: Double(brightness)), for: .seconds(1.6))
            }
            lastBrightness = brightness
        }
    }
}

// MARK: - Core Audio helpers

nonisolated enum AudioHardware {
    /// 'vmvc': the overall volume of a device, however many channels it has.
    static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<Value>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            as initial: Value) -> Value? {
        var address = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        guard let device = read(AudioObjectID(kAudioObjectSystemObject), selector, as: AudioDeviceID(0)),
              device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    static func name(of device: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    /// Calls `handler` on the main actor whenever the property changes.
    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       handler: @escaping @MainActor () -> Void) {
        var address = address(selector, scope)
        AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main) { _, _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}

// MARK: - Brightness

/// Brightness of the built-in display. macOS offers no public way to read it, so
/// this calls the private DisplayServices function the system itself uses; if it
/// is ever removed, brightness alerts simply stop.
nonisolated enum Brightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private static let getBrightness: GetBrightness? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness")
        else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    static func current() -> Float? {
        guard let getBrightness else { return nil }
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        guard CGGetOnlineDisplayList(8, &displays, &count) == .success,
              let builtIn = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 })
        else { return nil }

        var value: Float = 0
        return getBrightness(builtIn, &value) == 0 ? value : nil
    }
}
