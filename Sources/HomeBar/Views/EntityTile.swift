import SwiftUI
import AppKit

struct EntityTile: View {
    let entity: HAEntity
    let displayName: String
    let areaName: String?
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
    let onSetSliderValue: (Double) -> Void
    let onToggleWatch: () -> Void
    let onMediaAction: (HomeBarStore.MediaAction) -> Void
    let otherMediaPlayers: [HAEntity]
    let onMediaGroupJoin: (String) -> Void
    let onMediaGroupUnjoin: (String) -> Void

    @State private var isHovering = false
    @State private var editing = false
    @State private var editText = ""
    @State private var dragIntensity: Double?
    /// Value the user just dropped to. Held until HA state_changed catches up
    /// (or a short timeout) so the slider doesn't bounce off the old cached
    /// brightness.
    @State private var pendingIntensity: Double?
    @State private var pendingClearTask: Task<Void, Never>?
    @State private var showGroupPopover = false
    @State private var showPlayURL = false
    @State private var playURLText = ""
    @FocusState private var editFocused: Bool

    private var isOn: Bool {
        switch entity.state {
        case "on", "open", "unlocked", "playing", "home", "active": return true
        default: return false
        }
    }

    private var iconName: String {
        EntityIcons.name(for: entity)
    }

    private var stateLabel: String {
        let s = entity.state
        guard !s.isEmpty else { return "" }
        if ["automation", "script", "scene"].contains(entity.domain) {
            switch s {
            case "on": return "enabled"
            case "off": return "disabled"
            default: return s.replacingOccurrences(of: "_", with: " ")
            }
        }
        if entity.domain == "light", isOn,
           case .number(let b) = entity.attributes["brightness"] {
            let pct = Int((b / 255.0 * 100).rounded())
            return "on · \(pct)%"
        }
        return s.replacingOccurrences(of: "_", with: " ")
    }

    private var typeLabel: String {
        switch entity.domain {
        case "light": return "Light"
        case "switch": return "Switch"
        case "input_boolean": return "Toggle"
        case "fan": return "Fan"
        case "script": return "Script"
        case "scene": return "Scene"
        case "automation": return "Automation"
        case "button", "input_button": return "Button"
        case "cover": return "Cover"
        case "lock": return "Lock"
        case "media_player": return "Media"
        case "sensor": return "Sensor"
        case "binary_sensor": return "Sensor"
        case "person": return "Person"
        case "weather": return "Weather"
        case "device_tracker": return "Tracker"
        case "climate": return "Climate"
        case "remote": return "Remote"
        case "select": return "Select"
        case "number": return "Number"
        default: return entity.domain.replacingOccurrences(of: "_", with: " ").capitalized
        }
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
        } else {
            let intensity = aggregate?.intensities.first ?? selfIntensity
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TileFill.color(for: intensity))
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            icon
            nameAndState
            Spacer(minLength: 0)
            pinButton
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(tileBackground)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard !editing else { return }
            if NSEvent.modifierFlags.contains(.option) {
                copyDebugInfo()
                return
            }
            guard actionable else { return }
            onTap()
        }
        .contextMenu { contextMenu }
        .help(tooltip)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5, maximumDistance: 4)
                .onEnded { _ in
                    if entity.domain == "media_player" {
                        showGroupPopover = true
                    }
                }
        )
        .popover(isPresented: $showGroupPopover, arrowEdge: .trailing) {
            MediaGroupPopover(
                leader: entity,
                displayName: displayName,
                otherMediaPlayers: otherMediaPlayers,
                onJoin: { onMediaGroupJoin($0) },
                onUnjoin: { onMediaGroupUnjoin($0) }
            )
        }
        .alert("Play URL", isPresented: $showPlayURL, actions: playURLActions, message: playURLMessage)
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

    private var tooltip: String {
        var s = entity.friendlyName
        if !entity.state.isEmpty {
            s += " · \(typeLabel) · \(entity.state)"
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

    @ViewBuilder
    private var tileBackground: some View {
        ZStack {
            if isHovering && actionable && !editing {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            }
            if isSelected && !editing {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
            }
        }
    }

    private var icon: some View {
        ZStack {
            iconBackground
                .frame(width: 34, height: 34)
            MDIIcon(name: iconName, size: 20)
                .foregroundStyle(iconTint)
            if let hotkey {
                Text(hotkey.uppercased())
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.28))
                    .frame(width: 34, height: 34, alignment: .bottomTrailing)
                    .padding(.trailing, 3)
                    .padding(.bottom, 2)
                    .help("⌥\(hotkey.uppercased())")
            }
            if isWatched {
                Image(systemName: "eye.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(HomeBarStore.isWatchAlert(entity) ? Color.orange : Color.secondary.opacity(0.7))
                    .frame(width: 34, height: 34, alignment: .topLeading)
                    .padding(.leading, 3)
                    .padding(.top, 3)
                    .help(HomeBarStore.isWatchAlert(entity) ? "Watched — alerting" : "Watched")
            }
        }
    }

    @ViewBuilder
    private var nameAndState: some View {
        VStack(alignment: .leading, spacing: 2) {
            if editing {
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .focused($editFocused)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                            )
                    )
                    .onSubmit { commit() }
                    .onExitCommand { cancelEdit() }
                    .onChange(of: editFocused) { _, focused in
                        if !focused && editing { commit() }
                    }
            } else {
                HStack(spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if hasAlias {
                        Image(systemName: "pencil")
                            .font(.system(size: 7, weight: .regular))
                            .foregroundStyle(.tertiary.opacity(0.55))
                            .help("Renamed · HA name: \(entity.friendlyName)")
                    }
                }
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 5, height: 5)
                    .opacity(stateLabel.isEmpty ? 0 : 0.9)
                Text(typeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                Text(stateLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(stateColor)
                if let areaName {
                    Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text(areaName)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if isSlidable {
                sliderRow
            }
        }
    }

    private var sliderRow: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.22))
                Capsule()
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: max(0, geo.size.width * effectiveIntensity))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let pct = max(0, min(1, value.location.x / max(1, geo.size.width)))
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
            )
        }
        .frame(height: 3)
        .padding(.top, 3)
    }

    private func schedulePendingIntensityClear() {
        pendingClearTask?.cancel()
        pendingClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            pendingIntensity = nil
        }
    }

    private var pinButton: some View {
        Button(action: onTogglePin) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11))
                .foregroundStyle(isPinned ? Color.accentColor : Color.secondary.opacity(isHovering ? 0.9 : 0.35))
                .rotationEffect(.degrees(isPinned ? -30 : 0))
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Unpin" : "Pin to favorites")
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(isPinned ? "Unpin" : "Pin to Favorites") { onTogglePin() }
        Button(isWatched ? "Stop Watching" : "Watch for Alerts") { onToggleWatch() }
        Divider()
        Button("Rename…") { beginEdit() }
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

    private func beginEdit() {
        editText = displayName
        editing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            editFocused = true
            // After focus settles, select all so typing replaces the name.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private func commit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        if trimmed.isEmpty || trimmed == entity.friendlyName {
            onRename(nil)
        } else {
            onRename(trimmed)
        }
    }

    private func cancelEdit() {
        editing = false
        editText = ""
    }
}
