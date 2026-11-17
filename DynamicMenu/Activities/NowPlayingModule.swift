//
//  NowPlayingModule.swift
//  DynamicMenu
//
//  System-wide Now Playing: whatever macOS itself reports, from any app, including
//  video and audio in browsers.
//
//  The data comes from the private MediaRemote framework through a helper process
//  (see NowPlayingBridge below and Helper/NowPlayingBridge.m). Favourite and
//  Suggest Less are not part of that data; they exist only for Music, through
//  AppleScript.
//
//  Each app gets its own session. When a second app starts playing, the first
//  one's session stays, so the pill can show it in a bubble.
//

import AppKit
import SwiftUI
import Observation
import CoreImage

/// Owns the helper and one session per app.
@Observable
final class MediaCenter {
    private(set) var sessions: [NowPlayingModule] = []

    @ObservationIgnored private var bridge: NowPlayingBridge?
    /// The app macOS currently treats as Now Playing.
    @ObservationIgnored private var currentKey: String?

    func start() {
        guard bridge == nil else { return }
        bridge = NowPlayingBridge { [weak self] update in
            self?.route(update)
        }
        bridge?.launch()
    }

    fileprivate func send(_ command: String, to session: NowPlayingModule) {
        bridge?.send(session.isCurrent ? command : "\(command) @\(session.app)")
    }

    private func session(for key: String) -> NowPlayingModule {
        if let existing = sessions.first(where: { $0.app == key }) { return existing }
        let session = NowPlayingModule(app: key, center: self)
        sessions.append(session)
        return session
    }

    private func route(_ update: NowPlayingUpdate) {
        let key = update.app ?? "system"

        if update.background == true {
            // Only sessions we already know about; ignore stray reports.
            guard let session = sessions.first(where: { $0.app == key }) else { return }
            session.apply(update)
            if update.title.isEmpty { sessions.removeAll { $0 === session } }
            return
        }

        guard !update.title.isEmpty else {
            // Nothing is Now Playing any more.
            if let currentKey { session(for: currentKey).apply(update) }
            currentKey = nil
            return
        }

        if let previous = currentKey, previous != key {
            // Another app took over. Keep the old one; the helper reports on it
            // separately if the system still knows it.
            session(for: previous).moveToBackground()
        }
        currentKey = key
        for session in sessions { session.isCurrent = session.app == key }
        session(for: key).apply(update)
    }
}

@Observable
final class NowPlayingModule: ActivityModule {
    let id: String
    /// Below the short alerts (battery, volume, Wi-Fi, lock) and a finished timer,
    /// above everything long-running.
    let priority = 80
    /// Bundle identifier of the app, or "system" when unknown.
    let app: String
    /// True while this is the session macOS treats as Now Playing. Only that one
    /// can be seeked.
    fileprivate(set) var isCurrent = true

    private(set) var title = ""
    private(set) var artist = ""
    private(set) var artwork: NSImage?
    /// Bright colour taken from the artwork; tints the waveform as on iPhone.
    private(set) var tint = Color.white
    private(set) var isPlaying = false
    private(set) var isActive = false
    private(set) var activeSince = Date.distantPast

    /// Track length in seconds; 0 when unknown (e.g. a live stream).
    private(set) var duration: TimeInterval = 0
    private(set) var isFavorite = false
    private(set) var isSuggestedLess = false
    /// True only while Music is the app that is playing.
    private(set) var supportsRating = false

    /// The system reports a position together with the moment it was measured;
    /// the current position is extrapolated from that while playing.
    private var positionAnchor: TimeInterval = 0
    private var anchorDate = Date.now
    private var rate = 1.0

    @ObservationIgnored private weak var center: MediaCenter?
    @ObservationIgnored private var trackKey = ""
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    /// Waiting to confirm that nothing is Now Playing any more.
    @ObservationIgnored private var dropTask: Task<Void, Never>?
    @ObservationIgnored private var ratingTask: Task<Void, Never>?

