# Project Rules

- Do not add any Claude or Anthropic authorship references (Co-Authored-By, comments, documentation, commit messages, or otherwise) anywhere in this project.

# Pending fix — phantom autofill popup hardening

`Sources/HomeBar/Views/Components/FilterField.swift` is missing a
structural fix that prevents phantom-popup regressions across all
sheets, popovers, and new-window surfaces. Apply on the next change
to this project — 9 lines, no behavior change for existing fields.

In `NoAutoFillTextField` (alongside the existing `becomeFirstResponder`
and `textDidBeginEditing` overrides) add:

```swift
override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Layer-5 install at the earliest moment a field's window is
    // known. AppKit calls this synchronously when the view is
    // attached to a window — before any focus event is possible —
    // so our shared field-editor singleton is wired before
    // becomeFirstResponder fires. Eliminates per-call-site
    // DispatchQueue.main.async install races.
    if let window {
        installFieldEditorInterceptor(on: window)
    }
}
```

Then remove any per-call-site `DispatchQueue.main.async {
installFieldEditorInterceptor(on: field.window) }` shims — the
override makes them unnecessary and is guaranteed to beat any
focus event.

Reference implementation:
`~/workspace/swift/stash-mac/Sources/StashMac/Views/Components/FilterField.swift`
(canonical as of 2026-05-07).

# Build & Test

- Build: `swift build` or `make build` (release)
- Test: `swift test` or `make test`
- Deploy: `make deploy` (builds, bundles, installs to /Applications)
- Generate Xcode project: `xcodegen generate`

# Architecture

HomeBar is a SwiftUI menu bar app for fast Home Assistant control.

- Swift 6.0, macOS 15+, SPM, zero external dependencies
- Menu-bar-only (LSUIElement=true) — no dock icon, no main window
- `MenuBarExtra(style: .window)` for the popover UI
- `@Observable` + `@MainActor` for state management
- HA access via direct WebSocket (URLSessionWebSocketTask) + REST (URLSession), no third-party client libs

# Data Storage

- `~/.homebar/config.json` — base URL, UI prefs, watch set
- `~/.homebar/pins.json` — pinned tile order
- `~/.homebar/recents.json` — auto-promoted recently used actions
- macOS Keychain — long-lived HA access token (never written to disk)

# HA Connection

- WebSocket: `ws(s)://<base>/api/websocket`
- Auth: send `{type:"auth",access_token:"..."}` after `auth_required`
- Snapshot: `{type:"get_states"}`
- Live: `{type:"subscribe_events",event_type:"state_changed"}`
- Actions: `{type:"call_service",domain,service,target,service_data}`
- Areas: `{type:"config/area_registry/list"}`
- Notifications: subscribe to `persistent_notifications_updated`
