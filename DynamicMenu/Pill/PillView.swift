//
//  PillView.swift
//  DynamicMenu
//

import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct PillView: View {
    let model: PillModel
    private var activities = ActivityCenter.shared
    private var settings = AppearanceSettings.shared
    /// Still images cannot run the fluid layer's shader, so they go without it.
    @Environment(\.isStillRender) private var isStillRender
    /// How far the blobs of the fluid layer reach to each other right now. It
    /// is wide as a bubble appears or leaves, so the neck lasts through the
    /// pull-off, and settles to a short reach, so bubbles at rest stay apart.
    @State private var fluidReach: CGFloat = PillView.restingReach
    private var fileDrag = FileDragMonitor.shared
    /// Scripted content for the state renderer and --demo; nil otherwise.
    private var demo = DemoStage.shared

    /// Measured content sizes; the pill is sized around them.
    /// How far the pointer has dragged the pill from rest.
    @State private var pull = CGSize.zero
    /// The same for each bubble, by activity id.
    @State private var bubblePulls: [String: CGSize] = [:]

    /// Briefly true after a click that has nothing to open.
    @State private var isNudged = false
    /// The shelf's drop zone is showing. Kept as state so the area that keeps it
    /// open can be larger than the area that opens it.
    @State private var isDropZoneOpen = false
    /// Keeps the zone open for a moment after a drag leaves, so a brief exit
    /// does not snap it shut.
    @State private var isDropHeld = false
    @State private var dropHoldTask: Task<Void, Never>?

    init(model: PillModel) {
        self.model = model
    }

    var body: some View {
        let active = demo.isRunning ? demo.active : activities.active
        let primary = active.first
        // Bubbles beside the pill only: a notch shows one activity at a time.
        let secondary = active.count > 1 && model.style.isPill ? active[1] : nil
        // Files dragged toward the pill open the shelf's drop zone, whatever is
        // playing, so the drop has a large target instead of the small pill.
        // Also opened by a file drag that reaches the pill without the early
        // detector having seen it start (the Dock prepares its drag ahead of time).
        let showsDropZone = demo.isRunning ? demo.showsDropZone
            : shelf.draggingOut == nil && (isDropZoneOpen || model.isDropTargeted || isDropHeld)
        // While the pill is coming back from its idle dot, it stays a dot
        // until the dot has reappeared; then it grows into the activity.
        let presentation: PillPresentation = model.idlePhase != .pill ? .idle
            : (showsDropZone ? .expanded : model.presentation(activeCount: active.count))
        // Expanded shows whichever activity was clicked; otherwise the top one.
        let shown = model.isExpanded ? (active.first { $0.id == model.focusedID } ?? primary) : primary
        // Files held over the pill make it swell like a hover, to invite the drop.
        let isRaised = model.isHovering || model.isDropTargeted
        let expandedKey = showsDropZone ? "dropZone" : (shown?.id ?? "")
        let metrics = model.style.metrics(presentation, hovering: isRaised, layout: model.layout.showing(expandedKey),
                                          idlePhase: model.idlePhase)
        let shape = PillShape(
            flare: metrics.flare, topRadius: metrics.topRadius, bottomRadius: metrics.bottomRadius)
        let appearance = settings.appearance(for: model.displayUUID).resolved(for: model.style)
        let isNotch = if case .notch = model.style { true } else { false }
        let stretch = Self.stretch(for: pull, nudged: isNudged)

        ZStack(alignment: .top) {
            // Only while a bubble is out or just leaving: on its own the pill
            // is already crisp, and the blurred copy only fringed its edges.
            if presentation == .compact, !isStillRender, !ProcessInfo.processInfo.arguments.contains("--no-fluid"),
               secondary != nil || (model.style.isPill && active.count > 2) || fluidReach > Self.restingReach + 0.05 {
                fluidLayer(metrics: metrics, shape: shape, active: active, secondary: secondary,
                           raised: isRaised, appearance: appearance, isNotch: isNotch, stretch: stretch)
            }
            ZStack(alignment: .top) {
                PillBackground(shape: shape, appearance: appearance,
                                 openness: metrics.shadow, solidTop: model.style.baseHeight)

                content(presentation, activity: shown, dropZone: showsDropZone, height: metrics.height)
                    .padding(.horizontal, metrics.flare)
                    .clipShape(shape)
            }
            // Top-aligned: content taller than the pill must never be centred,
            // which pushed its top off screen.
            .frame(width: metrics.width + metrics.flare * 2, height: metrics.height, alignment: .top)
            .contentShape(shape)
            .onHover { model.setHovering($0) }
            // Opens the pill. Off while it is open, so it never competes with
            // the buttons and scrubber inside; leaving the pill closes it.
            .gesture(
                TapGesture().onEnded {
                    if primary == nil { nudge() } else { model.toggleExpanded(focus: primary?.id) }
                },
                isEnabled: presentation != .expanded
            )
            // Pulling the pill stretches it toward the pointer with growing
            // resistance; letting go springs it back. A notch stays attached to
            // the top edge, a pill moves freely.
            // Measured in global space: the pill itself moves under the pointer,
            // and measuring against a moving view feeds back into jitter. Each
            // update is eased with a short spring so the motion stays fluid.
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.85)) {
                            pull = value.translation
                        }
                    }
                    .onEnded { _ in withAnimation(.pillSnapBack) { pull = .zero } },
                isEnabled: presentation != .expanded
            )
            .scaleEffect(x: stretch.scale.width, y: stretch.scale.height, anchor: isNotch ? .top : .center)
            .offset(x: metrics.xOffset + stretch.offset.width, y: isNotch ? 0 : stretch.offset.height)
            // Fading away when idle: shrink and fade together, like a drop
            // evaporating, and take no clicks once gone.
            .scaleEffect(0.2 + 0.8 * metrics.visibility)
            .opacity(metrics.visibility)
            .allowsHitTesting(metrics.visibility > 0)
            .padding(.top, metrics.topInset)

            // A hidden pill draws nothing, so drags would fall through it. While
            // a drag is under way, keep an invisible place to drop onto where
            // the pill rests; it exists only during a drag, so ordinary clicks
            // on the menu bar are never caught.
            if model.idlePhase == .hidden, !showsDropZone, fileDrag.isPointerDragging {
                Color.black.opacity(Self.invisibleHit)
                    .frame(width: 240, height: max(model.style.baseHeight + 16, 36))
            }

            if presentation == .compact, let secondary {
                bubble(secondary, beside: metrics, raised: isRaised)
            }
            // A third activity goes on the other side. Only beside a pill: next
            // to a notch that space belongs to the app's menus.
            if presentation == .compact, !isNotch, active.count > 2 {
                bubble(active[2], beside: metrics, raised: isRaised, leading: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // While the drop zone is open, the whole window becomes a solid drop
        // target. Without this, the pixel under the pointer goes transparent for
        // a moment while the pill grows, macOS reports the drag as having left,
        // the zone closes, and the pill flaps until the pointer holds still.
        // The fill is invisible; it only exists during a file drag.
        .background(Color.black.opacity(showsDropZone ? Self.invisibleHit : 0))
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        // Activities start, stop and resize on their own; this is what makes the
        // pill spring to follow them. Hover and expand animate from PillModel.
        .animation(.pillActivity, value: active.map(\.id))
        .onChange(of: active.map(\.id)) { _, _ in
            // Reach out at once, then relax as the bubble settles.
            var jump = Transaction()
            jump.disablesAnimations = true
            withTransaction(jump) { fluidReach = Self.pullingReach }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                withAnimation(.spring(duration: 1.0, bounce: 0.1)) { fluidReach = Self.restingReach }
            }
        }
        .animation(.pillActivity, value: model.layout)
        .animation(.pillExpand, value: showsDropZone)
        .onChange(of: model.isDropTargeted) { _, targeted in
            dropHoldTask?.cancel()
            if targeted {
                isDropHeld = true
            } else {
                dropHoldTask = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled, !model.isDropTargeted else { return }
                    isDropHeld = false
                }
            }
        }
        .onChange(of: demo.expandedID) { _, id in
            if let id { model.open(focus: id) } else { model.collapse() }
        }
        .onChange(of: fileDrag.location) { updateDropZone() }
        .onChange(of: fileDrag.isDragging) { updateDropZone() }
        .onChange(of: showsDropZone) { _, shows in
            model.dropZoneChanged(open: shows)
            Log.shelf.notice("Drop zone \(shows ? "opened" : "closed", privacy: .public)")
        }
        .onChange(of: active.isEmpty, initial: true) { _, isEmpty in
            if isEmpty { model.collapse() }
            model.updateIdle(isEmpty)
        }
        .onChange(of: AppSettings.shared.hidesIdlePill) { model.updateIdle(active.isEmpty) }
    }

    /// The shelf shown in the drop zone: the demo's while a demo runs.
    private var shelf: ShelfModule { demo.isRunning ? demo.shelf : activities.shelf }

    private func updateDropZone() {
        // A file being dragged out of the shelf starts right at the pill; the
        // shelf stays as it is rather than turning into a drop zone.
        let open = shelf.draggingOut == nil
            && fileDrag.isNear(topCentreOf: model.screenFrame, generous: isDropZoneOpen)
        if open != isDropZoneOpen { isDropZoneOpen = open }
    }

    // MARK: - Liquid pull

    /// The least opacity a window can store (one step of 255): enough for
    /// macOS to count the area as part of the window for drags, too little
    /// to see. 1% black showed as a faint grey box over light wallpapers.
    private static let invisibleHit: Double = 1.0 / 255

    /// Offset and stretch for a drag. Movement follows the pointer less and less
    /// the further it goes, and the shape lengthens along the pull.
    private static func stretch(for pull: CGSize, nudged: Bool) -> (offset: CGSize, scale: CGSize) {
        // A few points at most: a hint of give, not a draggable object.
        let offset = CGSize(width: rubberBand(pull.width, limit: 6), height: rubberBand(pull.height, limit: 3))
        let bump: CGFloat = nudged ? 1.07 : 1
        let scale = CGSize(
            width: (1 + abs(offset.width) / 120) * bump,
            height: (1 + max(offset.height, 0) / 60 - abs(offset.width) / 300) * bump)
        return (offset, scale)
    }

    private static func rubberBand(_ distance: CGFloat, limit: CGFloat) -> CGFloat {
        let magnitude = abs(distance)
        let eased = (1 - 1 / (magnitude * 0.55 / limit + 1)) * limit
        return distance < 0 ? -eased : eased
    }

    /// A click with nothing to open: swell slightly and settle, so the pill
    /// still answers the touch.
    private func nudge() {
        withAnimation(.spring(duration: 0.16, bounce: 0)) { isNudged = true }
        Task {
            try? await Task.sleep(for: .milliseconds(130))
            withAnimation(.pillSnapBack) { isNudged = false }
        }
    }

    /// Content swaps with Apple's blur-replace: the old view blurs, shrinks and fades
    /// while the new one does the reverse, instead of a flat cross-fade.
    @ViewBuilder
    private func content(_ presentation: PillPresentation, activity: (any ActivityModule)?,
                         dropZone: Bool, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            switch presentation {
            case .idle:
                EmptyView()

            case .compact:
                if let activity {
                    compact(activity, height: height)
                        .id(activity.id)
                        .transition(.blurReplace)
                }

            case .expanded:
                if dropZone {
                    expanded(ShelfDropZone(shelf: shelf, isTargeted: model.isDropTargeted), key: "dropZone")
                        .id("dropZone")
                        .transition(.blurReplace)
                } else if let activity {
                    expanded(activity.expanded, key: activity.id)
                        .id(activity.id)
                        .transition(.blurReplace)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Two slots with the same margin on the top, bottom and outer side. `height`
    /// is the pill's current height, so content stays vertically centred when
    /// the pill grows on hover.
    private func compact(_ activity: any ActivityModule, height: CGFloat) -> some View {
        let style = model.style
        let leading = activity.compactLeading
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.layout.leading = $0 }
        let trailing = activity.compactTrailing
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.layout.trailing = $0 }

        // On a notch each side is exactly as wide as its content (the shape is
        // sized to match), so both items touch the camera housing and the outer
        // margin. A pill has no real camera: both slots take the wider content's
        // width to keep the pill centred, and items sit against the outer edge.
        let isNotch = if case .notch = style { true } else { false }
        let slot = max(model.layout.leading, model.layout.trailing)
        return HStack(spacing: 0) {
            if isNotch {
                leading
                Spacer(minLength: style.cameraGap)
                trailing
            } else {
                leading.frame(width: slot, alignment: .leading)
                Spacer(minLength: style.cameraGap)
                trailing.frame(width: slot, alignment: .trailing)
            }
        }
        .compactSlot(style, height: height)
        .padding(.horizontal, style.compactSideMargin)
    }

    /// The second activity, detached beside the pill: a circle, or an oval when
    /// its content is wider. Clicking it expands that activity.
    /// Where a bubble sits beside the pill.
    private struct BubbleFrame {
        let width: CGFloat
        let height: CGFloat
        /// Signed distance of its centre from the pill's centre, at rest.
        let travel: CGFloat
        /// Its horizontal offset on screen.
        let offset: CGFloat
    }

    private func bubbleFrame(beside pill: PillMetrics, raised: Bool, leading: Bool) -> BubbleFrame {
        let style = model.style
        let height = style.bubbleHeight(hovering: raised)
        let margin = style.compactMargin
        let width = max(height, (leading ? model.layout.leadingBubble : model.layout.bubble) + margin * 2)
        let halfPill = pill.width / 2 + pill.flare
        let distance = halfPill + PillStyle.bubbleSpacing + width / 2
        let travel = leading ? -distance : distance
        return BubbleFrame(width: width, height: height, travel: travel, offset: pill.xOffset + travel)
    }

    /// The pill and its bubbles again, as soft blobs: blurred together so that
    /// blobs close to each other join in a smooth neck, then sharpened by a
    /// shader. It sits under the real pill and bubbles, which stay crisp, so
    /// what shows from it is the neck and the bulge where a bubble pulls out.
    @ViewBuilder
    private func fluidLayer(metrics: PillMetrics, shape: PillShape, active: [any ActivityModule],
                            secondary: (any ActivityModule)?, raised: Bool, appearance: PillAppearance,
                            isNotch: Bool, stretch: (offset: CGSize, scale: CGSize)) -> some View {
        let blobs = ZStack(alignment: .top) {
            shape.fill(.black)
                .frame(width: metrics.width + metrics.flare * 2, height: metrics.height)
                .scaleEffect(x: stretch.scale.width, y: stretch.scale.height, anchor: isNotch ? .top : .center)
                .offset(x: metrics.xOffset + stretch.offset.width, y: isNotch ? 0 : stretch.offset.height)
                .padding(.top, metrics.topInset)

            if let secondary {
                bubbleBlob(secondary, beside: metrics, raised: raised, leading: false)
            }
            if !isNotch, active.count > 2 {
                bubbleBlob(active[2], beside: metrics, raised: raised, leading: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .compositingGroup()
        .blur(radius: fluidReach)
        // Just above 0.5, a straight edge lands a hair inside the crisp shape
        // above it however wide the blur, so no soft halo shows around it.
        .colorEffect(ShaderLibrary.gooThreshold(.float(0.58), .float(0.03)))

        if appearance == .glass {
            // The neck is frosted like the glass it joins.
            Rectangle().fill(.ultraThinMaterial).mask { blobs }.allowsHitTesting(false)
        } else {
            blobs.allowsHitTesting(false)
        }
    }

    /// Two blobs join when closer than about 1.35 times the reach. At rest it is
    /// shorter than the gap the bubbles sit at.
    private static let restingReach: CGFloat = 4.5
    private static let pullingReach: CGFloat = 11

    private func bubbleBlob(_ activity: any ActivityModule, beside pill: PillMetrics,
                            raised: Bool, leading: Bool) -> some View {
        let f = bubbleFrame(beside: pill, raised: raised, leading: leading)
        let st = Self.stretch(for: bubblePulls[activity.id] ?? .zero, nudged: false)
        return Capsule().fill(.black)
            .frame(width: f.width, height: f.height)
            .scaleEffect(x: st.scale.width, y: st.scale.height)
            .offset(x: f.offset + st.offset.width, y: st.offset.height)
            .padding(.top, model.style.bubbleTopInset)
            .id("\(activity.id).\(leading ? "left" : "right")")
            .transition(.bubbleEmerge(travel: f.travel))
    }

    private func bubble(_ activity: any ActivityModule, beside pill: PillMetrics,
                        raised: Bool, leading: Bool = false) -> some View {
        let style = model.style
        let appearance = settings.appearance(for: model.displayUUID).resolved(for: style)
        let f = bubbleFrame(beside: pill, raised: raised, leading: leading)
        let height = f.height, width = f.width, offset = f.offset
        let stretch = Self.stretch(for: bubblePulls[activity.id] ?? .zero, nudged: false)
        return BubbleFade(content: activity.minimal)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                if leading { model.layout.leadingBubble = $0 } else { model.layout.bubble = $0 }
            }
            .compactSlot(style, height: height)
            .frame(width: width)
            .background {
                PillBackground(shape: Capsule(), appearance: appearance)
            }
            .contentShape(Capsule())
            .onHover { model.setHovering($0) }
            .onTapGesture { model.toggleExpanded(focus: activity.id) }
            // Bubbles give and spring back like the pill itself.
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.85)) {
                            bubblePulls[activity.id] = value.translation
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.pillSnapBack) { bubblePulls[activity.id] = .zero }
                    }
            )
            .scaleEffect(x: stretch.scale.width, y: stretch.scale.height)
            .offset(x: offset + stretch.offset.width, y: stretch.offset.height)
            .padding(.top, style.bubbleTopInset)
            // The side is part of its identity: an activity that moves to the other
            // side goes back into the pill and comes out of the other end.
            .id("\(activity.id).\(leading ? "left" : "right")")
            // Comes out of the pill and goes back into it, together with its blob.
            .transition(.bubbleEmerge(travel: f.travel))
    }

    /// The pill's height follows the content, so the margin stays the same on
    /// every side whatever the activity shows.
    private func expanded(_ content: some View, key: String) -> some View {
        let style = model.style
        return content
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.layout.expandedHeights[key] = $0 }
        // Short content (a single row) is centred in the pill's minimum height,
        // so the space is shared above and below instead of all landing underneath.
        .frame(minHeight: PillStyle.expandedContentRange.lowerBound)
        .padding(.horizontal, PillStyle.expandedMargin)
        .padding(.bottom, PillStyle.expandedMargin)
        .padding(.top, style.expandedTopMargin)
        .environment(\.pillInnerRadius, style.expandedInnerRadius)
    }
}

