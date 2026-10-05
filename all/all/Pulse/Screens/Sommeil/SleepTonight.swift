//
//  SleepTonight.swift
//  all (bridge-connect)
//
//  Choix de la nuit « À VENIR » de l'écran Sommeil (carte fixe « Ce soir »).
//  Une nuit est indexée par son jour de RÉVEIL ; la nuit à venir est celle dont
//  le réveil est le PROCHAIN réveil prévu : avant le réveil prévu d'aujourd'hui
//  (il est 1 h du matin) c'est la nuit de réveil AUJOURD'HUI, sinon celle de
//  DEMAIN. Fonction PURE (maintenant, calendrier, alarmes, reco en entrée) pour
//  rester testable sans horloge ni `WakeScheduleStore`.
//

import Foundation

enum SleepTonight {
    /// Réveil prévu (minutes depuis minuit local) du jour de semaine `weekday`
    /// (1 = dimanche … 7 = samedi) : l'alarme réglée ce jour-là ; sinon, avec une
    /// reco, le lever habituel du type de jour puis le lever habituel global
    /// (`SleepBedtimePlan.plannedWakeMinutes`). `nil` sans alarme ni reco exploitable.
    static func plannedWakeMinutes(
        weekday: Int, alarms: [Int: Int], reco: DashboardSleepRecommendation?
    ) -> Int? {
        if let alarm = alarms[weekday] { return alarm }
        guard let reco else { return nil }
        return SleepBedtimePlan.plannedWakeMinutes(reco: reco, weekday: weekday, alarmMinutes: nil)
    }

    /// Date (`YYYY-MM-DD`, jour de réveil) de la nuit à venir. Comparaison à
    /// l'HEURE MURALE locale (h/min de `now` vs minutes du réveil) et non à un
    /// instant : un changement d'heure dans la journée ne décale pas le choix.
    /// Réveil prévu inconnu (ni alarme ni reco) → demain, le cas courant en
    /// soirée ; l'appelant réévalue dès que la reco arrive (les lever habituels
    /// ne dépendent pas de la date demandée).
    static func upcomingNightDate(
        now: Date,
        calendar: Calendar,
        alarms: [Int: Int],
        reco: DashboardSleepRecommendation?
    ) -> String {
        let weekday = calendar.component(.weekday, from: now)
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (clock.hour ?? 0) * 60 + (clock.minute ?? 0)
        if let wake = plannedWakeMinutes(weekday: weekday, alarms: alarms, reco: reco),
           nowMinutes < wake {
            return SommeilDatePicking.key(forPickerDate: now, calendar: calendar)
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return SommeilDatePicking.key(forPickerDate: tomorrow, calendar: calendar)
    }
}
