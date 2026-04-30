# HomeBar

A macOS menu bar app for fast Home Assistant control. Raycast-style popover — `⌘/` to open, type to find, click to fire, drag to dim.

## Features

**Search & fire**
- Pinned favorites, recents, and frequent-use sections
- Free-text search across name, entity_id, and area, plus structured filters: `is:watched|alerting|on|off`, `domain:<domain>`, `area:<name>`. Tokens AND together with free text.
- Tab opens an autocomplete dropdown of valid keys/values; arrow keys / Ctrl-J/K cycle, Enter commits. Already-used tokens are excluded from suggestions.
- Subtle hotkey watermarks on tiles — `⌥1..9` and `⌥A..Z` to fire up to 35 tiles without the mouse
- Right-click → "Copy Entity ID" (or ⌥-click) for debugging

**Tiles**
- List and grid (tile) view; your choice persists
- Drag pinned tiles to reorder them (grid or list)
- Material Design Icons (MDI): honors HA's per-entity `icon: mdi:...` attribute
- Local aliases — rename tiles without pushing back to HA (tap to inline-edit or right-click → Rename)
- Watched tiles show a small eye indicator — orange when alerting, dim when nominal
- Type label + state + area shown compactly in list view

**Automations**
- Aggregate tile coloring for the entities an automation controls (fetched once per connect via REST)
- 2 affected entities: diagonal split, each half reflecting its entity's state
- 3+ entities: horizontal stacked strips, one per entity
- Intensity mapping: dimmed lights show proportional accent (a light at 43% reads visibly dimmer than one at 100%)

**Dimmable lights**
- Glass-fill slider: tile background fills bottom-up proportional to brightness
- Drag vertically on the tile to adjust; release commits via `light.turn_on` with `brightness_pct`
- Thin accent thumb line with floating "43%" readout (above the line at ≤20%, inside the fill otherwise)

**Alerts**
- Right-click any tile → "Watch for Alerts" adds it to the watch set
- Menu bar icon tints orange when any watched entity is in an off-nominal state (anything other than `off`, `closed`, `locked`, `home`, `safe`, `disarmed`, `docked`, `stopped`, `idle`, `ok`)
- Watched tiles get a small eye badge; it goes orange when that tile is the one alerting
- Subscribes to HA's `persistent_notifications_updated` → delivers native macOS banners with a Dismiss action that routes back to `persistent_notification.dismiss`

**Auth**
- Direct long-lived access token (stored at `~/.homebar/token`, 0600), or
- 1Password reference — paste an `op://vault/item/field` into the token field; resolved via `op read` on every connect (Touch ID when 1Password CLI integration is enabled)

**System integration**
- Global `⌘/` hotkey to toggle
- Right-click menu bar icon → Launch at Login (writes a user LaunchAgent plist + `launchctl bootstrap`s it)

**Speak from HA**
- HomeBar subscribes to `homebar_speak` events on the HA WebSocket — automations can push TTS or audio playback to your Mac without any inbound port or HA custom component. Examples:
  ```yaml
  # Text-to-speech on the Mac's default output
  - event: homebar_speak
    event_data:
      message: "Garage door left open"

  # Adjust rate (0.0–1.0) and volume (0.0–1.0)
  - event: homebar_speak
    event_data:
      message: "Mail is here"
      rate: 0.45
      volume: 0.7

  # Play a remote audio file instead
  - event: homebar_speak
    event_data:
      media_url: "http://ha:8123/local/doorbell.mp3"

  # Target a specific Mac (so multiple HomeBar installs don't all speak)
  - event: homebar_speak
    event_data:
      target: marks-mac
      message: "Your 3pm meeting"

  # Target multiple specific Macs
  - event: homebar_speak
    event_data:
      target: [marks-mac, kims-mac]
      message: "Dinner's ready"
  ```
