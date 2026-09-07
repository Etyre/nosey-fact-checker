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
            center.getNotificationSettings { st in
                FileLog.write("notifications: granted=\(granted) status=\(st.authorizationStatus.rawValue) alertStyle=\(st.alertStyle.rawValue) (0 none,1 banner,2 alert) notificationCenter=\(st.notificationCenterSetting.rawValue) alert=\(st.alertSetting.rawValue)")
            }
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
            if let error {
                log.error("post failed: \(error.localizedDescription)")
                FileLog.write("notification post FAILED: \(error.localizedDescription)")
            } else {
                FileLog.write("notification posted: \(finding.summary)")
            }
        }
    }

    /// Clears every Nosey notification from the screen and Notification Center.
    func dismissAll() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// Nosey's delivered (still on screen / in Notification Center) finding notifications, newest first.
    func deliveredFindings(_ completion: @escaping ([UUID]) -> Void) {
        UNUserNotificationCenter.current().getDeliveredNotifications { list in
            FileLog.write("delivered notifications: \(list.count)")
            let ids = list
                .sorted { $0.date > $1.date }
                .compactMap { n -> UUID? in
                    guard let s = n.request.content.userInfo["findingID"] as? String else { return nil }
                    return UUID(uuidString: s)
                }
            DispatchQueue.main.async { completion(ids) }
        }
    }

    /// Removes just the newest notification (the one on top of the stack).
    func dismissTop() {
        deliveredFindings { ids in
            guard let top = ids.first else { FileLog.write("dismiss: no notifications on screen"); return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [top.uuidString])
            FileLog.write("dismissed top notification (\(ids.count) were on screen)")
        }
    }

    func remove(_ id: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
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