private extension View {
    /// Sizing shared by everything shown at compact scale: content is centred in
    /// a container of the given height, with the same margin above and below.
    /// Content size comes from the resting height, so hover grows the container
    /// around the content rather than scaling the content.
    func compactSlot(_ style: PillStyle, height: CGFloat) -> some View {
        let contentHeight = style.compactContentHeight
        return self
            .frame(height: contentHeight)
            .font(.system(size: max(10, contentHeight * 0.62), weight: .semibold, design: .rounded))
            .frame(height: height)
            .environment(\.pillContentHeight, contentHeight)
            .environment(\.pillInnerRadius, style.compactInnerRadius)
    }
}

// MARK: - Bubbles leaving and rejoining the pill

private struct BubbleProgressKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

private extension EnvironmentValues {
    /// How far a bubble has come out of the pill: 0 hidden inside, 1 at rest.
    var bubbleProgress: Double {
        get { self[BubbleProgressKey.self] }
        set { self[BubbleProgressKey.self] = newValue }
    }
}

/// A bubble's contents appear once it has cleared the pill, so nothing is
/// drawn over the pill while the bubble is still inside it.
private struct BubbleFade<Content: View>: View {
    @Environment(\.bubbleProgress) private var progress
    let content: Content

    var body: some View {
        let t = min(max((progress - 0.45) / 0.4, 0), 1)
        content.opacity(t * t * (3 - 2 * t))
    }
}

