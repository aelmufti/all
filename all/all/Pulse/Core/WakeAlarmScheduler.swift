//
//  WakeAlarmScheduler.swift
//  all (bridge-connect)
//
//  Programme les rappels sonores du réveil réglé dans l'app
//  (`WakeScheduleStore`) via des notifications locales `UNUserNotification`.
//
//  À ne pas confondre avec une alarme de l'app Horloge iOS : sans
//  l'entitlement « alertes critiques » (que nous n'avons pas et ne
//  demandons pas ici), une notification locale respecte le mode silencieux/
//  Ne pas déranger et ne sonne qu'une fois — elle ne peut pas forcer le
//  volume ni relancer si elle est ignorée. C'est un rappel téléphone, pas un
//  réveil garanti.
//

import Foundation
import UserNotifications

final class WakeAlarmScheduler {
    static let shared = WakeAlarmScheduler()

    private static let idPrefix = "wake-"

    /// Best-effort — avale les erreurs (permission refusée, etc.) : l'appelant
    /// n'a rien d'autre à faire que retenter plus tard si `false`.
    func requestAuthorizationIfNeeded() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Reprogramme tous les rappels à partir du planning courant. Pas de
    /// diff incrémental : on purge toutes les notifs `wake-*` en attente puis
    /// on réinsère — le planning tient sur 7 jours max, le coût est nul.
    func reschedule(_ minutesByWeekday: [Int: Int]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let staleIds = requests.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: staleIds)

            for (weekday, minutes) in minutesByWeekday {
                let content = UNMutableNotificationContent()
                content.title = "Réveil"
                content.body = "Il est l'heure de te lever."
                content.sound = .default

                var dateComponents = DateComponents()
                dateComponents.hour = minutes / 60
                dateComponents.minute = minutes % 60
                dateComponents.weekday = weekday

                let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
                let request = UNNotificationRequest(
                    identifier: "\(Self.idPrefix)\(weekday)",
                    content: content,
                    trigger: trigger
                )
                center.add(request)
            }
        }
    }
}
