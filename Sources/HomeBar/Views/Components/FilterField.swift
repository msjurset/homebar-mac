import AppKit
import SwiftUI

/// NSTextField subclass that disables every macOS auto-* behavior on its field
/// editor (the shared NSTextView). Required because SwiftUI's `TextField` on
/// macOS shows a system autofill popover that no SwiftUI modifier can disable,
/// and our custom suggestion dropdown needs to own that UI slot.
final class NoAutoFillTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { disableAutoFeatures() }
        return ok
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        disableAutoFeatures()
    }

    override func textShouldBeginEditing(_ textObject: NSText) -> Bool {
        let ok = super.textShouldBeginEditing(textObject)
        disableAutoFeatures()
        return ok
    }

    private func disableAutoFeatures() {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        // macOS 14+ added an inline-prediction bar that renders as a
        // large ghost popup beneath the field on focus. The auto-* flags
        // above don't suppress it; this trait does.
        if #available(macOS 14.0, *) {
            editor.inlinePredictionType = .no
        }
    }
}

/// Keys a FilterField host wants a chance to handle before the field editor
/// sees them. Return `true` to consume (FilterField won't invoke default
/// behavior), or `false` to let the field editor process normally.
enum FilterFieldKey {
    case tab
    case backTab
    case arrowDown
    case arrowUp
    case enter
    case escape
    /// Ctrl-J — same semantic as arrowDown per CLAUDE.md autocomplete spec.
    case ctrlJ
    /// Ctrl-K — same semantic as arrowUp per CLAUDE.md autocomplete spec.
    case ctrlK
}

struct FilterField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont = .systemFont(ofSize: 12)
    /// One-shot caret move request. When non-nil, the field positions its
    /// caret there and then clears the binding so the request isn't applied
    /// twice. User-driven cursor moves never write to this binding — the
    /// source of truth for the live caret is the field editor itself.
    @Binding var pendingCursor: Int?
    /// Called with the current caret location on every edit/selection change.
    var onCursorChange: (Int) -> Void = { _ in }
    /// Called when the user presses a key of interest. Return true to consume.
    var onKey: (FilterFieldKey) -> Bool = { _ in false }
    /// Called on submit (Enter when onKey returns false). Matches TextField.onSubmit semantics.
    var onSubmit: () -> Void = {}
    /// When true, the field requests focus on `updateNSView`.
    var wantsFocus: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NoAutoFillTextField {
        let tf = NoAutoFillTextField()
        tf.delegate = context.coordinator
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.bezelStyle = .squareBezel
        tf.font = font
        tf.placeholderString = placeholder
        tf.stringValue = text
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.cell?.usesSingleLineMode = true
        context.coordinator.installKeyMonitor(for: tf)
        return tf
    }

    static func dismantleNSView(_ tf: NoAutoFillTextField, coordinator: Coordinator) {
        coordinator.removeKeyMonitor()
    }

    func updateNSView(_ tf: NoAutoFillTextField, context: Context) {
        if tf.stringValue != text {
            tf.stringValue = text
        }
        if tf.placeholderString != placeholder {
            tf.placeholderString = placeholder
        }
        context.coordinator.parent = self
        if let cursor = pendingCursor,
           let editor = tf.currentEditor() as? NSTextView {
            let clamped = max(0, min(cursor, (tf.stringValue as NSString).length))
            editor.selectedRange = NSRange(location: clamped, length: 0)
            // Consume the request so the next render doesn't re-apply it and
            // fight the user's live typing.
            DispatchQueue.main.async { self.pendingCursor = nil }
        }
        if wantsFocus, tf.window?.firstResponder !== tf.currentEditor() {
            DispatchQueue.main.async {
                tf.window?.makeFirstResponder(tf)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
        var parent: FilterField
        private var keyMonitor: Any?
        private weak var hostField: NSTextField?

        init(_ parent: FilterField) { self.parent = parent }

        func installKeyMonitor(for tf: NSTextField) {
            hostField = tf
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyEvent(event) ?? event
            }
        }

        private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
            // Key monitors always fire on the main thread; the helper is
            // @MainActor-isolated so AppKit property access is legal without
            // per-line assumeIsolated boilerplate.
            guard let tf = hostField else { return event }
            guard let window = tf.window,
                  let editor = tf.currentEditor(),
                  window.firstResponder === editor else { return event }
            let hasControl = event.modifierFlags.contains(.control)
            let otherMods: NSEvent.ModifierFlags = [.command, .option, .shift]
            guard hasControl, event.modifierFlags.intersection(otherMods).isEmpty else { return event }
            switch event.keyCode {
            case 38: // J
                if parent.onKey(.ctrlJ) { return nil }
            case 40: // K
                if parent.onKey(.ctrlK) { return nil }
            default:
                break
            }
            return event
        }

        func removeKeyMonitor() {
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
            keyMonitor = nil
            hostField = nil
        }

        // Monitor cleanup happens in dismantleNSView — no deinit needed.

        func controlTextDidChange(_ notification: Notification) {
            guard let tf = notification.object as? NSTextField else { return }
            parent.text = tf.stringValue
            if let editor = tf.currentEditor() as? NSTextView {
                parent.onCursorChange(editor.selectedRange.location)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.onCursorChange(tv.selectedRange.location)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                return parent.onKey(.tab)
            case #selector(NSResponder.insertBacktab(_:)):
                return parent.onKey(.backTab)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onKey(.arrowDown)
            case #selector(NSResponder.moveUp(_:)):
                return parent.onKey(.arrowUp)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onKey(.escape)
            case #selector(NSResponder.insertNewline(_:)):
                if parent.onKey(.enter) { return true }
                parent.onSubmit()
                return true
            default:
                return false
            }
        }
    }
}
