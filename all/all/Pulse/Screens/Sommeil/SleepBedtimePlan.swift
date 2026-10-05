//
//  SleepBedtimePlan.swift
//  all (bridge-connect)
//
//  Heure de coucher conseillée POUR UNE DATE donnée (écran Sommeil, nuit
//  indexée par son jour de RÉVEIL). Fonction PURE (entrées : la reco, la date,
//  l'alarme éventuelle) pour rester testable sans `WakeScheduleStore`.
//

import Foundation

enum SleepBedtimePlan {
    struct Result: Equatable {
        /// « HH:mm ».
        let bedtime: String
        /// Réveil prévu pour la date, minutes depuis minuit.
        let wakeMinutes: Int
        /// Durée idéale retenue pour la nuit (h).
        let idealHours: Double
        /// `true` si `idealHours` vient du calcul contextuel de CETTE nuit
        /// (`nightIdealHours` de la reco), `false` si repli global.
        let isNightSpecific: Bool
    }

    /// Jour de semaine d'une clé `YYYY-MM-DD`, convention de `WakeScheduleStore`
    /// (1 = dimanche … 7 = samedi). Calendrier grégorien en UTC, comme
    /// `HealthViewModel.parseDate` : la clé est une date calendaire, pas un
    /// instant (composantes lues à la main, ce type n'étant pas `@MainActor`).
    static func weekday(ofDateKey key: String) -> Int? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let day = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return nil }
        return cal.component(.weekday, from: day)
    }

    /// Lundi → vendredi.
    static func isWorkday(weekday: Int) -> Bool { (2...6).contains(weekday) }

    /// Réveil prévu (minutes) du jour `date` : l'alarme réglée pour ce jour de
    /// semaine ; sinon le lever habituel du type de jour (`waketimeWorkday` /
    /// `waketimeFreeDay`) ; sinon le lever habituel global (`waketime`). Jamais
    /// le réveil réel de la nuit.
    static func plannedWakeMinutes(reco: DashboardSleepRecommendation, weekday: Int, alarmMinutes: Int?) -> Int? {
        if let alarmMinutes { return alarmMinutes }
        let byType = isWorkday(weekday: weekday) ? reco.waketimeWorkday : reco.waketimeFreeDay
        return parseHHMM(byType) ?? parseHHMM(reco.waketime)
    }

    /// Durée idéale de la nuit `date` : `nightIdealHours` si elle a été calculée
    /// pour CETTE date, sinon l'idéal global, sinon la cible.
    static func idealHours(reco: DashboardSleepRecommendation, date: String) -> (hours: Double, isNightSpecific: Bool)? {
        if reco.nightDate == date, let night = reco.nightIdealHours { return (night, true) }
        if let ideal = reco.idealHours ?? reco.targetHours { return (ideal, false) }
        return nil
    }

    /// `réveil prévu − (idéal × 60 + éveil moyen + latence)`, modulo 24 h.
    /// `nil` si la date est illisible ou si ni réveil prévu ni durée ne sont
    /// exploitables.
    static func plan(reco: DashboardSleepRecommendation, date: String, alarmMinutes: Int?) -> Result? {
        guard let weekday = weekday(ofDateKey: date),
              let wake = plannedWakeMinutes(reco: reco, weekday: weekday, alarmMinutes: alarmMinutes),
              let ideal = idealHours(reco: reco, date: date) else { return nil }
        let neededMin = Int((ideal.hours * 60).rounded()) + (reco.avgAwakeMin ?? 0) + (reco.latencyMin ?? 0)
        let bedMin = ((wake - neededMin) % 1_440 + 1_440) % 1_440
        return Result(
            bedtime: String(format: "%02d:%02d", bedMin / 60, bedMin % 60),
            wakeMinutes: wake, idealHours: ideal.hours, isNightSpecific: ideal.isNightSpecific)
    }

    /// « 8 h 10 » — durée en heures et minutes (arrondie à la minute).
    static func durationLabel(hours: Double) -> String {
        let total = Int((hours * 60).rounded())
        return "\(total / 60) h \(String(format: "%02d", total % 60))"
    }

    /// « HH:mm » → minutes depuis minuit, ou `nil` si absent/mal formé.
    private static func parseHHMM(_ value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}
