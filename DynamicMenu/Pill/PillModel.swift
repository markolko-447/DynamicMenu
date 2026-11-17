//
//  PillModel.swift
//  DynamicMenu
//
//  State, geometry, and spring tuning for one pill.
//

import AppKit
import SwiftUI
import Observation

/// How the pill is drawn on a given display.
nonisolated enum PillStyle: Equatable {
    /// Grows out of the top edge. `width`/`height` match the camera housing.
    case notch(width: CGFloat, height: CGFloat)
    /// A floating pill, `topInset` points below the top edge.
    case pill(height: CGFloat, topInset: CGFloat)
}

nonisolated enum PillPresentation: Equatable {
    /// Nothing to show: invisible on a notch, a bare pill on a display without a notch.
    case idle
    /// An activity is running: leading and trailing slots. A second activity,
    /// if any, sits beside the pill in a detached bubble.
    case compact
    /// Opened by the user.
    case expanded
}

/// The animatable geometry of the shape. Every field is interpolated by the spring.
/// How a pill with nothing to show looks on an external display. It rests
/// as a pill, then draws in to a dot, then shrinks away.
nonisolated enum PillIdlePhase: Equatable {
    case pill, dot, hidden
}

nonisolated struct PillMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    /// Concave radius where a notch meets the top edge. Zero for a pill.
    var flare: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var topInset: CGFloat
    var shadow: Double
    /// Shift from the screen's centre line. On a notch each side is only as wide
    /// as its own content, so the shape's centre moves while the camera stays put.
    var xOffset: CGFloat = 0
    /// 1 shown, 0 gone. The pill scales down and fades as this falls.
    var visibility: Double = 1
}

/// Measured sizes of the current content. The pill wraps its content instead of
/// using fixed sizes, which is what keeps the margins even on every side.
nonisolated struct PillLayout: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    /// Minimal view in the detached bubble on the trailing side.
    var bubble: CGFloat = 0
    /// Minimal view in the detached bubble on the leading side.
    var leadingBubble: CGFloat = 0
    /// Height of the expanded content being shown. Filled from
    /// `expandedHeights` when metrics are computed.
    var expandedHeight: CGFloat = 0
    /// Measured height of each expanded view, by its id. Kept separately so a
    /// view on its way out cannot overwrite the height of the one coming in.
    var expandedHeights: [String: CGFloat] = [:]

    /// This layout with `expandedHeight` set for the expanded view `key`.
    func showing(_ key: String) -> PillLayout {
        var layout = self
        layout.expandedHeight = expandedHeights[key] ?? 0
        return layout
    }
}