    private static let musicBundleID = "com.apple.Music"

    fileprivate init(app: String, center: MediaCenter) {
        self.app = app
        self.center = center
        id = "nowPlaying." + app
    }

    /// Sessions are driven by MediaCenter.
    func start() {}

    func position(at date: Date) -> TimeInterval {
        let elapsed = isPlaying ? date.timeIntervalSince(anchorDate) * rate : 0
        let position = positionAnchor + elapsed
        return duration > 0 ? min(max(position, 0), duration) : max(position, 0)
    }

    // MARK: - Controls

    func togglePlayPause() { send("toggle") }
    func nextTrack() { send("next") }
    func previousTrack() { send("previous") }

    private func send(_ command: String) {
        // Never risk a command meant for this session reaching another player.
        guard canControl else { return }
        center?.send(command, to: self)
    }

    /// Whether the controls reach this session. A browser only accepts commands
    /// while it is the main Now Playing app; sent anything while in the
    /// background, macOS passes the command on to the main player instead.
    var canControl: Bool { isCurrent || !Self.isBrowser(app) }

    /// Display name of the app, e.g. "Dia".
    var appName: String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return "App" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Brings the app forward, so the user can control it there.
    func showApp() {
        NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.activate()
    }

    /// Any app that can open web links counts as a browser.
    private static let browsers: Set<String> = {
        guard let link = URL(string: "https://example.com") else { return [] }
        return Set(NSWorkspace.shared.urlsForApplications(toOpen: link)
            .compactMap { Bundle(url: $0)?.bundleIdentifier })
    }()

    private static func isBrowser(_ bundleID: String) -> Bool {
        browsers.contains(bundleID)
    }

    var canSeek: Bool { isCurrent && duration > 0 }

    func seek(to seconds: TimeInterval) {
        guard canSeek else { return }
        positionAnchor = min(max(seconds, 0), duration)
        anchorDate = .now
        center?.send(String(format: "seek %.2f", positionAnchor), to: self)
    }

    func toggleFavorite() {
        guard supportsRating else { return }
        isFavorite.toggle()
        if isFavorite { isSuggestedLess = false }
        setRating("set favorited of current track to \(isFavorite)")
    }

    func toggleSuggestLess() {
        guard supportsRating else { return }
        isSuggestedLess.toggle()
        if isSuggestedLess { isFavorite = false }
        setRating("set disliked of current track to \(isSuggestedLess)")
    }

    private func setRating(_ command: String) {
        Task {
            await AppleScript.run("tell application id \"\(Self.musicBundleID)\" to \(command)")
            // Music has the final say, e.g. if a track cannot be rated.
            refreshRating()
        }
    }

    private func refreshRating() {
        let script = """
        tell application id "\(Self.musicBundleID)"
            return (favorited of current track as text) & linefeed & (disliked of current track as text)
        end tell
        """
        ratingTask?.cancel()
        ratingTask = Task { [weak self] in
            guard let lines = await AppleScript.run(script)?.string?.components(separatedBy: "\n"),
                  lines.count == 2, !Task.isCancelled, let self
            else { return }
            self.isFavorite = lines[0] == "true"
            self.isSuggestedLess = lines[1] == "true"
        }
    }

    // MARK: - State

    /// Another app became Now Playing. Until the helper reports on this one, show
    /// it paused rather than guess that it is still playing.
    fileprivate func moveToBackground() {
        isCurrent = false
        positionAnchor = position(at: .now)
        anchorDate = .now
        isPlaying = false
        startLinger()
    }