- Pick a specific macOS voice by passing its identifier in `voice` (e.g. `com.apple.voice.compact.en-US.Samantha`).
- With no `target`, every connected HomeBar instance speaks. Each install has an **Instance Name** in Settings (defaults to the Mac's host name) — only instances whose name matches the `target` (or all of them when `target` is omitted) will respond.

## Requirements

- macOS 15.0 (Sequoia) or later
- Home Assistant instance reachable over the local network
- Optional: `1password-cli` (`brew install 1password-cli`) with "Connect with 1Password CLI" enabled in the 1Password app

## Build & Deploy

```sh
make deploy          # build, bundle, sign, install to /Applications, launch
make build           # release build only
swift test           # unit tests (HAConfig, EntityAction, EntityIcons, intensity, slidable, watch, media)
```

## First-time Setup

### 1. Create a stable codesigning cert (one-time)

Ad-hoc signed apps get a new signature hash on every rebuild, which causes macOS TCC and 1Password to treat each build as a new app and re-prompt for permissions.

```sh
make cert
```

Then: Keychain Access → find `HomeBar Dev` → Get Info → Trust → **Always Trust**. Enter your login password.

From here on every `make deploy` reuses the same signature, so TCC and 1Password decisions stick.

### 2. Configure Home Assistant

Right-click the menu bar icon → **Settings…**
- **Base URL**: e.g. `http://ha:8123` or `http://homeassistant.local:8123`
- **Token**: paste either a [long-lived access token](https://www.home-assistant.io/docs/authentication/#your-account-profile) or a 1Password reference like `op://Private/HomeAssistant/credential`
- Click **Test Connection**, then **Save**

### 3. (Optional) Launch at Login

Right-click the menu bar icon → **Launch at Login** ✓

## Data

- `~/.homebar/config.json` — base URL, watch set, optional 1Password ref
- `~/.homebar/token` — long-lived access token (0600) when not using 1Password
- `~/.homebar/pins.json` — pinned entity_ids (order preserved)
- `~/.homebar/recents.json` — last ~30 fired entities
- `~/.homebar/counts.json` — per-entity fire counts (for Frequent view)
- `~/.homebar/aliases.json` — local display-name overrides

## Architecture

- Swift 6.0, macOS 15+, SPM, zero external Swift dependencies
- `@main enum HomeBarMain` with `NSApplication.accessory` activation policy (no dock icon)
- Custom `NSPanel` subclass (`FloatingPanel`) hosting the SwiftUI `PopoverView` via `NSHostingView`
- `HAClient` actor: URLSessionWebSocketTask for live state + commands, URLSession for REST (automation config fetch). A 30-second ping heartbeat and an unexpected-disconnect stream drive automatic reconnect with exponential backoff; `NSWorkspace.didWakeNotification` forces an immediate resync after sleep so tiles don't show stale state.
- `HomeBarStore` — `@Observable @MainActor`, owns entities, pins, aliases, recents, and aggregate computation
- Resources bundled: MDI font (`materialdesignicons.ttf`) + name→codepoint map (`mdi-map.json`)

## Releases & Updates

HomeBar ships with [Sparkle](https://sparkle-project.org) for in-app auto-updates. The About window (right-click menu bar icon → About) shows the installed version and has a **Check for Updates…** button.

Tagged releases are built by GitHub Actions and published as a notarized DMG plus an `appcast.xml` that Sparkle polls.

### Cutting a release (maintainers)

```sh
make release VERSION=1.2.3
```

`scripts/release.sh` bumps `Info.plist` + `project.yml`, builds, bundles
`Sparkle.framework`, codesigns with Developer ID + hardened runtime,
notarizes via `xcrun notarytool`, staples the ticket, signs the DMG with
Sparkle's EdDSA key, regenerates `appcast.xml`, commits, tags `vX.Y.Z`,
pushes, and creates a GitHub release with the DMG attached.

**One-time setup:**
- Developer ID cert (`Developer ID Application: Mark Sjurseth (...)`) in the
  login keychain
- `xcrun notarytool store-credentials notarytool-profile` (uses an Apple ID
  + app-specific password)
- Sparkle keypair: run `.build/artifacts/sparkle/Sparkle/bin/generate_keys`;
  paste the public key into `Info.plist` → `SUPublicEDKey`. The private key
  lives in the keychain and is read by `sign_update` at release time.
- For the CI fallback path (tag push → `release.yml`), store the private
  key as a repo secret named `SPARKLE_PRIVATE_KEY`.

## License

MIT — see [LICENSE](LICENSE).

Third-party components and their licenses are listed in [NOTICES.md](NOTICES.md).