/// Slides a bubble out of the pill, a little past its resting place and back,
/// as a drop pulled off by its own weight, with a little give: stretched on the
/// way out, squashed the other way as the spring carries it past. The blob under
/// the bubble takes the same path, so the neck between them follows. `progress`
/// goes 0 → 1 as the bubble appears (and back as it leaves).
private struct BubbleEmerge: ViewModifier, Animatable {
    var raw: Double
    /// Signed resting distance of the bubble's centre from the pill's centre.
    let travel: CGFloat
    /// Part of the animation an arriving bubble waits through, so one that is
    /// leaving the pill (to come back on the other side) is gone first.
    let wait: Double

    /// 0 hidden inside the pill, 1 at rest, after the wait.
    private var progress: Double { wait > 0 ? min(max((raw - wait) / (1 - wait), -0.5), 1.5) : raw }

    var animatableData: Double {
        get { raw }
        set { raw = newValue }
    }

    private var travelled: Double {
        let clamped = min(max(progress, 0), 1)
        let eased = progress < 1 ? pow(clamped, 1.5) : progress
        return eased + 0.3 * sin(.pi * pow(clamped, 1.5))
    }

    func body(content: Content) -> some View {
        let give = sin(.pi * min(max(progress, -0.5), 1.5))
        return content
            .environment(\.bubbleProgress, progress)
            .scaleEffect(x: 1 + 0.12 * give, y: 1 - 0.08 * give)
            .offset(x: -(1 - travelled) * travel)
            // While it waits, hidden behind the pill, it must not peek out above
            // and below it (it is a little taller than the pill).
            .opacity(progress > 0.001 ? 1 : 0)
    }
}

private extension AnyTransition {
    static func bubbleEmerge(travel: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BubbleEmerge(raw: 0, travel: travel, wait: 0.12),
                                 identity: BubbleEmerge(raw: 1, travel: travel, wait: 0.12)),
            removal: .modifier(active: BubbleEmerge(raw: 0, travel: travel, wait: 0),
                               identity: BubbleEmerge(raw: 1, travel: travel, wait: 0)))
    }
}
