import SwiftUI

enum TileFill {
    /// Returns the background color for a tile region at the given intensity.
    /// 0.0 → dim gray (off), 1.0 → full accent. Partial brightness (e.g. a
    /// light at 43%) scales opacity proportionally so dimmer states read as
    /// "on but lower".
    static func color(for intensity: Double) -> Color {
        let clamped = max(0, min(1, intensity))
        if clamped <= 0 {
            return Color.gray.opacity(0.18)
        }
        // Keep a floor so even a 1% dim reads as "on", ramp up to full.
        let opacity = 0.10 + 0.18 * clamped
        return Color.accentColor.opacity(opacity)
    }
}
