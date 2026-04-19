import Foundation
import AppKit
import UserNotifications

/// Bridges Home Assistant's `persistent_notifications_updated` events into
/// native macOS notifications. Exposes a Dismiss action that routes back to
/// HA via persistent_notification.dismiss.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private let dismissActionID = "HOMEBAR_DISMISS"
    private let categoryID = "HOMEBAR_HA_NOTIFICATION"

    private var bootstrapped = false

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let dismiss = UNNotificationAction(
            identifier: dismissActionID,
            title: "Dismiss",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [dismiss],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                fputs("UN auth error: \(error.localizedDescription)\n", stderr)
            }
            if !granted {
                fputs("UN auth: not granted\n", stderr)
            }
        }
    }

    /// Shows a macOS banner for an HA persistent notification. `notificationID`
    /// is HA's id so the Dismiss action can route back to HA.
    func show(notificationID: String, title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Home Assistant" : title
        content.body = message
        content.categoryIdentifier = categoryID
        content.userInfo = ["notification_id": notificationID]
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "homebar-\(notificationID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { err in
            if let err {
                fputs("UN add failed: \(err.localizedDescription)\n", stderr)
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let id = info["notification_id"] as? String
        let actionID = response.actionIdentifier
        let dismissID = dismissActionID

        // Run the completion handler immediately; dispatch the actual work
        // to the main actor without crossing the Sendable boundary with the
        // non-Sendable UN completion handler.
        completionHandler()

        Task { @MainActor in
            switch actionID {
            case dismissID:
                if let id { await AppController.shared.store.dismissHANotification(id) }
            case UNNotificationDefaultActionIdentifier:
                AppController.shared.togglePanel()
            default:
                break
            }
        }
    }
}
