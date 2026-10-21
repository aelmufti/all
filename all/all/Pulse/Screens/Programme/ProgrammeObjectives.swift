//
//  ProgrammeObjectives.swift
//  all (bridge-connect)
//
//  Choix de programme par objectif (sèche, maintien, masse sèche) : chaque
//  objectif est une paire entraînement + alimentation du catalogue Pulse,
//  activée d'un geste. Table statique côté iOS ; un id absent de
//  `domain.choices` (serveur Pulse pas encore à jour) rend l'objectif
//  indisponible. Plus les jours proposés d'après les habitudes (fonction pure).
//

import Foundation

// MARK: - Objectifs

struct ProgrammeObjective: Identifiable, Hashable {
    let id: String
    let name: String
    let tagline: String
    let trainingId: String
    let nutritionId: String

    static let all: [ProgrammeObjective] = [
        ProgrammeObjective(
            id: "seche", name: "Sèche", tagline: "Perdre du gras",
            trainingId: "seche-escalade-nutrients-2021", nutritionId: "seche-nutrients-2021"),
        ProgrammeObjective(
            id: "maintien", name: "Maintien", tagline: "Garder le niveau",
            trainingId: "maintien-escalade-muscu-jscr-2021", nutritionId: "maintien-nutrition-acsm-2016"),
        ProgrammeObjective(
            id: "masse-seche", name: "Masse sèche", tagline: "Du muscle sans gras",
            trainingId: "masse-seche-muscu-escalade-schoenfeld", nutritionId: "masse-seche-nutrition-iraki-2019"),
    ]
}

/// Les deux choix du catalogue d'un objectif, quand les deux existent.
struct ProgrammeObjectiveChoices {
    let training: ProgrammeChoice
    let nutrition: ProgrammeChoice
}

/// `nil` = objectif indisponible (un des deux ids manque dans les domaines).
func programmeObjectiveChoices(
    _ objective: ProgrammeObjective, domains: [ProgrammeDomainView]
) -> ProgrammeObjectiveChoices? {
    let training = domains.first { $0.kind == .training }?.choices.first { $0.id == objective.trainingId }
    let nutrition = domains.first { $0.kind == .nutrition }?.choices.first { $0.id == objective.nutritionId }
    guard let training, let nutrition else { return nil }
    return ProgrammeObjectiveChoices(training: training, nutrition: nutrition)
}

/// Objectif dont la paire est exactement la paire actuellement active.
func programmeActiveObjective(domains: [ProgrammeDomainView]) -> ProgrammeObjective? {
    let training = domains.first { $0.kind == .training }?.active?.programmeId
    let nutrition = domains.first { $0.kind == .nutrition }?.active?.programmeId
    guard let training, let nutrition else { return nil }
    return ProgrammeObjective.all.first { $0.trainingId == training && $0.nutritionId == nutrition }
}

// MARK: - Jours d'après les habitudes

/// Ordre de remplissage par défaut (lun, mer, ven, mar, jeu, sam, dim) —
/// équivalent `DAY_ORDER` (Angular). Convention 0 = dimanche.
let programmeDefaultDayOrder = [1, 3, 5, 2, 4, 6, 0]
/// Ordre d'affichage du sélecteur (lundi en premier).
let programmeDayPickerOrder = [1, 2, 3, 4, 5, 6, 0]

struct ProgrammeDaySuggestion: Equatable {
    /// Jours proposés (`perWeek` jours, convention 0 = dimanche), triés dans
    /// l'ordre du sélecteur.
    let days: [Int]
    /// `true` si au moins un jour vient des habitudes (≥ 2 semaines actives).
    let fromHabits: Bool

    /// « L M V S ».
    var label: String {
        days.map { ProgrammeDate.weekdayLetters[$0] }.joined(separator: " ")
    }
}

/// Jours proposés d'après les activités des `weeks` dernières semaines
/// (marches exclues) : pour chaque jour de semaine, nombre de semaines avec au
/// moins une activité ; les `perWeek` plus fréquents (≥ 2 semaines), départage
/// et complément par `programmeDefaultDayOrder`.
func programmeSuggestDays(
    activities: [Activity],
    perWeek: Int,
    now: Date = Date(),
    weeks: Int = 8,
    calendar: Calendar = .current
) -> ProgrammeDaySuggestion {
    let count = max(perWeek, 0)
    let windowStart = calendar.date(
        byAdding: .day, value: -7 * weeks, to: calendar.startOfDay(for: now)) ?? .distantPast
    // (jour de semaine, début de semaine) distincts.
    var seen = Set<[Int]>()
    var counts: [Int: Int] = [:]
    for activity in activities where activity.sport != "walking" {
        guard let date = ActivityDateFormatting.date(from: activity.startTime),
              date >= windowStart, date <= now,
              let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start
        else { continue }
        let weekday = calendar.component(.weekday, from: date) - 1
        let key = [weekday, Int(week.timeIntervalSince1970)]
        if seen.insert(key).inserted { counts[weekday, default: 0] += 1 }
    }
    let rank = Dictionary(uniqueKeysWithValues: programmeDefaultDayOrder.enumerated().map { ($1, $0) })
    let habitual = counts.filter { $0.value >= 2 }.keys.sorted {
        let a = counts[$0] ?? 0, b = counts[$1] ?? 0
        return a != b ? a > b : (rank[$0] ?? 0) < (rank[$1] ?? 0)
    }
    var picked = Array(habitual.prefix(count))
    let fromHabits = !picked.isEmpty
    for day in programmeDefaultDayOrder where picked.count < count && !picked.contains(day) {
        picked.append(day)
    }
    let ordered = programmeDayPickerOrder.filter { picked.contains($0) }
    return ProgrammeDaySuggestion(days: ordered, fromHabits: fromHabits)
}