    private func startLinger() {
        guard isActive, lingerTask == nil else { return }
        // Stay visible for a while so the user can resume from the pill.
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppSettings.shared.mediaLingerSeconds))
            guard !Task.isCancelled else { return }
            self?.isActive = false
            self?.lingerTask = nil
        }
    }

    fileprivate func apply(_ update: NowPlayingUpdate) {
        guard !update.title.isEmpty else {
            // Nothing is registered as Now Playing any more. macOS reports that
            // briefly whenever audio routing changes (a call starting, the
            // microphone opening), so wait a moment before believing it: the
            // pill must not shrink away and come back for a blip.
            guard isActive, dropTask == nil else { return }
            dropTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled, let self else { return }
                self.dropTask = nil
                self.lingerTask?.cancel()
                self.isPlaying = false
                self.isActive = false
                self.trackKey = ""
            }
            return
        }
        // Playing again: it was only a blip.
        dropTask?.cancel()
        dropTask = nil

        if update.track != trackKey {
            trackKey = update.track
            artwork = nil
            tint = .white
            isFavorite = false
            isSuggestedLess = false
            supportsRating = update.app == Self.musicBundleID
            if supportsRating { refreshRating() }
        }
        if let encoded = update.artwork, let data = Data(base64Encoded: encoded) {
            artwork = NSImage(data: data)
            tint = ArtworkColor.tint(of: data) ?? .white
        }

        title = update.title
        artist = update.artist
        duration = update.duration
        positionAnchor = update.elapsed
        anchorDate = update.timestamp.map(Date.init(timeIntervalSince1970:)) ?? .now
        rate = update.rate > 0 ? update.rate : 1
        isPlaying = update.playing

        if update.playing {
            lingerTask?.cancel()
            lingerTask = nil
            if !isActive {
                activeSince = .now
                isActive = true
            }
        } else {
            startLinger()
        }
    }

    // MARK: - Presentation

    var compactLeading: AnyView {
        AnyView(ArtworkView(module: self))
    }

    var compactTrailing: AnyView {
        AnyView(AudioBars(module: self))
    }

    var minimal: AnyView {
        AnyView(ArtworkView(module: self))
    }

    var expanded: AnyView {
        AnyView(NowPlayingExpandedView(module: self))
    }
}

private struct ArtworkView: View {
    let module: NowPlayingModule
    /// Nil fills the height the pill offers (the compact slot).
    var size: CGFloat?

    @Environment(\.pillContentHeight) private var contentHeight
    @Environment(\.pillInnerRadius) private var innerRadius

    var body: some View {
        let size = size ?? contentHeight
        // A rounded square like the iPhone's, never a circle: concentric with the
        // pill's corner where that is tighter, otherwise a quarter of the side.
        let cornerRadius = min(innerRadius, size * 0.25)
        Group {
            if let artwork = module.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.14)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// The Now Playing waveform: six thin capsules centred on the midline, tallest in
/// the middle, tinted from the artwork. Each bar follows two sine waves at unrelated
/// speeds so the motion never visibly repeats. Paused, the bars rest as dots.
private struct AudioBars: View {
    let module: NowPlayingModule

    @Environment(\.pillContentHeight) private var contentHeight

    private static let barWidth: CGFloat = 2
    /// Peak height of each bar as a share of the full height.
    private static let envelope: [Double] = [0.45, 0.75, 1, 0.9, 0.7, 0.4]

    var body: some View {
        let full = min(contentHeight * 0.85, 18)
        TimelineView(.animation(paused: !module.isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 1.5) {
                ForEach(Self.envelope.indices, id: \.self) { index in
                    Capsule()
                        .fill(module.tint)
                        .frame(width: Self.barWidth, height: height(of: index, at: time, full: full))
                }
            }
            .frame(height: full)
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: module.isPlaying)
        .accessibilityHidden(true)
    }

    private func height(of index: Int, at time: TimeInterval, full: CGFloat) -> CGFloat {
        guard module.isPlaying else { return Self.barWidth }
        let i = Double(index)
        let wave = 0.5 + 0.3 * sin(time * (5.3 + i * 0.7) + i * 1.9)
                       + 0.2 * sin(time * (8.9 - i * 0.5) + i * 0.6)
        return max(Self.barWidth, full * Self.envelope[index] * wave)
    }
}

/// Picks a bright, legible colour from album artwork.
private nonisolated enum ArtworkColor {
    static func tint(of data: Data) -> Color? {
        guard let image = CIImage(data: data),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: image,
                kCIInputExtentKey: CIVector(cgRect: image.extent),
              ]),
              let output = filter.outputImage
        else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        let average = NSColor(
            srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // An average is usually muddy; lift it so it reads on black. Near-grey
        // artwork stays white rather than picking up a random hue.
        guard saturation > 0.12 else { return .white }
        return Color(hue: hue, saturation: min(max(saturation * 1.4, 0.45), 0.85), brightness: 0.95)
    }
}

private struct NowPlayingExpandedView: View {
    let module: NowPlayingModule

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ArtworkView(module: module, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(module.artist)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                AudioBars(module: module)
            }

