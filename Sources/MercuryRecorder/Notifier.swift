import Foundation
import UserNotifications

/// Notificación "¿Grabar esta reunión?" con un botón Grabar.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private static let category = "REUNION_DETECTADA"
    private static let recordAction = "GRABAR"

    /// Se llama en la cola principal cuando el usuario elige Grabar (o toca la notificación).
    var onRecordRequested: (() -> Void)?

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordAction, title: "Grabar", options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.category, actions: [record], intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    /// Pide el permiso (la primera vez macOS muestra el diálogo) y devuelve si está concedido.
    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("mercury-recorder: permiso de notificaciones: \(error.localizedDescription)") }
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Estado actual del permiso, sin mostrar diálogos.
    func isAuthorized(_ completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func notifyMeetingStarted(in app: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                NSLog("mercury-recorder: reunión detectada en \(app), pero macOS no permite notificaciones")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "¿Grabar esta reunión?"
            content.body = "\(app) empezó a usar el micrófono. Pulsa Grabar para empezar."
            content.categoryIdentifier = Self.category
            content.sound = .default
            // Mismo identificador: si llegan varias seguidas, se reemplazan.
            let request = UNNotificationRequest(identifier: "reunion-detectada", content: content, trigger: nil)
            center.add(request)
        }
    }

    func clear() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["reunion-detectada"])
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.recordAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.onRecordRequested?() }
        }
        completionHandler()
    }
}
