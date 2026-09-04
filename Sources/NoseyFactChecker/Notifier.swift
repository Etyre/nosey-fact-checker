import Foundation
import UserNotifications
import os

private let log = Logger(subsystem: "com.elityre.nosey", category: "notify")

/// Posts macOS notifications for findings and routes clicks back to the chat window.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var onOpen: ((UUID) -> Void)?
    private(set) var authorized = false

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            self.authorized = granted
            if let error { log.error("notification auth: \(error.localizedDescription)") }
        }
    }

    func post(_ finding: Finding, hotKeyLabel: String) {
        let content = UNMutableNotificationContent()
        content.title = "Nosey: possibly inaccurate"
        content.body = finding.summary
        content.subtitle = "“\(String(finding.claim.prefix(60)))\(finding.claim.count > 60 ? "…" : "")”"
        content.userInfo = ["findingID": finding.id.uuidString]
        content.threadIdentifier = "nosey"
        content.interruptionLevel = .active
        if AppSettings.shared.notifySound { content.sound = .default }
        let req = UNNotificationRequest(identifier: finding.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error { log.error("post failed: \(error.localizedDescription)") }
        }
    }

    /// Clears every Nosey notification from the screen and Notification Center.
    func dismissAll() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func postInfo(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // Show banners even while Nosey is the frontmost app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["findingID"] as? String, let id = UUID(uuidString: s) {
            DispatchQueue.main.async { self.onOpen?(id) }
        }
        completionHandler()
    }
}
