//
//  DashboardFormatting.swift
//  all (bridge-connect)
//
//  Petites fonctions de présentation propres à l'écran Dashboard — portage des
//  helpers `hm()`, `signedHm()`, `signedHours()`, `paceOf()`, `sportColor()`/
//  `sportName()` (`custom-connect/web/src/app/core/sports.ts`) et du parsing
//  des dates calendaires `YYYY-MM-DD` en `Date` pour Swift Charts. Tout est
//  préfixé `dashboard`/`Dashboard` (module partagé avec d'autres écrans).
//

import Foundation
import SwiftUI

// MARK: - Dates calendaires (jamais d'epoch sur ces endpoints)

private let dashboardDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

/// Parse une chaîne calendaire `YYYY-MM-DD` (format Pulse pour les champs
/// `date` de ces endpoints) en `Date` à minuit UTC. `nil` si non parsable —
/// l'appelant filtre plutôt que d'échouer (cohérent avec le reste du socle :
/// jamais planté sur une donnée serveur inattendue).
func dashboardDate(from calendarDay: String) -> Date? {
    dashboardDayFormatter.date(from: calendarDay)
}

private let dashboardAxisFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d/MM"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "fr_FR")
    return formatter
}()

/// `dateFormat` côté Angular (`d/MM`), pour les axes de graphe.
func dashboardShortDate(_ date: Date) -> String {
    dashboardAxisFormatter.string(from: date)
}

private let dashboardDayMonthFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE d MMM"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "fr_FR")
    return formatter
}()

/// Format long façon `date: 'EEE d MMM'` (détail des nuits).
func dashboardLongDate(_ calendarDay: String) -> String {
    guard let date = dashboardDate(from: calendarDay) else { return calendarDay }
    return dashboardDayMonthFormatter.string(from: date)
}

// MARK: - Durées

/// `hm()` côté Angular : minutes rondes en `"1h05"`.
func dashboardFormatHM(_ seconds: Int) -> String {
    let totalMinutes = Int((Double(abs(seconds)) / 60).rounded())
    return "\(totalMinutes / 60)h\(String(format: "%02d", totalMinutes % 60))"
}

/// `signedHm()` côté Angular.
func dashboardFormatSignedHM(_ seconds: Int) -> String {
    "\(seconds < 0 ? "−" : "+")\(dashboardFormatHM(seconds))"
}

/// `signedHours()` côté Angular.
func dashboardFormatSignedHours(_ seconds: Int) -> String {
    let hours = Double(abs(seconds)) / 3600
    return "\(seconds < 0 ? "−" : "")\(String(format: "%.1f", hours)) h"
}

/// `paceOf()`/`formatPaceSecPerKm()` côté Angular.
func dashboardFormatPace(secPerKm: Double) -> String {
    guard secPerKm.isFinite, secPerKm > 0 else { return "—" }
    let minutes = Int(secPerKm / 60)
    let secondsRemainder = Int((secPerKm.truncatingRemainder(dividingBy: 60)).rounded())
    return "\(minutes)'\(String(format: "%02d", secondsRemainder))\"/km"
}

// MARK: - Sports (`sports.ts`)

/// Palette qualitative propre à l'écran (les variables SCSS `--m-steps`,
/// `--m-sleep`, `--m-cal`, `--m-spo2`, `--m-hr`, `--m-stress` n'ont pas
/// d'équivalent dans `DesignSystem.swift`, qui n'expose que la palette
/// sémantique accent/success/danger) — couleurs système adaptatives
/// light/dark, pas besoin de dupliquer l'init `Color(light:dark:)` privée de
/// `DesignSystem.swift`.
enum DashboardMetricColor {
    static let steps = Color.green
    static let sleep = Color.indigo
    static let calories = Color.orange
    static let spo2 = Color.teal
    static let heartRate = Color.red
    static let stress = Color.yellow
}

private let dashboardSportLabels: [String: String] = [
    "running": "Course à pied",
    "training": "Entraînement",
    "walking": "Marche",
    "rockClimbing": "Escalade",
    "floorClimbing": "Montée d'étages",
    "swimming": "Natation",
    "cycling": "Vélo",
    "rowing": "Aviron",
    "racket": "Sport de raquette",
    "generic": "Autre",
]

func dashboardSportName(_ sport: String) -> String {
    dashboardSportLabels[sport] ?? sport
}

func dashboardSportColor(_ sport: String) -> Color {
    switch sport {
    case "running", "walking": return DashboardMetricColor.steps
    case "training": return DashboardMetricColor.sleep
    case "rockClimbing", "floorClimbing": return DashboardMetricColor.calories
    case "swimming", "rowing": return DashboardMetricColor.spo2
    case "cycling": return DashboardMetricColor.heartRate
    case "racket": return DashboardMetricColor.stress
    default: return .pulseTextSecondary
    }
}

/// Palette des zones d'effort Z1…Z5 — mêmes couleurs que `zonesDesc()` côté
/// Angular (`['--accent', '--m-steps', '--m-cal', '--m-hr', '--danger']`).
func dashboardZoneColor(_ zone: Int) -> Color {
    let colors: [Color] = [.pulseAccent, DashboardMetricColor.steps, DashboardMetricColor.calories, DashboardMetricColor.heartRate, .pulseDanger]
    return colors[min(max(zone - 1, 0), colors.count - 1)]
}

/// `macroColor()` côté Angular.
func dashboardMacroColor(_ key: String) -> Color {
    switch key {
    case "protein": return .pulseAccent
    case "carbs": return DashboardMetricColor.calories
    default: return DashboardMetricColor.stress
    }
}

/// `streakLabel()` côté Angular.
func dashboardStreakLabel(current: Int) -> String {
    if current >= 8 { return "solide" }
    if current >= 4 { return "régulier" }
    if current >= 1 { return "à confirmer" }
    return "coupé"
}

/// `debtLevel()` côté Angular.
func dashboardDebtLevel(debtHours: Double) -> String {
    if debtHours <= 0 { return "à jour" }
    if debtHours < 4 { return "faible" }
    if debtHours < 9 { return "modérée" }
    return "élevée"
}

/// `regularityColor()` côté Angular.
func dashboardRegularityColor(score: Int) -> Color {
    if score >= 70 { return .pulseSuccess }
    if score >= 45 { return DashboardMetricColor.stress }
    return .pulseDanger
}
