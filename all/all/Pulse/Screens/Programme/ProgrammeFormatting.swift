//
//  ProgrammeFormatting.swift
//  all (bridge-connect)
//
//  Portage des petits calculs de présentation de `ProgrammeComponent`
//  (Angular) qui ne dépendent que des modèles (`ProgrammeModels.swift`), pas
//  de l'état de l'écran — badge de progression, grille des jours de la
//  semaine affichée, libellés sommeil/nutrition… Tout est en fonctions
//  statiques préfixées `programme` pour éviter toute collision avec les
//  autres écrans (même motif que `nutritionValueText`/`nutritionRangeText`
//  dans `Screens/Nutrition/NutritionView.swift`).
//

import SwiftUI

// MARK: - Légende partagée (calendrier entraînement, frise sommeil)

/// Puce ronde + libellé — légende des couleurs, réutilisée par la carte
/// entraînement (calendrier de la semaine) et la carte sommeil (frise des
/// nuits).
struct ProgrammeLegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

// MARK: - Badge de progression (entête des cartes de domaine)

/// "semaine 2 / 4", "fin · 4 semaines" ou "jour 12" — équivalent `badge()`.
func programmeBadge(_ domain: ProgrammeDomainView) -> String {
    guard let active = domain.active else { return "" }
    if programmeFinished(domain) { return "fin · \(active.weeks) semaines" }
    if active.weeks > 0 { return "semaine \(active.week) / \(active.weeks)" }
    guard let days = ProgrammeDate.daysBetween(active.startedOn, ProgrammeDate.today()) else {
        return "en cours"
    }
    return "jour \(days + 1)"
}

/// Équivalent `finished()` : le programme a dépassé sa dernière semaine.
func programmeFinished(_ domain: ProgrammeDomainView) -> Bool {
    guard let active = domain.active, active.weeks > 0 else { return false }
    return active.week > active.weeks
}

/// "N actifs" / "aucun programme actif" — équivalent `activeNote()`.
func programmeActiveNote(_ domains: [ProgrammeDomainView]) -> String {
    let count = domains.filter { $0.active != nil }.count
    if count == 0 { return "aucun programme actif" }
    return "\(count) actif\(count > 1 ? "s" : "")"
}

/// "N programmes · en cours : X" — équivalent `libNote()`.
func programmeLibraryNote(_ domain: ProgrammeDomainView) -> String {
    let count = "\(domain.choices.count) programme\(domain.choices.count > 1 ? "s" : "")"
    guard let active = domain.active else { return "\(count) · aucun en cours" }
    return "\(count) · en cours : \(active.name)"
}

// MARK: - Entraînement — semaine affichée

/// Une case du calendrier de la semaine affichée — équivalent de l'objet
/// anonyme renvoyé par `weekDays()` (Angular).
struct ProgrammeDayCell: Identifiable {
    let date: String
    let letter: String
    /// `"done" | "planned" | "missed" | "empty"`.
    let state: String
    let today: Bool
    let title: String
    var id: String { date }
}

/// Équivalent `weekDays(domain, detail)` : les 7 jours de `shownWeek`,
/// pointés faite/prévue/en retard/vide à partir de `detail.sessions`.
func programmeWeekDays(domain: ProgrammeDomainView, detail: ProgrammeTrainingDetail, shownWeek: Int) -> [ProgrammeDayCell] {
    guard let startedOn = domain.active?.startedOn,
          let first = ProgrammeDate.addDays(startedOn, (shownWeek - 1) * 7)
    else { return [] }
    let today = ProgrammeDate.today()

    var doneOn: [String: String] = [:]
    var plannedOn: [String: ProgrammeSessionProgress] = [:]
    for session in detail.sessions {
        if session.done, let date = session.date, doneOn[date] == nil {
            doneOn[date] = session.session.name
        }
        if let planned = session.plannedOn, plannedOn[planned] == nil {
            plannedOn[planned] = session
        }
    }

    return (0..<7).compactMap { offset -> ProgrammeDayCell? in
        guard let date = ProgrammeDate.addDays(first, offset) else { return nil }
        let weekday = ProgrammeDate.weekday(of: date) ?? 0
        let doneName = doneOn[date]
        let planned = plannedOn[date]

        let state: String
        if doneName != nil {
            state = "done"
        } else if planned == nil || planned!.done {
            state = "empty"
        } else if planned!.status == .missed {
            state = "missed"
        } else {
            state = "planned"
        }

        let title: String
        if let doneName {
            title = "\(doneName) · faite"
        } else if let planned, planned.done {
            title = "\(planned.session.name) · faite le \(ProgrammeDate.shortLabel(planned.date))"
        } else if let planned {
            title = "\(planned.session.name) · \(planned.status == .missed ? "en retard" : "prévue")"
        } else if date == today {
            title = "aujourd’hui · rien de prévu"
        } else {
            title = "rien de prévu"
        }

        return ProgrammeDayCell(
            date: date,
            letter: ProgrammeDate.weekdayLetters[weekday],
            state: state,
            today: date == today,
            title: title
        )
    }
}

