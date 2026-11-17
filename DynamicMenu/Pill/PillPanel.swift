//
//  PillPanel.swift
//  DynamicMenu
//
//  The transparent overlay window that hosts one pill.
//

import AppKit
import OSLog
import SwiftUI

/// A fixed-size, transparent panel pinned to the top centre of a screen.
///
/// The panel never resizes. The pill shape animates inside it, which is what keeps
/// the motion smooth: window-frame animation runs outside the render loop and stutters.
/// Fully transparent pixels of a non-opaque window do not receive mouse events, so
/// everything outside the shape stays click-through.
final class PillPanel: NSPanel {
    private(set) var model: PillModel?
    /// Large enough for the expanded pill plus its shadow.
    static let canvasSize = CGSize(width: 680, height: 340)

    init(screen: NSScreen, style: PillStyle, displayUUID: String) {
        let size = Self.canvasSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        // Above the menu bar, so the pill can sit in it and on the notch.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let model = PillModel(style: style, screenFrame: screen.frame, displayUUID: displayUUID)
        self.model = model
        let hosting = PillHostingView(rootView: PillView(model: model))
        hosting.model = model
        hosting.registerForDraggedTypes([])
        hosting.sizingOptions = []
        contentView = hosting

        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit would otherwise push the window below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The panel never becomes the key window, so every click on it is a "first
/// click". AppKit drops first clicks on controls unless the view accepts them,
/// which left the pill's buttons and scrubber unresponsive.
///
/// It is also the pill's drop target. Drops are taken here, from the drag
/// pasteboard directly, rather than through SwiftUI's onDrop: that converts every
/// item to a typed provider, which lost the file links Dock stacks offer and
/// refused file promises. Every drawn part of the window takes drops, so the
/// bubbles count as well as the pill.
final class PillHostingView: NSHostingView<PillView> {
    weak var model: PillModel?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// True from the moment a file drag enters until it leaves or drops.
    private var isReceivingDrag = false

    /// While a file drag is over the window, this view answers every point
    /// itself. Otherwise AppKit hands the drag to whatever inner view is under
    /// the pointer (the shelf's scroll view, for one), which does not take drops,
    /// and the drop fails until the pointer finds a spot outside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isReceivingDrag || FileDragMonitor.shared.isDragging {
            return super.hitTest(point) == nil ? nil : self
        }
        return super.hitTest(point)
    }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        super.registerForDraggedTypes(Array(Set(newTypes + Self.shelfTypes)))
    }

    private static let shelfTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .tiff, .png] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ShelfModule.canAccept(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        Log.shelf.notice("Drag allows: \(Self.describe(sender.draggingSourceOperationMask), privacy: .public)")
        isReceivingDrag = true
        setTargeted(true)
        return Self.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ShelfModule.canAccept(sender.draggingPasteboard) else { return super.draggingUpdated(sender) }
        return Self.operation(for: sender)
    }

    /// An operation the source allows. A drop answered with one it does not allow
    /// is refused and slides back; Dock stacks, for one, do not offer "copy".
    /// The shelf only keeps a reference, so whichever is chosen, nothing moves.
    private static func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        let allowed = sender.draggingSourceOperationMask
        for operation: NSDragOperation in [.copy, .link, .generic, .move, .every] where allowed.contains(operation) {
            return operation
        }
        return allowed.isEmpty ? .copy : allowed
    }

    private static func describe(_ mask: NSDragOperation) -> String {
        let names: [(NSDragOperation, String)] = [(.copy, "copy"), (.link, "link"), (.generic, "generic"),
                                                  (.private, "private"), (.move, "move"), (.delete, "delete")]
        let present = names.filter { mask.contains($0.0) }.map(\.1)
        return present.isEmpty ? "none (\(mask.rawValue))" : present.joined(separator: ", ")
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isReceivingDrag = false
        setTargeted(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ShelfModule.canAccept(sender.draggingPasteboard) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard ShelfModule.canAccept(sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        isReceivingDrag = false
        setTargeted(false)
        return ActivityCenter.shared.shelf.accept(sender.draggingPasteboard)
    }

    private func setTargeted(_ targeted: Bool) {
        guard let model, model.isDropTargeted != targeted else { return }
        Log.shelf.notice("Drop target \(targeted ? "entered" : "left", privacy: .public)")
        model.isDropTargeted = targeted
    }
}