/// Spacing rules, following Apple's Live Activities guidelines: one margin on every
/// side, concentric with the outer edge, and compact content snug against the camera.
nonisolated extension PillStyle {
    /// Margin of the expanded pill, on all sides.
    static let expandedMargin: CGFloat = 16
    /// Apple's expanded Live Activity is 371–408 pt wide.
    static let expandedWidth: CGFloat = 400
    static let expandedContentRange: ClosedRange<CGFloat> = 52...160

    var baseHeight: CGFloat {
        switch self {
        case .notch(_, let height), .pill(let height, _): height
        }
    }

    /// Margin above and below compact content.
    var compactMargin: CGFloat { max(3, (baseHeight * 0.19).rounded()) }

    var compactContentHeight: CGFloat { baseHeight - compactMargin * 2 }

    /// Margin between compact content and the outer left and right edges: the same
    /// as above and below it, so the content sits concentric with the edge.
    var compactSideMargin: CGFloat { compactMargin }

    /// Corner radius for a rounded element placed against the compact margin.
    var compactInnerRadius: CGFloat {
        switch self {
        case .notch: max(2, Self.compactBottomRadius - compactMargin)
        case .pill: compactContentHeight / 2
        }
    }

    /// Corner radius for a rounded element placed against the expanded margin.
    var expandedInnerRadius: CGFloat { expandedOuterRadius - Self.expandedMargin }

    /// Space above expanded content. On a notch the content starts just below the
    /// camera housing; on a pill it is the same margin as every other side.
    var expandedTopMargin: CGFloat {
        switch self {
        case .notch(_, let height): height + 4
        case .pill: Self.expandedMargin
        }
    }

    private static let compactBottomRadius: CGFloat = 12

    private var expandedOuterRadius: CGFloat {
        switch self {
        case .notch: 32
        case .pill: 40
        }
    }

    /// The housing's height is reported rounded, so the real notch can reach a
    /// hair below a pill of exactly that height. A little extra covers it.
    private static let notchBleed: CGFloat = 0.75

    func metrics(_ presentation: PillPresentation, hovering: Bool, layout: PillLayout,
                 idlePhase: PillIdlePhase = .pill) -> PillMetrics {
        let expandedHeight = expandedTopMargin
            + min(max(layout.expandedHeight, Self.expandedContentRange.lowerBound), Self.expandedContentRange.upperBound)
            + Self.expandedMargin

        switch self {
        case .notch(let width, let height):
            switch presentation {
            case .idle:
                return PillMetrics(
                    width: width + (hovering ? 12 : 0), height: height + Self.notchBleed + (hovering ? 4 : 0),
                    flare: 6, topRadius: 0, bottomRadius: hovering ? 13 : 10, topInset: 0, shadow: 0)
            case .compact:
                // Each side wraps its own content, as on iPhone: both items sit
                // against the camera and both keep the same outer margin, even
                // when one is much wider than the other.
                let leading = layout.leading + compactSideMargin
                let trailing = layout.trailing + compactSideMargin
                return PillMetrics(
                    width: width + leading + trailing + (hovering ? 12 : 0), height: height + Self.notchBleed + (hovering ? 4 : 0),
                    flare: 6, topRadius: 0, bottomRadius: Self.compactBottomRadius + (hovering ? 2 : 0),
                    topInset: 0, shadow: 0, xOffset: (trailing - leading) / 2)
            case .expanded:
                return PillMetrics(
                    width: max(Self.expandedWidth, width + 120), height: expandedHeight,
                    flare: 12, topRadius: 0, bottomRadius: expandedOuterRadius, topInset: 0, shadow: 1)
            }

        case .pill(let height, let topInset):
            let bump: CGFloat = hovering ? 3 : 0
            switch presentation {
            case .idle where idlePhase != .pill:
                // A dot on the pill's centre line; it fades and shrinks when hidden.
                let dot: CGFloat = 10
                return PillMetrics(
                    width: dot, height: dot,
                    flare: 0, topRadius: dot / 2, bottomRadius: dot / 2,
                    topInset: topInset + (height - dot) / 2, shadow: 0,
                    visibility: idlePhase == .hidden ? 0 : 1)
            case .idle:
                let h = height + bump
                return PillMetrics(
                    width: 56 + bump * 3, height: h,
                    flare: 0, topRadius: h / 2, bottomRadius: h / 2, topInset: topInset, shadow: 0)
            case .compact:
                let h = height + bump
                // Same anatomy as the notch: two balanced slots around a camera gap.
                let slot = max(layout.leading, layout.trailing) + compactSideMargin
                return PillMetrics(
                    width: cameraGap + slot * 2 + bump * 3, height: h,
                    flare: 0, topRadius: h / 2, bottomRadius: h / 2, topInset: topInset, shadow: 0)
            case .expanded:
                return PillMetrics(
                    width: Self.expandedWidth, height: expandedHeight,
                    flare: 0, topRadius: expandedOuterRadius, bottomRadius: expandedOuterRadius,
                    topInset: topInset, shadow: 1)
            }
        }
    }

    /// Width kept clear between the two compact slots. On a notch it is the camera
    /// housing; a pill has no camera, so it reserves the same kind of gap to keep
    /// the two sides apart, as the iPhone pill does around its camera.
    var cameraGap: CGFloat {
        switch self {
        case .notch(let width, _): width
        case .pill(let height, _): max(40, height * 2.2)
        }
    }
}

/// The detached bubble that holds a second activity.
nonisolated extension PillStyle {
    /// A floating pill, not a notch.
    var isPill: Bool { if case .pill = self { true } else { false } }

    static let bubbleSpacing: CGFloat = 8

    /// Beside a notch the bubble floats in the menu bar, so it is a little shorter
    /// than the housing; beside a pill it matches the pill. It grows with the
    /// pill on hover so the two always read as one group.
    func bubbleHeight(hovering: Bool) -> CGFloat {
        switch self {
        case .notch(_, let height): height - 6 + (hovering ? 4 : 0)
        case .pill(let height, _): height + (hovering ? 3 : 0)
        }
    }

    var bubbleTopInset: CGFloat {
        switch self {
        case .notch: 3
        case .pill(_, let topInset): topInset
        }
    }
}

/// Sizes that activity views read so their content fits the pill it is drawn in.
extension EnvironmentValues {
    /// Height available to compact content.
    @Entry var pillContentHeight: CGFloat = 20
    /// Corner radius that keeps a rounded element concentric with the pill's edge.
    @Entry var pillInnerRadius: CGFloat = 6
}

/// Spring tuning. SwiftUI springs retarget from the current position and velocity, so
/// reversing mid-animation (hover in, straight back out) never snaps.
extension Animation {
    /// Opening: quick with a small overshoot.
    static let pillExpand = Animation.spring(duration: 0.5, bounce: 0.22)
    /// Closing: faster and critically damped; a bounce on the way in looks loose.
    static let pillCollapse = Animation.spring(duration: 0.38, bounce: 0)
    /// Hover bump: short and lively.
    static let pillHover = Animation.spring(duration: 0.3, bounce: 0.35)
    /// Released after being pulled: loose and springy, like a drop of liquid.
    static let pillSnapBack = Animation.spring(duration: 0.5, bounce: 0.4)
    /// Compact activity appearing or leaving.
    static let pillActivity = Animation.spring(duration: 0.85, bounce: 0.2)
}