/// Une pastille de la frise multi-semaines — équivalent `weekSegments()`.
struct ProgrammeWeekSegment: Identifiable {
    let index: Int
    /// `"done" | "part" | "todo"`.
    let state: String
    let current: Bool
    var id: Int { index }
}

func programmeWeekSegments(weeks: Int, sessions: [ProgrammeSessionProgress], shownWeek: Int) -> [ProgrammeWeekSegment] {
    guard weeks > 0 else { return [] }
    return (1...weeks).map { index in
        let weekSessions = sessions.filter { $0.week == index }
        let done = weekSessions.filter(\.done).count
        let state: String
        if !weekSessions.isEmpty, done == weekSessions.count {
            state = "done"
        } else if done > 0 {
            state = "part"
        } else {
            state = "todo"
        }
        return ProgrammeWeekSegment(index: index, state: state, current: index == shownWeek)
    }
}

/// Ligne "Prochaine" sous la carte entraînement — équivalent `nextLabel()`.
func programmeNextLabel(detail: ProgrammeTrainingDetail, shownWeek: Int) -> String {
    let weekSessions = detail.sessions.filter { $0.week == shownWeek }
    let pending = weekSessions.first { !$0.done }
    let latestDone = detail.sessions.compactMap { $0.done ? $0.date : nil }.max()

    let gap: String
    if let latestDone, let since = ProgrammeDate.daysBetween(latestDone, ProgrammeDate.today()) {
        gap = since <= 0 ? "la dernière est d’aujourd’hui" : "\(since) jour\(since > 1 ? "s" : "") depuis la dernière"
    } else {
        gap = "aucune séance pointée"
    }

    guard let pending else { return "semaine complète · \(gap)" }
    return "\(pending.session.name) · \(gap)"
}

/// Sous-titre d'une ligne de séance — équivalent `sessionMeta()`.
func programmeSessionMeta(_ session: ProgrammeSessionProgress) -> String {
    if session.done {
        return "\(session.manual ? "pointée" : "appariée") le \(ProgrammeDate.shortLabel(session.date))"
    }
    let count = session.session.items.count
    let exercises = "\(count) exercice\(count > 1 ? "s" : "")"
    guard let plannedOn = session.plannedOn else { return exercises }
    if session.status == .today { return "aujourd’hui · \(exercises)" }
    if session.status == .missed { return "en retard depuis le \(ProgrammeDate.shortLabel(plannedOn))" }
    return "\(ProgrammeDate.shortLabel(plannedOn)) · \(exercises)"
}

// MARK: - Alimentation

/// "3 / 5" ou "— / 5" — équivalent `nutritionSummary()`.
func programmeNutritionSummary(_ day: ProgrammeDayProgress) -> String {
    day.logged ? "\(day.hits) / \(day.total)" : "— / \(day.total)"
}

/// "g" / "kcal" — équivalent de la table `UNIT` (Angular).
func programmeMacroUnit(_ metric: String) -> String {
    switch metric {
    case "kcal": return "kcal"
    case "protein", "carbs", "fat", "fiber": return "g"
    default: return ""
    }
}

func programmeWeekdayLetter(_ date: String) -> String {
    guard let weekday = ProgrammeDate.weekday(of: date) else { return "" }
    return ProgrammeDate.weekdayLetters[weekday]
}

// MARK: - Sommeil

/// "1 h 05" (≥ 1 h) ou "45 min" — équivalent `duration()` (Angular).
func programmeSleepDuration(_ minutes: Double) -> String {
    let total = Int(abs(minutes).rounded())
    let hours = total / 60
    let rest = total % 60
    if hours == 0 { return "\(rest) min" }
    return rest > 0 ? "\(hours) h \(String(format: "%02d", rest))" : "\(hours) h"
}

/// Valeur affichée d'un critère de sommeil — équivalent `metricValue()`.
func programmeSleepValueText(_ metric: ProgrammeSleepMetric) -> String {
    guard let value = metric.value else { return "—" }
    switch metric.unit {
    case .index:
        return "\(Int(value.rounded()))"
    case .duration:
        return programmeSleepDuration(value)
    case .min:
        let rounded = Int(value.rounded())
        let signed = metric.scale.min < 0 && rounded > 0
        return "\(signed ? "+" : "")\(rounded) min"
    }
}

