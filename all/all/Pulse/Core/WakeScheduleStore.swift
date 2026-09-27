//
//  WakeScheduleStore.swift
//  all (bridge-connect)
//
//  Réveil manuel réglé DANS l'app — iOS n'expose pas les alarmes de
//  l'app Horloge système à une app tierce, on ne cherche pas à les lire.
//  L'heure vient uniquement de la saisie utilisateur ici, et sert à deux
//  choses : programmer un rappel sonore (`WakeAlarmScheduler`) et recalculer
//  localement l'heure de coucher conseillée à partir du prochain réveil à
//  venir (la reco serveur, `/api/stats/sleep-recommendation`, se base sinon
//  sur l'heure de lever HABITUELLE calculée sur l'historique).
//
//  Miroir de style `ThemeStore.swift` : `@MainActor @Observable`, persisté
//  dans `UserDefaults`.
//

import Foundation
import Observation

/// Résultat du recalcul local de coucher à partir du prochain réveil réglé
/// dans l'app — cf. `WakeScheduleStore.adaptedBedtime(reco:calendar:now:)`.
struct AdaptedBedtime: Equatable {
    /// Coucher à viser CE SOIR (palier appliqué si besoin).
    let bedtime: String
    /// Cible finale (sans palier) — à afficher quand `stepped` est vrai.
    let targetBedtime: String
    let stepped: Bool
    let wakeMinutes: Int
    let weekday: Int
}

@MainActor
@Observable
final class WakeScheduleStore {
    static let shared = WakeScheduleStore()

    /// Calendar weekday (1 = dimanche … 7 = samedi) → minutes depuis minuit
    /// local (0…1439). Jour absent de la table = pas de réveil ce jour-là.
    private(set) var minutesByWeekday: [Int: Int]

    private let defaults: UserDefaults
    private static let key = "pulse-wake-schedule"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            var restored: [Int: Int] = [:]
            for (rawWeekday, minutes) in decoded {
                if let weekday = Int(rawWeekday) { restored[weekday] = minutes }
            }
            minutesByWeekday = restored
        } else {
            minutesByWeekday = [:]
        }
    }

    func minutes(for weekday: Int) -> Int? {
        minutesByWeekday[weekday]
    }

    func set(minutes: Int, weekdays: Set<Int>) {
        for weekday in weekdays { minutesByWeekday[weekday] = minutes }
        persist()
        WakeAlarmScheduler.shared.reschedule(minutesByWeekday)
    }

    func clear(weekdays: Set<Int>) {
        for weekday in weekdays { minutesByWeekday.removeValue(forKey: weekday) }
        persist()
        WakeAlarmScheduler.shared.reschedule(minutesByWeekday)
    }

    func clearAll() {
        minutesByWeekday.removeAll()
        persist()
        WakeAlarmScheduler.shared.reschedule(minutesByWeekday)
    }

    private func persist() {
        // Clés JSON en `String` (Int n'est pas codable comme clé de dico par
        // `JSONEncoder`) — reconverties en `Int` à la lecture.
        let encodable = Dictionary(uniqueKeysWithValues: minutesByWeekday.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// "HH:mm" zero-paddé — même format que les heures reçues du serveur
    /// (`waketime` / `recommendedBedtime` de `DashboardSleepRecommendation`).
    /// `nonisolated` : pur formatage, appelé aussi depuis du code hors
    /// `@MainActor` (ex. `wakeScheduleSummary` dans `SommeilView.swift`).
    nonisolated static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// Recalcule localement l'heure de coucher conseillée à partir du **prochain
    /// réveil à venir** réglé dans l'app — exactement la sémantique d'un réveil :
    /// on cherche la première occurrence future d'un réveil programmé, à partir
    /// de maintenant. À 1 h du lundi, le réveil de lundi matin (07:00) est encore
    /// à venir → c'est LUI (la nuit dim.→lun. en cours), pas mardi. À 10 h, une
    /// fois lundi passé, ce sera le prochain jour réglé (mardi, etc.). On garde
    /// volontairement cette sémantique « par alarme » (pas un ancrage stable) :
    /// c'est un réveil qu'on adapte, pas une moyenne.
    ///
    /// On applique ensuite la formule de la reco serveur (bedtime = lever −
    /// (durée cible + éveil habituel + délai d'endormissement)), mais avec
    /// l'heure de lever fixée par l'utilisateur au lieu de la moyenne serveur.
    /// Comme côté serveur, on ne vise la cible finale que si elle n'avance pas
    /// de plus de `stepMin` sur l'habitude (`currentBedtime`) — au-delà, palier
    /// de `stepMin` ce soir — mais seulement si le serveur envoie `stepMin`
    /// (contrat v2) ; un serveur v1 (pas de `stepMin`) ne déclenche jamais de
    /// palier ici, pour rester compatible. `nil` si aucun réveil n'est
    /// programmé dans les 7 prochains jours, ou si le serveur n'a pas encore de
    /// durée cible exploitable (nuits insuffisantes).
    func adaptedBedtime(
        reco: DashboardSleepRecommendation,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> AdaptedBedtime? {
        guard let targetHours = reco.targetHours else { return nil }
        guard let (wakeMinutes, weekday) = nextWake(calendar: calendar, now: now) else { return nil }

        let neededMin = Int((targetHours * 60).rounded()) + (reco.avgAwakeMin ?? 0) + (reco.latencyMin ?? 0)
        // Repli mod 1440 pour gérer le passage minuit (coucher la veille).
        let targetBedMin = ((wakeMinutes - neededMin) % 1_440 + 1_440) % 1_440

        var stepped = false
        var bedMin = targetBedMin
        if let stepMin = reco.stepMin,
           let habitMin = Self.parseHHMM(reco.currentBedtime) {
            let shift = Self.signedDiffMinutes(targetBedMin, habitMin)
            if shift < -stepMin {
                stepped = true
                bedMin = ((habitMin - stepMin) % 1_440 + 1_440) % 1_440
            }
        }

        return AdaptedBedtime(
            bedtime: Self.hhmm(bedMin),
            targetBedtime: Self.hhmm(targetBedMin),
            stepped: stepped,
            wakeMinutes: wakeMinutes,
            weekday: weekday
        )
    }

    /// "HH:mm" → minutes depuis minuit, ou `nil` si absent/mal formé.
    private static func parseHHMM(_ value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    /// Décalage signé le plus court entre deux horaires (minutes depuis
    /// minuit), négatif = `a` avant `b` — même formule que côté serveur.
    private static func signedDiffMinutes(_ a: Int, _ b: Int) -> Int {
        (((a - b) % 1_440 + 1_440 + 720) % 1_440) - 720
    }

    /// Prochaine occurrence future d'un réveil programmé (minutes + weekday) —
    /// balaie aujourd'hui puis les 6 jours suivants et retient le premier
    /// instant `startOfDay + réveil` strictement après `now`.
    private func nextWake(calendar: Calendar, now: Date) -> (minutes: Int, weekday: Int)? {
        for offset in 0...6 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard let wakeMinutes = minutes(for: weekday) else { continue }
            let wakeDate = calendar.startOfDay(for: day)
                .addingTimeInterval(TimeInterval(wakeMinutes * 60))
            if wakeDate > now { return (wakeMinutes, weekday) }
        }
        return nil
    }
}
