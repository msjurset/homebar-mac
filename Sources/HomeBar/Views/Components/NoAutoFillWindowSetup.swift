import AppKit
import SwiftUI
import OSLog

private let log = Logger(subsystem: "com.msjurseth.homebar", category: "phantom-diagnostics")

/// Once-and-for-all suppression of the empty rounded-rectangle popup
/// that appears the first time any field-editor or menu surface
/// initializes in a window on macOS 15. The popup is whatever
/// predictive-text / Apple Intelligence subsystem AppKit warms up when
/// it first creates the window's shared field editor — by providing
/// our own pre-configured editor *before* AppKit gets a chance to
/// instantiate the default one, the warm-up has nothing to render.
///
/// The interception happens via NSWindowDelegate's
/// `windowWillReturnFieldEditor(_:to:)` — when that returns non-nil,
/// AppKit uses it in place of its own default editor. SwiftUI assigns
/// its own internal delegate to the windows it creates, so we wrap
/// that delegate via a forwarding NSObject (`responds(to:)` +
/// `forwardingTarget(for:)`) and only add this single method on top.
/// Everything SwiftUI's delegate did before still happens; we just
/// inject one extra hook.

/// The pre-configured field editor returned by every wrapped window.
/// One per app — NSText/NSTextView field editors are designed to be
/// shared; AppKit checks that the returned editor isn't already in
/// use elsewhere and falls back to its own pool when it is, so a
/// shared instance plus the same disabled flags is the canonical
/// shape.
@MainActor
private let sharedNoAutoFillFieldEditor: NSTextView = {
    let editor = NSTextView()
    editor.isFieldEditor = true
    editor.disableAutoFeatures()
    return editor
}()

/// Forwarding NSObject that wraps an existing NSWindowDelegate and
/// adds `windowWillReturnFieldEditor`. All other delegate calls are
/// forwarded transparently so SwiftUI's window machinery (drag, key
/// equivalents, restoration, etc.) keeps working.
final class FieldEditorInterceptor: NSObject, NSWindowDelegate {
    weak var wrapped: NSObject?

    init(wrapping wrapped: NSObject?) {
        self.wrapped = wrapped
        super.init()
    }

    /// Tell AppKit we respond to a selector if EITHER we implement it
    /// directly, or the wrapped delegate does. Without this AppKit
    /// won't even attempt forwarding for selectors we don't define.
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return wrapped?.responds(to: aSelector) ?? false
    }

    /// Route any selector this interceptor doesn't define to the
    /// wrapped delegate. Selectors we DO define (notably
    /// windowWillReturnFieldEditor) get handled here.
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard let wrapped, wrapped.responds(to: aSelector) else { return nil }
        return wrapped
    }

    @MainActor
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        // Re-apply flags every time AppKit asks for the editor — some of
        // these are reset between editor uses, and Sequoia in particular
        // re-enables `inlinePredictionType` on reuse.
        sharedNoAutoFillFieldEditor.disableAutoFeatures()
        return sharedNoAutoFillFieldEditor
    }
}

/// Strong references to installed interceptors, keyed by window
/// identity. Without this the wrapped objects would dealloc as soon as
/// `installFieldEditorInterceptor` returns since `NSWindow.delegate`
/// is a weak reference.
@MainActor
private var installedInterceptors: [ObjectIdentifier: FieldEditorInterceptor] = [:]

/// Install (or replace) the interceptor on a window. Idempotent — safe
/// to call repeatedly when SwiftUI re-assigns the delegate.
@MainActor
func installFieldEditorInterceptor(on window: NSWindow) {
    let key = ObjectIdentifier(window)
    let currentDelegate = window.delegate as? NSObject
    if let existing = installedInterceptors[key],
       window.delegate === existing {
        return
    }
    let interceptor = FieldEditorInterceptor(wrapping: currentDelegate)
    installedInterceptors[key] = interceptor
    window.delegate = interceptor
}

/// Helper called by `AppDelegate` to wire up window-level field-editor
/// interception. Sweeps existing windows and registers observers so any
/// future window (sheets, popovers promoted to windows, etc.) is also
/// wrapped at order-in time.
@MainActor
func installFieldEditorInterceptorsForAllWindows() -> [NSObjectProtocol] {
    for window in NSApp.windows {
        installFieldEditorInterceptor(on: window)
    }

    let didKey = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: nil,
        queue: .main
    ) { notification in
        guard let window = notification.object as? NSWindow else { return }
        MainActor.assumeIsolated {
            installFieldEditorInterceptor(on: window)
        }
    }

    let didUpdate = NotificationCenter.default.addObserver(
        forName: NSWindow.didUpdateNotification,
        object: nil,
        queue: .main
    ) { notification in
        guard let window = notification.object as? NSWindow else { return }
        MainActor.assumeIsolated {
            installFieldEditorInterceptor(on: window)
        }
    }

    // Belt-and-suspenders: before any user interaction reaches a
    // text field, re-sweep every window. SwiftUI sometimes creates
    // panels (sheets, popovers, QLPreviewPanel) whose lifecycle
    // notifications don't reliably fire `didBecomeKey` /
    // `didUpdate` before the field-editor warm-up that raises the
    // phantom popup. Sweeping on `.leftMouseDown` and `.keyDown` is
    // cheap (idempotent installs) and guarantees coverage.
    _ = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .keyDown]
    ) { event in
        MainActor.assumeIsolated {
            for window in NSApp.windows {
                installFieldEditorInterceptor(on: window)
            }
        }
        return event
    }

    return [didKey, didUpdate]
}