@Observable
final class PillModel {
    let style: PillStyle
    /// The screen the pill sits on, in screen coordinates.
    let screenFrame: CGRect
    /// Identifies the display across launches; keys its appearance.
    let displayUUID: String

    private(set) var isExpanded = false
    /// The activity the user clicked to expand. Nil shows the top one.
    private(set) var focusedID: String?
    private(set) var isHovering = false
    /// Files are being dragged over this pill or its bubbles. Set by the
    /// window's drop handling.
    var isDropTargeted = false

    @ObservationIgnored private var collapseTask: Task<Void, Never>?

    /// Only pills on external displays fade away; a notch stays as it is.
    private(set) var idlePhase: PillIdlePhase = .pill

    /// Measured content sizes; the pill is sized around them. Kept here, not in
    /// the view, so the state renderer can measure once and render again.
    var layout = PillLayout()
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var isIdle = false

    init(style: PillStyle, screenFrame: CGRect, displayUUID: String) {
        self.style = style
        self.screenFrame = screenFrame
        self.displayUUID = displayUUID
    }

    func presentation(activeCount: Int) -> PillPresentation {
        // With nothing to show there is nothing to expand into.
        guard activeCount > 0 else { return .idle }
        return isExpanded ? .expanded : .compact
    }

    /// `activityID` is the activity to open if the pointer stays; nil when there
    /// is nothing to open.
    /// Hover only makes the pill swell; opening is click-only, so working in
    /// the menu bar never opens it by accident. Leaving closes it.
    /// Called whenever activities start or stop. With nothing to show, a pill
    /// rests a moment, draws in to a dot, then shrinks away; anything starting
    /// brings it back.
    func updateIdle(_ idle: Bool) {
        isIdle = idle
        idleTask?.cancel()
        guard case .pill = style, AppSettings.shared.hidesIdlePill else {
            if idlePhase != .pill { withAnimation(.pillActivity) { idlePhase = .pill } }
            return
        }
        guard idle else {
            wake()
            return
        }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.isIdle, !self.isHovering else { return }
            withAnimation(.spring(duration: 0.5, bounce: 0.15)) { self.idlePhase = .dot }
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled, self.isIdle, !self.isHovering else { return }
            withAnimation(.spring(duration: 0.45, bounce: 0)) { self.idlePhase = .hidden }
        }
    }

    /// The shelf's drop zone opened or closed. A hidden pill opens it the same
    /// way it returns for an activity, from the dot. If the drag leaves without
    /// dropping anything, it draws straight back in to the dot and fades away.
    func dropZoneChanged(open: Bool) {
        guard case .pill = style, AppSettings.shared.hidesIdlePill else { return }
        idleTask?.cancel()
        if open {
            wake()
        } else if isIdle {
            withAnimation(.spring(duration: 0.45, bounce: 0.1)) { idlePhase = .dot }
            idleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, self.isIdle, !self.isHovering else { return }
                withAnimation(.spring(duration: 0.45, bounce: 0)) { self.idlePhase = .hidden }
            }
        }
    }

    /// Something started: come back the way the pill left, in reverse. A
    /// hidden pill first reappears as the dot, then the dot grows into the
    /// pill with its content.
    private func wake() {
        switch idlePhase {
        case .pill:
            return
        case .dot:
            withAnimation(.pillActivity) { idlePhase = .pill }
        case .hidden:
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) { idlePhase = .dot }
            idleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self else { return }
                withAnimation(.pillActivity) { self.idlePhase = .pill }
            }
        }
    }

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        collapseTask?.cancel()

        // Pointing at the dot wakes it back into a pill; leaving lets it fade again.
        if hovering, idlePhase == .dot {
            idleTask?.cancel()
            withAnimation(.pillHover) { idlePhase = .pill }
        } else if !hovering, isIdle {
            updateIdle(true)
        }

        if hovering {
            if !isExpanded {
                if AppSettings.shared.hapticsEnabled {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
            withAnimation(.pillHover) { isHovering = true }
        } else {
            withAnimation(.pillHover) { isHovering = false }
            // A short grace period so brushing past the edge does not close it.
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                self?.collapse()
            }
        }
    }

    /// Opens on an activity, or switches to it if already open.
    func open(focus id: String?) {
        if isExpanded {
            withAnimation(.pillActivity) { focusedID = id }
        } else {
            focusedID = id
            expand()
        }
    }

    /// For the state renderer and --demo: show a given idle phase directly.
    func setIdlePhase(_ phase: PillIdlePhase, animation: Animation? = .pillActivity) {
        idleTask?.cancel()
        withAnimation(animation) { idlePhase = phase }
    }

    func toggleExpanded(focus id: String?) {
        if isExpanded {
            collapse()
        } else {
            focusedID = id
            expand()
        }
    }

    private func expand() {
        guard !isExpanded else { return }
        if AppSettings.shared.hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        withAnimation(.pillExpand) { isExpanded = true }
    }

    func collapse() {
        guard isExpanded else { return }
        withAnimation(.pillCollapse) { isExpanded = false }
    }
}
