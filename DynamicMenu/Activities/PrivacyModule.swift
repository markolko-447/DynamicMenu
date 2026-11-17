//
//  PrivacyModule.swift
//  DynamicMenu
//
//  Shows when any app is using the camera or the microphone, like the green and
//  orange indicators on iPhone.
//

import SwiftUI
import Observation
import CoreAudio
import CoreMediaIO

@Observable
final class PrivacyModule: ActivityModule {
    let id = "privacy"
    /// Background information: everything else takes precedence.
    let priority = 10

    private(set) var cameraInUse = false
    private(set) var microphoneInUse = false
    private(set) var activeSince = Date.distantPast
    /// Apps recording from the microphone right now, by name. macOS tells which
    /// processes record audio, but not which use the camera, so a video call
    /// shows through its microphone.
    private(set) var microphoneApps: [String] = []

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var isActive: Bool { cameraInUse || microphoneInUse }

    func start() {
        guard pollTask == nil else { return }
        // "Is running somewhere" is a plain property read on each device; once a
        // second is frequent enough for an indicator.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() {
        let camera = Self.isAnyCameraRunning()
        let microphone = Self.isMicrophoneRunning()
        let apps = microphone ? Self.appsRecordingAudio() : []
        if apps != microphoneApps { microphoneApps = apps }
        guard camera != cameraInUse || microphone != microphoneInUse else { return }
        if !isActive { activeSince = .now }
        cameraInUse = camera
        microphoneInUse = microphone
    }

    /// Names of the apps with an audio input running, from CoreAudio's process list
    /// (macOS 14.4 and later; it needs no permission). A helper process counts for
    /// the app it lives in, so a browser's audio process shows as the browser.
    private static func appsRecordingAudio() -> [String] {
        func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as value: T) -> T? {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var result = value
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == 0 ? result : nil
        }

        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == 0,
              size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == 0
        else { return [] }

        var names: [String] = []
        for process in processes {
            guard (property(process, kAudioProcessPropertyIsRunningInput, as: UInt32(0)) ?? 0) != 0,
                  let pid = property(process, kAudioProcessPropertyPID, as: pid_t(0)),
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let url = NSRunningApplication(processIdentifier: pid)?.bundleURL
            else { continue }
            // The outermost app bundle: Chrome's helper lives inside Chrome.app.
            let parts = url.pathComponents
            guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { continue }
            let path = "/" + parts[1...index].joined(separator: "/")
            let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            if !names.contains(name) { names.append(name) }
        }
        return names.sorted()
    }

    private static func isMicrophoneRunning() -> Bool {
        guard let device = AudioHardware.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return false }
        return (AudioHardware.read(device, kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32(0)) ?? 0) != 0
    }

    private static func isAnyCameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)

        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return false }

        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return devices.contains { device in
            var running: UInt32 = 0
            let status = CMIOObjectGetPropertyData(
                device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
            return status == 0 && running != 0
        }
    }

    // MARK: - Presentation

    /// Camera wins when both are in use, as on iPhone.
    var symbol: String { cameraInUse ? "video.fill" : "mic.fill" }
    var tint: Color { cameraInUse ? .green : .orange }

    /// Who is using it, when macOS says: "Zoom", or "Zoom and Safari".
    var appsText: String? {
        switch microphoneApps.count {
        case 0: nil
        case 1: microphoneApps[0]
        case 2: "\(microphoneApps[0]) and \(microphoneApps[1])"
        default: "\(microphoneApps[0]) and \(microphoneApps.count - 1) more"
        }
    }

    var statusText: String {
        switch (cameraInUse, microphoneInUse) {
        case (true, true): "Camera and Microphone in Use"
        case (true, false): "Camera in Use"
        default: "Microphone in Use"
        }
    }

    var compactLeading: AnyView {
        AnyView(Image(systemName: symbol).foregroundStyle(tint).symbolEffect(.pulse, options: .repeating))
    }

    var compactTrailing: AnyView {
        AnyView(PrivacyDot(module: self))
    }

    var minimal: AnyView {
        AnyView(Image(systemName: symbol).foregroundStyle(tint))
    }

    var expanded: AnyView {
        AnyView(PrivacyExpandedView(module: self))
    }
}

private struct PrivacyDot: View {
    let module: PrivacyModule
    @Environment(\.pillContentHeight) private var contentHeight

    var body: some View {
        Circle()
            .fill(module.tint)
            .frame(width: contentHeight * 0.4, height: contentHeight * 0.4)
            .accessibilityLabel(module.statusText)
    }
}

private struct PrivacyExpandedView: View {
    let module: PrivacyModule

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: module.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(module.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.statusText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if let apps = module.appsText {
                    Text(apps)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
