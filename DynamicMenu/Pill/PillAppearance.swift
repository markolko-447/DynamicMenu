//
//  PillAppearance.swift
//  DynamicMenu
//

import SwiftUI
import Observation

/// What the pill is made of.
enum PillAppearance: String, CaseIterable, Identifiable {
    /// Opaque black, like the iPhone's pill.
    case solid
    /// Solid black while closed. When opened, the top stays black (always covering
    /// the camera housing) and fades into glass toward the bottom.
    case gradient
    /// Glass throughout. External displays only: on a notch the top has to be
    /// black to join the camera housing, so it falls back to `gradient` there.
    case glass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .solid: "Solid"
        case .gradient: "Gradient"
        case .glass: "Glass"
        }
    }

    /// The choices that make sense for a display: glass cannot meet the black
    /// camera housing of a notch.
    static func choices(for style: PillStyle?) -> [PillAppearance] {
        if case .notch? = style { return [.solid, .gradient] }
        return allCases
    }

    /// What is actually drawn: glass on a notch becomes the gradient.
    func resolved(for style: PillStyle) -> PillAppearance {
        if self == .glass, case .notch = style { return .gradient }
        return self
    }
}

/// The chosen appearance for each display, remembered between launches.
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    private static let defaultKey = "pillAppearance"
    private static let perDisplayKey = "pillAppearanceByDisplay"

    /// Used by a display with no choice of its own.
    private var fallback: PillAppearance
    private var byDisplay: [String: PillAppearance]

    private init() {
        let defaults = UserDefaults.standard
        fallback = defaults.string(forKey: Self.defaultKey).flatMap(PillAppearance.init(rawValue:)) ?? .solid
        byDisplay = (defaults.dictionary(forKey: Self.perDisplayKey) as? [String: String] ?? [:])
            .compactMapValues(PillAppearance.init(rawValue:))
    }

    func appearance(for display: String) -> PillAppearance {
        byDisplay[display] ?? fallback
    }

    /// `remember: false` changes it for this run only (used by the state renderer).
    func setAppearance(_ appearance: PillAppearance, for display: String, remember: Bool = true) {
        byDisplay[display] = appearance
        guard remember else { return }
        fallback = appearance
        let defaults = UserDefaults.standard
        defaults.set(byDisplay.mapValues(\.rawValue), forKey: Self.perDisplayKey)
        defaults.set(appearance.rawValue, forKey: Self.defaultKey)
    }
}

/// The pill's surface, drawn in any shape (the pill itself or a bubble).
struct PillBackground<S: Shape>: View {
    let shape: S
    let appearance: PillAppearance
    /// 0 when closed, 1 when fully expanded; animates in between.
    var openness: Double = 0
    /// Height at the top that must stay opaque black: the camera housing on a
    /// notch, the resting pill height otherwise.
    var solidTop: CGFloat = 0

    var body: some View {
        switch appearance {
        case .solid:
            shape
                .fill(.black)
                // Glass brings its own edge; only the solid surface needs a shadow.
                .shadow(color: .black.opacity(0.4 * openness), radius: 18, y: 10)

        case .gradient:
            ZStack {
                Color.clear
                    .glassEffect(.regular, in: shape)
                    .opacity(openness)

                // Black band over the camera housing, then a fade into the glass.
                // Drawn as one gradient sized by the pill itself: a band with
                // a fixed height made the shape at least that tall, which turned
                // the small idle dot into a tall line.
                GeometryReader { proxy in
                    let band = proxy.size.height > 0 ? min(solidTop / proxy.size.height, 1) : 1
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: band),
                        .init(color: .black.opacity(band < 1 ? 0 : 1), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .clipShape(shape)

                // Closed, the pill is plain black; this fades away as it opens.
                shape.fill(.black).opacity(1 - openness)
            }

        case .glass:
            Color.clear
                .glassEffect(.regular, in: shape)
        }
    }
}
