//
//  FileDragMonitor.swift
//  DynamicMenu
//
//  Notices when the user starts dragging files anywhere on screen, so the pill
//  can open a drop zone before the pointer reaches it. Waiting for the pointer to
//  land exactly on the small pill made drops hit-or-miss.
//
//  It polls instead of watching mouse events: drags that start in the Dock, or on
//  the Desktop while another app is in front, never reach an event monitor. The
//  mouse button state and the drag pasteboard are always readable, need no
//  permission, and the drag pasteboard only changes when a drag begins.
//

import OSLog
import AppKit
import Observation

@Observable
final class FileDragMonitor {
    static let shared = FileDragMonitor()

    /// True while files (or something that can become a file) are being dragged,
    /// and briefly after release so the drop can land before the zone closes.
    private(set) var isDragging = false
    /// Pointer position in screen coordinates, updated only while dragging.
    private(set) var location = CGPoint.zero
    /// True while the mouse button is held and the pointer has moved: some drag
    /// is under way, whether or not it could be recognised as files (the Dock
    /// prepares its drags ahead of time, so they cannot be). The pill uses it
    /// to keep a place to drop onto while it is hidden.
    private(set) var isPointerDragging = false
    @ObservationIgnored private var pressLocation = CGPoint.zero

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var isPressed = false
    /// Consecutive polls that saw the button up. A release counts only after a
    /// few, because the button state can blip during a drag (seen with the Dock).
    @ObservationIgnored private var releasedPolls = 0
    /// The drag pasteboard's count when the button was last up. A different count
    /// while the button is down means a drag started during this press.
    @ObservationIgnored private var baselineChangeCount = 0
    /// Set once the current press has been checked and found not to carry files.
    @ObservationIgnored private var pressRejected = false

    private static let dragPasteboard = NSPasteboard(name: .drag)

    /// Pasteboard types that mean "this drag can end up as a file on the shelf".
    private static let fileTypes: Set<NSPasteboard.PasteboardType> = {
        var types: Set<NSPasteboard.PasteboardType> = [.fileURL, .tiff, .png, .pdf]
        types.formUnion(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        return types
    }()

    /// How long the drop zone stays open after release. The logs show the drop
    /// is delivered up to about a third of a second after the button comes up.
    private static let releaseGrace = Duration.milliseconds(700)

    func start() {
        guard pollTask == nil else { return }
        baselineChangeCount = Self.dragPasteboard.changeCount
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.poll()
                // Quick while the button is down, relaxed otherwise.
                try? await Task.sleep(for: .milliseconds(self.isPressed ? 40 : 90))
            }
        }
    }

    /// True when the pointer is close enough to a pill at the top centre of
    /// `screen` that the drop zone should open. `generous` is the larger area
    /// used once the zone is open, so moving down into it does not close it.
    func isNear(topCentreOf screen: CGRect, generous: Bool) -> Bool {
        guard isDragging, screen.contains(location) || abs(location.y - screen.maxY) < 2 else { return false }
        let halfWidth: CGFloat = generous ? 340 : 260
        let depth: CGFloat = generous ? 340 : 220
        return abs(location.x - screen.midX) < halfWidth && screen.maxY - location.y < depth
    }

    private func poll() {
        // The hardware state, not the event stream's: apps such as the Dock run
        // their own drag tracking, and the event-level state does not follow it.
        let pressed = CGEventSource.buttonState(.hidSystemState, button: .left)

        guard pressed else {
            releasedPolls += 1
            if isPressed, releasedPolls >= 3 {
                isPressed = false
                if isPointerDragging { isPointerDragging = false }
                baselineChangeCount = Self.dragPasteboard.changeCount
                if isDragging { scheduleFinish() }
            }
            return
        }
        releasedPolls = 0

        if !isPressed {
            isPressed = true
            pressRejected = false
            pressLocation = NSEvent.mouseLocation
            finishTask?.cancel()
        }
        if !isPointerDragging {
            let point = NSEvent.mouseLocation
            if hypot(point.x - pressLocation.x, point.y - pressLocation.y) > 6 { isPointerDragging = true }
        }

        if !isDragging, !pressRejected {
            let pasteboard = Self.dragPasteboard
            guard pasteboard.changeCount != baselineChangeCount else { return }
            let types = pasteboard.types ?? []
            // The source clears the pasteboard first and fills it a moment later
            // (the Dock and Desktop do this). Empty means "not written yet", so
            // look again on the next poll rather than give up on this drag.
            guard !types.isEmpty else { return }
            guard !Self.fileTypes.isDisjoint(with: types) else {
                // Text, a colour, a window tab… not for the shelf.
                pressRejected = true
                Log.shelf.notice("Drag ignored, no file types: \(types.map(\.rawValue).joined(separator: ", "), privacy: .public)")
                return
            }
            Log.shelf.notice("File drag started: \(types.map(\.rawValue).joined(separator: ", "), privacy: .public)")
            location = NSEvent.mouseLocation
            isDragging = true
        }

        if isDragging {
            let point = NSEvent.mouseLocation
            // Small moves change nothing visible; skip them to avoid re-rendering
            // every pill for each pixel.
            if hypot(point.x - location.x, point.y - location.y) > 6 { location = point }
        }
    }

    private func scheduleFinish() {
        finishTask?.cancel()
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseGrace)
            guard !Task.isCancelled, let self, self.isDragging else { return }
            Log.shelf.notice("File drag ended")
            self.isDragging = false
        }
    }
}
