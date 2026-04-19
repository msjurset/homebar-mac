import SwiftUI

/// Transport button that distinguishes a short tap from a press-and-hold.
/// Short tap → `onTap()`. Hold past the threshold → `onHoldBegin()` immediately,
/// repeated `onHoldTick()` every interval, and `onHoldEnd()` on release.
struct HoldableTransportButton: View {
    let systemName: String
    var size: CGFloat = 10
    var holdThreshold: TimeInterval = 0.4
    var tickInterval: TimeInterval = 0.25
    let onTap: () -> Void
    let onHoldTick: () -> Void

    @State private var holdActive = false
    @State private var pressTask: Task<Void, Never>?
    @State private var tickTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { _ in
                        guard pressTask == nil else { return }
                        pressTask = Task {
                            try? await Task.sleep(nanoseconds: UInt64(holdThreshold * 1_000_000_000))
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                holdActive = true
                                onHoldTick()
                                tickTask = Task {
                                    while !Task.isCancelled {
                                        try? await Task.sleep(nanoseconds: UInt64(tickInterval * 1_000_000_000))
                                        if Task.isCancelled { break }
                                        await MainActor.run { onHoldTick() }
                                    }
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        pressTask?.cancel()
                        pressTask = nil
                        tickTask?.cancel()
                        tickTask = nil
                        if !holdActive {
                            onTap()
                        }
                        holdActive = false
                    }
            )
    }
}
