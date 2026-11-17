//
//  PillShape.swift
//  DynamicMenu
//

import SwiftUI

/// One shape for both styles, so a single spring drives every corner.
///
/// - Pill: `flare` is 0 and all four corners are continuous (squircle) curves.
/// - Notch: `topRadius` is 0 and `flare` adds the concave fillets that blend the body
///   into the top edge of the screen. The fillets sit outside the body, so the body is
///   inset by `flare` on each side.
nonisolated struct PillShape: Shape {
    var flare: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(flare, AnimatablePair(topRadius, bottomRadius)) }
        set {
            flare = newValue.first
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let flare = max(0, min(flare, rect.width / 4, rect.height))
        let body = rect.insetBy(dx: flare, dy: 0)
        let limit = min(body.width, body.height) / 2

        var path = UnevenRoundedRectangle(
            topLeadingRadius: min(max(topRadius, 0), limit),
            bottomLeadingRadius: min(max(bottomRadius, 0), limit),
            bottomTrailingRadius: min(max(bottomRadius, 0), limit),
            topTrailingRadius: min(max(topRadius, 0), limit),
            style: .continuous
        ).path(in: body)

        guard flare > 0 else { return path }

        // The fillets overlap the body and run above the screen's top edge.
        // Abutting shapes on fractional pixels (the width is animating) each cover
        // part of a pixel, and together cover less than the whole: a light
        // hairline along the seam. Overlapping, wound the same way as the body
        // (clockwise), they add up instead.
        let overlap: CGFloat = 2, above: CGFloat = 2

        // Left fillet: the sliver between the body's top-left corner and a quarter
        // circle centred on the screen edge, one radius below the top.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY - above))
        path.addLine(to: CGPoint(x: body.minX + overlap, y: rect.minY - above))
        path.addLine(to: CGPoint(x: body.minX + overlap, y: rect.minY + flare))
        path.addLine(to: CGPoint(x: body.minX, y: rect.minY + flare))
        path.addArc(
            center: CGPoint(x: rect.minX, y: rect.minY + flare), radius: flare,
            startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
        path.closeSubpath()

        // Right fillet, mirrored.
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY - above))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX, y: rect.minY + flare), radius: flare,
            startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: CGPoint(x: body.maxX - overlap, y: rect.minY + flare))
        path.addLine(to: CGPoint(x: body.maxX - overlap, y: rect.minY - above))
        path.closeSubpath()

        return path
    }
}
