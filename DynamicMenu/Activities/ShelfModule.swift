//
//  ShelfModule.swift
//  DynamicMenu
//
//  A place to park files: drop them on the pill, drag them out again later.
//
//  Files from Finder, the Desktop and Dock stacks are held by reference; nothing
//  is copied or moved. Content an app hands over rather than a file (Mail
//  attachments, Photos, images from a browser) is written to the app's cache
//  folder and deleted when the shelf is cleared or the app next launches.
//

import OSLog
import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import QuickLookThumbnailing

@Observable
final class ShelfModule: ActivityModule {
    let id = "shelf"
    let priority = 20

    private(set) var files: [URL] = []

    /// Whether a file stays on the shelf after it is dragged out and dropped in
    /// another app. Off by default: most of the time the shelf is a stop on the
    /// way somewhere.
    var keepsFilesAfterDragOut: Bool = UserDefaults.standard.bool(forKey: "shelf.keepAfterDragOut") {
        didSet { UserDefaults.standard.set(keepsFilesAfterDragOut, forKey: "shelf.keepAfterDragOut") }
    }

    /// The file being dragged out right now, if any.
    private(set) var draggingOut: URL?
    @ObservationIgnored private var droppedBack = false
    @ObservationIgnored private var dragSource: ShelfDragSource?
    private(set) var activeSince = Date.distantPast

    var isActive: Bool { !files.isEmpty }

    func start() {
        // Copies from a previous run are no longer on any shelf.
        try? FileManager.default.removeItem(at: Self.storage)
    }

