import SwiftUI
import AppKit

/// Square grid tile. Icon on top, name below, subtle hotkey watermark.
struct EntityTileCompact: View {
    let entity: HAEntity
    let displayName: String
    let isPinned: Bool
    let hasAlias: Bool
    let hotkey: String?
    let aggregate: HomeBarStore.TileAggregate?
    let isWatched: Bool
    let isSelected: Bool
    let isOptionHeld: Bool
    let onTap: () -> Void
    let onTogglePin: () -> Void
    let onRename: (String?) -> Void
    /// Value is 0–1. Parent dispatches to the correct service (light brightness
    /// or media_player volume) based on the entity's domain.
    let onSetSliderValue: (Double) -> Void
    let onToggleWatch: () -> Void
    let onMediaAction: (HomeBarStore.MediaAction) -> Void
    let otherMediaPlayers: [HAEntity]
    let onMediaGroupJoin: (String) -> Void
    let onMediaGroupUnjoin: (String) -> Void

    @State private var isHovering = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var dragIntensity: Double?
    /// Value the user just dropped to. Kept visible until the HA state_changed
    /// event catches up (or a short timeout), so the slider doesn't snap back
    /// to the old cached brightness mid-round-trip.
    @State private var pendingIntensity: Double?
    @State private var pendingClearTask: Task<Void, Never>?
    @State private var scrubPreview: Double?
    @State private var showGroupPopover = false
    @State private var showPlayURL = false
    @State private var playURLText = ""

    private var isOn: Bool {
        switch entity.state {
        case "on", "open", "unlocked", "playing", "home", "active": return true
        default: return false
        }
    }

    private var iconName: String {
        EntityIcons.name(for: entity)
    }

    private var stateColor: Color {
        switch entity.state {
        case "unavailable", "unknown": return .orange
        case "on", "open", "unlocked", "playing", "home", "active", "heat", "cool":
            return .green
        default:
            return .secondary
        }
    }

    private var actionable: Bool { !EntityAction.isStatusOnly(entity) }

    private var iconTint: Color {
        if let aggregate {
            return aggregate.anyOn ? Color.accentColor : .secondary
        }
        return isOn ? Color.accentColor : .secondary
    }

    private var selfIntensity: Double {
        HomeBarStore.intensity(for: entity)
    }

    private var isSlidable: Bool {
        HomeBarStore.isSlidable(entity)
    }

    private var effectiveIntensity: Double {
        dragIntensity ?? pendingIntensity ?? selfIntensity
    }