/// Équivalent `metricState()`.
func programmeSleepStateText(_ metric: ProgrammeSleepMetric) -> String {
    if metric.informative { return metric.band?.risk ?? "indice descriptif" }
    guard metric.value != nil else { return "pas mesurable" }
    switch metric.status {
    case .hit: return "dans la cible"
    case .under: return "sous la cible"
    case .over: return "au-dessus de la cible"
    case .unknown: return "sans cible"
    }
}

private func programmeSleepBound(_ metric: ProgrammeSleepMetric, _ value: Double) -> String {
    switch metric.unit {
    case .duration: return programmeSleepDuration(value)
    case .index: return "\(Int(value.rounded()))"
    case .min: return "\(Int(value.rounded())) min"
    }
}

/// Équivalent `metricTarget()`.
func programmeSleepTargetText(_ metric: ProgrammeSleepMetric) -> String {
    if metric.informative {
        return "échelle \(Int(metric.scale.min)) à \(Int(metric.scale.max))"
    }
    let min = metric.range.min
    let max = metric.range.max
    if min == nil && max == nil { return metric.detail }
    if let min, let max { return "cible \(programmeSleepBound(metric, min)) à \(programmeSleepBound(metric, max))" }
    if let min { return "au moins \(programmeSleepBound(metric, min))" }
    return "au plus \(programmeSleepBound(metric, max!))"
}

/// Équivalent `markerColor()`. Le socle natif n'a pas d'équivalent à
/// `--m-stress` (SCSS) : "sous la cible" est représenté avec `.pulseAccent`
/// plutôt qu'une quatrième couleur sémantique dédiée.
func programmeSleepMarkerColor(_ metric: ProgrammeSleepMetric) -> Color {
    if metric.informative || metric.value == nil { return .pulseTextSecondary }
    switch metric.status {
    case .hit: return .pulseSuccess
    case .under: return .pulseAccent
    case .over: return .pulseDanger
    case .unknown: return .pulseTextSecondary
    }
}

/// Équivalent `windowLabel()`.
func programmeSleepWindowLabel(_ detail: ProgrammeSleepDetail) -> String {
    guard detail.nights > 0 else { return "aucune nuit importée" }
    let nights = "\(detail.nights) nuit\(detail.nights > 1 ? "s" : "")"
    return "\(nights) jusqu’au \(ProgrammeDate.shortLabel(detail.to))"
}

/// Équivalent `stripWarning()`.
func programmeSleepStripWarning(_ detail: ProgrammeSleepDetail) -> String? {
    if detail.nights == 0 {
        return "Aucune nuit dans la base : la montre ne garde ses fichiers de sommeil que quelques jours, il faut synchroniser régulièrement."
    }
    if detail.staleDays > 3 {
        return "La dernière nuit connue remonte à \(detail.staleDays) jours : la lecture porte sur cette période, pas sur la semaine en cours."
    }
    if detail.spanDays > detail.nights + 3 {
        return "Les \(detail.nights) nuits s’étalent sur \(detail.spanDays) jours : les trous ne sont pas comptés comme des nuits blanches, ils sont simplement ignorés."
    }
    return nil
}

/// Équivalent `workDaysLabel()`.
func programmeWorkDaysLabel(_ domain: ProgrammeDomainView) -> String {
    let days = domain.active?.days ?? []
    if days.isEmpty { return "Jours travaillés : lundi au vendredi, par défaut." }
    let letters = days
        .filter { $0 >= 0 && $0 < ProgrammeDate.weekdayLetters.count }
        .map { ProgrammeDate.weekdayLetters[$0] }
        .joined(separator: " ")
    return "Jours avec réveil imposé : \(letters). Les autres nuits servent de référence « jour libre »."
}

// MARK: - Envoi à la montre

/// Équivalent `pushSummary()`.
func programmePushSummary(filesSent: Int?) -> String {
    guard let filesSent else { return "jamais envoyées" }
    return "\(filesSent) séance\(filesSent > 1 ? "s" : "") distincte\(filesSent > 1 ? "s" : "")"
}

/// Équivalent `pushHint()`.
func programmePushHint(status: ProgrammePushStatus?) -> String {
    switch status?.state {
    case "running":
        return "L’hôte pousse les fichiers ; valide l’installation sur le téléphone."
    case "ok":
        let dateKey = status?.at.map { String($0.prefix(10)) }
        let suffix = dateKey.map { " le " + ProgrammeDate.shortLabel($0) } ?? ""
        return "Passées à Gadgetbridge\(suffix). Les séances arrivent sans date : c’est ce calendrier qui fait foi."
    case "error":
        return "L’hôte n’a pas pu joindre le téléphone. Vérifie le câble adb."
    default:
        return "Par Bluetooth via Gadgetbridge. Une seule fois par programme : les semaines répètent les mêmes séances."
    }
}
