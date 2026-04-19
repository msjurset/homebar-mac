import SwiftUI

/// Triangle covering the top-left half of its bounding rect, separated by the
/// diagonal from bottom-left to top-right. Used to render per-entity tile
/// halves in 2-entity aggregate tiles.
struct TopLeftTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