    @ViewBuilder
    private var iconBackground: some View {
        if let agg = aggregate, agg.count == 2 {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TileFill.color(for: agg.intensities[1]))
                TopLeftTriangle()
                    .fill(TileFill.color(for: agg.intensities[0]))
                TopLeftTriangle()
                    .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let agg = aggregate, agg.count >= 3 {
            VStack(spacing: 0) {
                ForEach(Array(agg.intensities.enumerated()), id: \.offset) { _, i in
                    Rectangle()
                        .fill(TileFill.color(for: i))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if isSlidable {
            // Dimmable slider visual: accent gradient fills from bottom,
            // thin highlight line at the top of the fill acts as a thumb,
            // and the current % pops above (if near full) or below the line.
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.gray.opacity(0.18))
                    if effectiveIntensity > 0 {
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.18),
                                Color.accentColor.opacity(0.42),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: geo.size.height * effectiveIntensity)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.75))
                                .frame(height: 1)
                        }
                    }
                    percentLabel(height: geo.size.height)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        } else {
            let intensity = aggregate?.intensities.first ?? selfIntensity
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TileFill.color(for: intensity))
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            iconStack
            Text(displayName)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
        }
        .padding(3)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.option) {
                copyDebugInfo()
                return
            }
            guard actionable else { return }
            onTap()
        }
        .onHover { isHovering = $0 }
        .contextMenu { menu }
        .help(tooltip)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5, maximumDistance: 4)
                .onEnded { _ in
                    if entity.domain == "media_player" {
                        showGroupPopover = true
                    }
                }
        )
        .popover(isPresented: $showGroupPopover, arrowEdge: .bottom) {
            MediaGroupPopover(
                leader: entity,
                displayName: displayName,
                otherMediaPlayers: otherMediaPlayers,
                onJoin: { onMediaGroupJoin($0) },
                onUnjoin: { onMediaGroupUnjoin($0) }
            )
        }
        .alert("Rename", isPresented: $showRename, actions: renameActions, message: renameMessage)
        .alert("Play URL", isPresented: $showPlayURL, actions: playURLActions, message: playURLMessage)
        .onChange(of: showRename) { _, shown in
            guard shown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
        .onChange(of: showPlayURL) { _, shown in
            guard shown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
        .onChange(of: selfIntensity) { _, new in
            guard let pending = pendingIntensity else { return }
            if abs(new - pending) < 0.02 {
                pendingIntensity = nil
                pendingClearTask?.cancel()
                pendingClearTask = nil
            }
        }
    }

    private var tooltip: String {
        var s = entity.friendlyName
        if !entity.state.isEmpty {
            s += " · \(stateLabel)"
        }
        if entity.domain == "media_player",
           case .string(let title) = entity.attributes["media_title"], !title.isEmpty {
            var nowPlaying = title
            if case .string(let artist) = entity.attributes["media_artist"], !artist.isEmpty {
                nowPlaying += " — \(artist)"
            }
            s += "\n\(nowPlaying)"
        }
        if let hotkey {
            s += "  (⌥\(hotkey.uppercased()))"
        }
        return s
    }

    private var isMediaPlaying: Bool {
        entity.domain == "media_player" && entity.state == "playing"
    }

    private var showsTransport: Bool {
        entity.domain == "media_player" && isOptionHeld && isHovering
    }

    private var stateLabel: String {
        let s = entity.state
        if ["automation", "script", "scene"].contains(entity.domain) {
            switch s {
            case "on": return "enabled"
            case "off": return "disabled"
            default: break
            }
        }
        return s.replacingOccurrences(of: "_", with: " ")
    }

    private var iconStack: some View {
        GeometryReader { geo in
            ZStack {
                iconBackground
                MDIIcon(name: iconName, size: 32)
                    .foregroundStyle(iconTint)
                    .allowsHitTesting(false)
                if let hotkey {
                    Text(hotkey.uppercased())
                        .font(.system(size: 7, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.30))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.trailing, 4)
                        .padding(.top, 3)
                        .allowsHitTesting(false)
                }
                Circle()
                    .fill(stateColor)
                    .frame(width: 5, height: 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 4)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
                if isPinned {
                    Button(action: onTogglePin) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(Color.accentColor.opacity(0.9))
                            .rotationEffect(.degrees(-30))
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .help("Unpin")
                }
                if isWatched {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(HomeBarStore.isWatchAlert(entity) ? Color.orange : Color.secondary.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.leading, 3)
                        .padding(.top, 3)
                        .allowsHitTesting(false)
                }
                if showsTransport {
                    mediaTransportOverlay
                }
            }
            .gesture(sliderGesture(height: geo.size.height), including: isSlidable && !showsTransport ? .all : .subviews)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private var mediaTransportOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.62))
            VStack(spacing: 3) {
                if case .string(let title) = entity.attributes["media_title"], !title.isEmpty {
                    Marquee(text: mediaHeaderText(title: title),
                            font: .system(size: 8, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(height: 11)
                        .padding(.horizontal, 4)
                }
                HStack(spacing: 2) {
                    HoldableTransportButton(
                        systemName: "backward.fill",
                        onTap: { onMediaAction(.previous) },
                        onHoldTick: { onMediaAction(.seekRelative(-5)) }
                    )
                    transportButton(systemName: "gobackward.10") {
                        onMediaAction(.seekRelative(-10))
                    }
                    transportButton(systemName: isMediaPlaying ? "pause.fill" : "play.fill", size: 13) {
                        onMediaAction(.playPause)
                    }
                    transportButton(systemName: "goforward.10") {
                        onMediaAction(.seekRelative(10))
                    }
                    HoldableTransportButton(
                        systemName: "forward.fill",
                        onTap: { onMediaAction(.next) },
                        onHoldTick: { onMediaAction(.seekRelative(5)) }
                    )
                }
                if HomeBarStore.mediaDuration(entity) != nil {
                    progressSection
                        .padding(.horizontal, 4)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = HomeBarStore.mediaDuration(entity) ?? 0
            let live = HomeBarStore.mediaPosition(for: entity, at: context.date) ?? 0
            let displayPos = scrubPreview ?? min(live, duration)
            let fraction = duration > 0 ? max(0, min(1, displayPos / duration)) : 0
            VStack(spacing: 1) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.25))
                        Capsule()
                            .fill(Color.white.opacity(0.75))
                            .frame(width: geo.size.width * fraction)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                let f = max(0, min(1, value.location.x / max(1, geo.size.width)))
                                scrubPreview = f * duration
                            }
                            .onEnded { value in
                                let f = max(0, min(1, value.location.x / max(1, geo.size.width)))
                                onMediaAction(.seekAbsolute(f * duration))
                                scrubPreview = nil
                            }
                    )
                }
                .frame(height: 3)
                HStack {
                    Text(formatMediaTime(displayPos))
                    Spacer()
                    Text(formatMediaTime(duration))
                }
                .font(.system(size: 7, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private func formatMediaTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))"
        }
        return "\(m):\(String(format: "%02d", s))"
    }

    private func mediaHeaderText(title: String) -> String {
        if case .string(let artist) = entity.attributes["media_artist"], !artist.isEmpty {
            return "\(title) — \(artist)"
        }
        return title
    }

    private func transportButton(systemName: String, size: CGFloat = 10, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 15, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func percentLabel(height: CGFloat) -> some View {
        let pct = Int(round(effectiveIntensity * 100))
        let lineY = height * (1 - effectiveIntensity)
        // When brightness is low (≤20%) the line is near the bottom and there
        // isn't room below for the label — pop it above. Otherwise put it
        // inside the fill area just under the line.
        let popAbove = effectiveIntensity <= 0.20
        let labelY = popAbove ? lineY - 12 : lineY + 3
        Text("\(pct)%")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: 0, y: max(0, labelY))
            .padding(.leading, 4)
    }

    private func sliderGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard isSlidable, height > 0 else { return }
                let pct = max(0, min(1, 1.0 - value.location.y / height))
                dragIntensity = pct
            }
            .onEnded { _ in
                if let pct = dragIntensity {
                    pendingIntensity = pct
                    onSetSliderValue(pct)
                    schedulePendingIntensityClear()
                }
                dragIntensity = nil
            }
    }

    /// Drop the optimistic pending value after a few seconds in case the HA
    /// state_changed event never arrives (e.g. command rejected, bulb offline).
    private func schedulePendingIntensityClear() {
        pendingClearTask?.cancel()
        pendingClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            pendingIntensity = nil
        }
    }

    @ViewBuilder
    private var background: some View {
        ZStack {
            if isHovering && actionable {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            }
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(isPinned ? "Unpin" : "Pin to Favorites") { onTogglePin() }
        Button(isWatched ? "Stop Watching" : "Watch for Alerts") { onToggleWatch() }
        Divider()
        Button("Rename…") { beginRename() }
        if hasAlias {
            Button("Reset to HA Name") { onRename(nil) }
        }
        if entity.domain == "media_player" {
            Divider()
            Button("Previous Track") { onMediaAction(.previous) }
            Button("Next Track") { onMediaAction(.next) }
            Button("Stop") { onMediaAction(.stop) }
            Button("Toggle Mute") { onMediaAction(.toggleMute) }
            mediaShuffleRepeatButtons
            mediaSourceMenu
            Button("Play URL…") { beginPlayURL() }
            Button("Play Diagnostic") { onMediaAction(.playDiagnostic) }
        }
        if entity.domain == "automation" {
            Divider()
            Button("Choose Tile Entities…") {
                AppController.shared.openAutomationConfig(for: entity)
            }
        }
        Divider()
        Button("Copy Entity ID") { copyDebugInfo() }
    }

    private func copyDebugInfo() {
        var parts = [entity.entityID]
        if case .string(let id) = entity.attributes["id"] {
            parts.append("id: \(id)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "\n"), forType: .string)
    }

    @ViewBuilder
    private var mediaShuffleRepeatButtons: some View {
        Button("Shuffle: \(HomeBarStore.mediaShuffleOn(entity) ? "On" : "Off")") {
            onMediaAction(.toggleShuffle)
        }
        Button("Repeat: \(HomeBarStore.mediaRepeatMode(entity).capitalized)") {
            onMediaAction(.cycleRepeat)
        }
    }

    @ViewBuilder
    private var mediaSourceMenu: some View {
        let sources = HomeBarStore.mediaSources(entity)
        if !sources.isEmpty {
            let current = HomeBarStore.mediaCurrentSource(entity)
            Menu("Source") {
                ForEach(sources, id: \.self) { src in
                    Button(src == current ? "✓ \(src)" : src) {
                        onMediaAction(.selectSource(src))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func renameActions() -> some View {
        TextField("Name", text: $renameText)
        Button("Save") { saveRename() }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private func renameMessage() -> some View {
        Text("HA name: \(entity.friendlyName)")
    }

    private func saveRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == entity.friendlyName {
            onRename(nil)
        } else {
            onRename(trimmed)
        }
    }

    private func beginRename() {
        renameText = displayName
        showRename = true
    }

    private func beginPlayURL() {
        playURLText = ""
        showPlayURL = true
    }

    @ViewBuilder
    private func playURLActions() -> some View {
        TextField("https://…", text: $playURLText)
        Button("Play") {
            let trimmed = playURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onMediaAction(.playURL(trimmed))
        }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private func playURLMessage() -> some View {
        Text("Enter an audio URL. HomeBar will cast it via `media_player.play_media`.")
    }
}