            Scrubber(module: module)

            if module.canControl {
                transport
            } else {
                // A browser in the background: say so rather than show controls
                // that cannot reach it.
                Button(action: module.showApp) {
                    Label("Open \(module.appName) to Control", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var transport: some View {
            HStack(spacing: 0) {
                rating(module.isFavorite ? "star.fill" : "star",
                       label: module.isFavorite ? "Remove from Favourites" : "Add to Favourites",
                       isOn: module.isFavorite, action: module.toggleFavorite)
                Spacer(minLength: 0)
                HStack(spacing: 30) {
                    control("backward.fill", label: "Previous Track", action: module.previousTrack)
                    control(module.isPlaying ? "pause.fill" : "play.fill",
                            label: module.isPlaying ? "Pause" : "Play",
                            size: 24, action: module.togglePlayPause)
                    control("forward.fill", label: "Next Track", action: module.nextTrack)
                }
                Spacer(minLength: 0)
                rating(module.isSuggestedLess ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                       label: module.isSuggestedLess ? "Undo Suggest Less" : "Suggest Less",
                       isOn: module.isSuggestedLess, action: module.toggleSuggestLess)
            }
    }

    /// Favourite / Suggest Less. Hidden, but still taking up its space, for players
    /// that do not support it, so the transport controls stay centred.
    private func rating(_ symbol: String, label: String, isOn: Bool,
                        action: @escaping () -> Void) -> some View {
        control(symbol, label: label, size: 16, opacity: isOn ? 1 : 0.6, action: action)
            .opacity(module.supportsRating ? 1 : 0)
            .disabled(!module.supportsRating)
    }

    private func control(_ symbol: String, label: String, size: CGFloat = 18, opacity: Double = 1,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(opacity))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Elapsed time, a draggable progress line, and time remaining. The line thickens
/// under the pointer and while dragging, as the system scrubber does.
private struct Scrubber: View {
    let module: NowPlayingModule

    /// Position under the pointer while dragging, as a share of the track.
    @State private var dragFraction: Double?
    @State private var isHovering = false

    private var isEngaged: Bool { isHovering || dragFraction != nil }

    var body: some View {
        TimelineView(.periodic(from: .distantPast, by: 0.5)) { context in
            let duration = module.duration
            let position = dragFraction.map { $0 * duration } ?? module.position(at: context.date)
            let fraction = duration > 0 ? position / duration : 0

            HStack(spacing: 8) {
                Text(Self.time(position))
                    .fixedSize()
                    .frame(minWidth: 40, alignment: .leading)

                GeometryReader { proxy in
                    // The played part is a full-width bar scaled from the left
                    // and clipped by the track. Scaling never re-lays-out, so the
                    // bar cannot blink when the track changes thickness.
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .overlay {
                            Rectangle()
                                .fill(.white)
                                .opacity(isEngaged ? 1 : 0.75)
                                .scaleEffect(x: fraction, anchor: .leading)
                                // Glide between half-second ticks, but track a drag exactly.
                                .animation(dragFraction == nil ? .linear(duration: 0.5) : nil, value: fraction)
                        }
                        .clipShape(Capsule())
                        .frame(height: isEngaged ? 8 : 5)
                        .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { dragFraction = Self.fraction(at: $0.location.x, in: proxy.size.width) }
                            .onEnded {
                                module.seek(to: Self.fraction(at: $0.location.x, in: proxy.size.width) * duration)
                                dragFraction = nil
                            }
                    )
                }
                .frame(height: 16)
                .onHover { isHovering = $0 }

                Text("-" + Self.time(max(duration - position, 0)))
                    .fixedSize()
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .animation(.spring(duration: 0.25, bounce: 0.2), value: isEngaged)
        // A session in the background can be played and paused but not seeked.
        .opacity(module.canSeek ? 1 : 0.4)
        .disabled(!module.canSeek)
        .accessibilityElement()
        .accessibilityLabel("Playback Position")
    }

    private static func fraction(at x: CGFloat, in width: CGFloat) -> Double {
        width > 0 ? min(max(x / width, 0), 1) : 0
    }

    private static func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Bridge to the system Now Playing service

/// One line of output from the helper.
nonisolated struct NowPlayingUpdate: Decodable, Sendable {
    var playing: Bool
    var title: String
    var artist: String
    var duration: Double
    var elapsed: Double
    var rate: Double
    /// When `elapsed` was measured, in seconds since 1970.
    var timestamp: Double?
    /// Bundle identifier of the app that is playing.
    var app: String?
    /// Changes when the track does.
    var track: String
    /// Base64 image data; sent once per track.
    var artwork: String?
    /// True for an app that played earlier and is no longer Now Playing.
    var background: Bool?
}

/// Runs the helper library inside /usr/bin/perl and exchanges lines with it.
///
/// macOS only gives Now Playing data to Apple-signed processes. Perl is one, and
/// it can load a library and call into it, so the helper lives there. If Apple
/// closes this route the helper simply produces nothing and the module stays idle.
nonisolated final class NowPlayingBridge: @unchecked Sendable {
    private static let perlProgram = #"""
    use DynaLoader;
    my $library = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $symbol = DynaLoader::dl_find_symbol($library, "dm_now_playing_stream") or die "missing entry point";
    my $entry = DynaLoader::dl_install_xsub("main::dm_now_playing_stream", $symbol);
    &$entry();
    """#

    private let onUpdate: @MainActor (NowPlayingUpdate) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var input: FileHandle?
    private var restarts = 0

    init(onUpdate: @escaping @MainActor (NowPlayingUpdate) -> Void) {
        self.onUpdate = onUpdate
    }

    func launch() {
        guard let library = Bundle.main.url(forResource: "NowPlayingBridge", withExtension: "bin") else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.perlProgram, library.path]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.receive(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.relaunchAfterExit()
        }

        do {
            try process.run()
            lock.withLock {
                self.input = input.fileHandleForWriting
                buffer.removeAll()
            }
        } catch {
            // Perl is missing or blocked: Now Playing stays off.
        }
    }

    /// Commands: toggle, play, pause, next, previous, seek <seconds>.
    func send(_ command: String) {
        let handle = lock.withLock { input }
        try? handle?.write(contentsOf: Data((command + "\n").utf8))
    }

    private func receive(_ data: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        for line in lines {
            guard let update = try? JSONDecoder().decode(NowPlayingUpdate.self, from: line) else { continue }
            Task { @MainActor in self.onUpdate(update) }
        }
    }

    /// The helper should run for as long as the app does. If it dies, try again a
    /// few times, then give up rather than loop forever.
    private func relaunchAfterExit() {
        let attempt = lock.withLock { () -> Int in
            input = nil
            restarts += 1
            return restarts
        }
        guard attempt <= 5 else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.launch()
        }
    }
}