    /// Whether a drag carries anything the shelf can take.
    nonisolated static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Takes a drop straight from the drag pasteboard. Returns whether anything
    /// was accepted.
    ///
    /// In order of preference:
    /// 1. File links (Finder, the Desktop, Dock stacks): kept where they are.
    /// 2. File promises (Mail attachments, Photos): the app writes the file into
    ///    our cache folder.
    /// 3. Plain image data (an image dragged from a web page): saved as a PNG.
    func accept(_ pasteboard: NSPasteboard) -> Bool {
        let types = (pasteboard.types ?? []).map(\.rawValue).joined(separator: ", ")
        Log.shelf.notice("Drop offered: \(types, privacy: .public)")

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            if let outgoing = draggingOut, urls.contains(outgoing) {
                // A file from the shelf dropped back onto the pill: not a move.
                droppedBack = true
                return true
            }
            urls.forEach(add)
            return true
        }

        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver], !promises.isEmpty {
            let folder = Self.storage.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for promise in promises {
                promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: Self.promiseQueue) {
                    [weak self] url, error in
                    if let error {
                        Log.shelf.error("Promised file failed: \(String(describing: error), privacy: .public)")
                        return
                    }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.add(url) }
                    }
                }
            }
            return true
        }

        if let image = (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first,
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let folder = Self.storage.appendingPathComponent(UUID().uuidString)
            let file = folder.appendingPathComponent("Image.png")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: file)
                add(file)
                return true
            } catch {
                Log.shelf.error("Image failed to save: \(String(describing: error), privacy: .public)")
            }
        }

        Log.shelf.notice("Drop refused: nothing usable")
        return false
    }

    /// Promised files are written on this queue, off the main thread.
    private nonisolated static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Where received copies live.
    private nonisolated static var storage: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "DynamicMenu")
            .appendingPathComponent("Shelf")
    }

    private func add(_ url: URL) {
        guard !files.contains(url) else { return }
        // Showing its thumbnail reads the file, which makes macOS ask about the
        // folder it is in; note that for the Permissions page.
        ProtectedFolder.containing(url)?.markUsed()
        if files.isEmpty { activeSince = .now }
        files.append(url)
        Log.shelf.notice("Added to shelf: \(url.lastPathComponent, privacy: .public)")
        // Confirm the drop where the user is looking; the shelf itself may sit
        // in a bubble behind whatever is playing.
        ActivityCenter.shared.flash.show(Flash(
            kind: "shelf", symbol: "tray.and.arrow.down.fill", title: "Added to Shelf",
            detail: files.count == 1 ? "1 file" : "\(files.count) files"), for: .seconds(2))
    }

    func remove(_ url: URL) {
        remove(url, deletingCopyAfter: .zero)
    }

    /// Removes a file. A copy the shelf made (from Mail, Photos, a web image) is
    /// deleted with it, after `delay`. Each copy has a folder of its own inside
    /// storage; the user's own files are never inside it, so they are never touched.
    private func remove(_ url: URL, deletingCopyAfter delay: Duration) {
        files.removeAll { $0 == url }
        let folder = url.deletingLastPathComponent()
        guard Self.isCopy(url) else { return }
        Task.detached {
            try? await Task.sleep(for: delay)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// True for files the shelf copied into its own folder.
    nonisolated static func isCopy(_ url: URL) -> Bool {
        url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
            == storage.standardizedFileURL
    }

    // MARK: - Dragging out

    /// Starts dragging `url` out of the shelf from the mouse event in progress.
    /// Done in AppKit rather than with SwiftUI's onDrag, because only AppKit
    /// reports how the drag ended, which decides whether the file leaves the shelf.
    func beginDragOut(_ url: URL) {
        guard draggingOut == nil,
              let event = NSApp.currentEvent,
              let view = event.window?.contentView
        else { return }

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let point = view.convert(event.locationInWindow, from: nil)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: icon)

        let source = ShelfDragSource(isCopy: Self.isCopy(url)) { [weak self] operation in
            self?.dragOutEnded(url, operation: operation)
        }
        dragSource = source
        draggingOut = url
        droppedBack = false
        view.beginDraggingSession(with: [item], event: event, source: source)
    }

    private func dragOutEnded(_ url: URL, operation: NSDragOperation) {
        let landedElsewhere = !operation.isEmpty && !droppedBack
        Log.shelf.notice("Drag out ended, operation \(operation.rawValue), dropped back: \(self.droppedBack)")
        draggingOut = nil
        dragSource = nil
        droppedBack = false
        guard landedElsewhere, !keepsFilesAfterDragOut else { return }
        // The receiving app may still be reading a copied file; give it time
        // before deleting the copy.
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
            remove(url, deletingCopyAfter: .seconds(120))
        }
    }

    func clear() {
        files.removeAll()
        try? FileManager.default.removeItem(at: Self.storage)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Presentation

    var compactLeading: AnyView {
        AnyView(Image(systemName: "tray.full.fill").foregroundStyle(.white))
    }

    var compactTrailing: AnyView {
        AnyView(ShelfCount(module: self))
    }

    var minimal: AnyView {
        AnyView(Image(systemName: "tray.full.fill").foregroundStyle(.white))
    }

    var expanded: AnyView {
        AnyView(ShelfExpandedView(module: self))
    }
}

private struct ShelfCount: View {
    let module: ShelfModule

    var body: some View {
        Text(module.files.count, format: .number)
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText())
    }
}

private struct ShelfExpandedView: View {
    let module: ShelfModule

    var body: some View {
        // The clear button floats over the grid's corner instead of taking a
        // column of its own, so the files get the full width.
        ShelfGrid(shelf: module)
            .overlay(alignment: .topTrailing) {
                Button(action: module.clear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background {
                            Circle()
                                .fill(.black.opacity(0.75))
                                .overlay(Circle().fill(.white.opacity(0.2)))
                                .shadow(color: .black.opacity(0.4), radius: 4)
                        }
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel("Clear Shelf")
            }
    }
}

/// Shown in place of whatever the pill holds while files are dragged toward it.
/// The whole pill is the target, so nothing covers the files already there.
struct ShelfDropZone: View {
    let shelf: ShelfModule
    let isTargeted: Bool

