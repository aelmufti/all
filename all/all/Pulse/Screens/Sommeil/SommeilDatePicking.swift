//
//  SommeilDatePicking.swift
//  all (bridge-connect)
//
//  Passerelle entre les clés de date de l'écran Sommeil (`YYYY-MM-DD`,
//  manipulées en UTC par `HealthViewModel.parseDate`/`formatDate`) et le
//  `DatePicker` SwiftUI, qui travaille dans le calendrier LOCAL. On convertit
//  par composantes année/mois/jour (jamais par instant) : un décalage de
//  fuseau ne peut alors pas faire glisser la date d'un jour.
//

import Foundation

enum SommeilDatePicking {
    /// Clé → `Date` représentant ce jour calendaire dans `calendar` (midi local,
    /// loin des bascules de jour/DST). `nil` si la clé est illisible.
    static func pickerDate(forKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            calendar: calendar, year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// `Date` du `DatePicker` → clé `YYYY-MM-DD`, lue dans `calendar` (le même
    /// que celui du picker).
    static func key(forPickerDate date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
