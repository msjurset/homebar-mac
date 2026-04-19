import SwiftUI

/// Single-line text that bounces left then back when it overflows its
/// container. Static when the text fits.
struct Marquee: View {
    let text: String
    var font: Font = .system(size: 8, weight: .medium)

    @State private var offset: CGFloat = 0
    @State private var overflow: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { textGeo in
                        Color.clear.task(id: "\(text)-\(Int(geo.size.width))") {
                            let over = max(0, textGeo.size.width - geo.size.width + 4)
                            offset = 0
                            overflow = over
                            guard over > 0 else { return }
                            // Short pause at edges; linear slide in between.
                            let duration = max(2.5, Double(over) / 18.0)
                            withAnimation(
                                .linear(duration: duration)
                                    .repeatForever(autoreverses: true)
                                    .delay(0.8)
                            ) {
                                offset = -over
                            }
                        }
                    }
                )
                .offset(x: offset)
        }
        .clipped()
    }
}