    var body: some View {
        if shelf.files.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                    .font(.system(size: 24, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text("Drop to add to Shelf")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isTargeted ? .white : .secondary)
            .frame(maxWidth: .infinity, minHeight: 72)
            .animation(.spring(duration: 0.25, bounce: 0.2), value: isTargeted)
        } else {
            // A plain preview: no scroll view and no drag handles, so nothing
            // inside competes with the pill for the incoming drop.
            HStack(spacing: 8) {
                ForEach(Array(shelf.files.reversed().prefix(Self.previewCount)), id: \.self) { url in
                    ShelfThumbnail(url: url)
                }
                if shelf.files.count > Self.previewCount {
                    Text("+\(shelf.files.count - Self.previewCount)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: ShelfItem.height)
                }
                Spacer(minLength: 0)
            }
            .frame(height: ShelfItem.height)
            .opacity(isTargeted ? 1 : 0.85)
            .allowsHitTesting(false)
        }
    }

    private static let previewCount = 4
}

/// Shelf files, newest first: one row while they fit, then two rows that scroll
/// sideways, so many files stay easy to scan.
private struct ShelfGrid: View {
    let shelf: ShelfModule

    @Environment(\.pillInnerRadius) private var innerRadius

    /// About this many items fit across the open pill.
    private static let perRow = 4

    var body: some View {
        let files = Array(shelf.files.reversed())
        let rowCount = files.count > Self.perRow ? 2 : 1
        let grid = LazyHGrid(rows: Array(repeating: GridItem(.fixed(ShelfItem.height), spacing: 8), count: rowCount),
                             spacing: 8) {
            ForEach(files, id: \.self) { url in
                ShelfItem(module: shelf, url: url)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        ScrollView(.horizontal, showsIndicators: false) { grid }
        .frame(height: CGFloat(rowCount) * ShelfItem.height + CGFloat(rowCount - 1) * 8)
        // Clip the scrolling edge with the same rounded corner as the items, so
        // a half-visible file is cut along a curve, not a straight line.
        .clipShape(RoundedRectangle(cornerRadius: ShelfItem.cornerRadius(innerRadius), style: .continuous))
        .animation(.spring(duration: 0.35, bounce: 0.2), value: shelf.files)
    }
}

/// A file's tile, without any interaction.
private struct ShelfThumbnail: View {
    let url: URL

    @Environment(\.pillInnerRadius) private var innerRadius
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let thumbnail = thumbnail ?? ShelfThumbnails.cache[url] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                }
            }
            .frame(width: 34, height: 34)
            Text(url.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 62)
        }
        .padding(.horizontal, 5)
        .frame(height: ShelfItem.height)
        .background(.white.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: ShelfItem.cornerRadius(innerRadius), style: .continuous))
        .task(id: url) { thumbnail = await ShelfThumbnails.thumbnail(for: url) }
        .accessibilityLabel(url.lastPathComponent)
    }
}

/// Reports how a drag out of the shelf ended.
private final class ShelfDragSource: NSObject, NSDraggingSource {
    private let isCopy: Bool
    private let ended: (NSDragOperation) -> Void

    init(isCopy: Bool, ended: @escaping (NSDragOperation) -> Void) {
        self.isCopy = isCopy
        self.ended = ended
    }

    /// Copy, never move: dropping a shelf file into a Finder folder must not
    /// take it from where it lives. A link is offered only for the user's own
    /// files, since the shelf's copies may be deleted later.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        isCopy ? [.copy, .generic] : [.copy, .generic, .link]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ended(operation)
    }
}

/// One parked file: drag it out to use it, click to show it in Finder.
private struct ShelfItem: View {
    static let height: CGFloat = 64

    static func cornerRadius(_ pillInnerRadius: CGFloat) -> CGFloat { min(pillInnerRadius, 12) }

    let module: ShelfModule
    let url: URL

    var body: some View {
        ShelfThumbnail(url: url)
            .opacity(module.draggingOut == url ? 0.4 : 1)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in module.beginDragOut(url) }
            )
            .onTapGesture { module.reveal(url) }
            .contextMenu {
                Button("Show in Finder") { module.reveal(url) }
                Button("Remove from Shelf") { module.remove(url) }
            }
    }
}

/// File previews, as in Finder, kept once made.
enum ShelfThumbnails {
    static var cache: [URL: NSImage] = [:]

    /// A preview of the file's content (an image, a PDF's first page…). Files
    /// without one keep their icon.
    static func thumbnail(for url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 34, height: 34),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        cache[url] = image
        return image
    }

    /// Makes previews ahead of time, for renders that cannot wait for them.
    static func prewarm(_ urls: [URL]) async {
        for url in urls { _ = await thumbnail(for: url) }
    }
}
