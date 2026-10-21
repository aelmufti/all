//
//  ProgrammeBilan.swift
//  all (bridge-connect)
//
//  Bilan d'un programme d'entraînement terminé (écran « Bravo ») : calculs
//  purs, sans vue. Le temps total d'entraînement n'est pas calculé : le détail
//  programme ne porte pas la durée des séances cochées (seules les activités
//  hors programme ont `durationS`).
//

import Foundation

struct ProgrammeBilanWeek: Identifiable, Equatable {
    let week: Int
    let done: Int
    let planned: Int
    var id: Int { week }
    /// Semaine avec au moins une séance prévue, toutes faites.
    var complete: Bool { planned > 0 && done == planned }
}

struct ProgrammeBilan: Equatable {
    let done: Int
    let planned: Int
    let weeks: [ProgrammeBilanWeek]
    /// Plus longue suite de semaines complètes consécutives.
    let bestStreak: Int
    /// Activités hors programme sur la durée du bloc.
    let extras: Int
    /// Dernier jour du bloc (`YYYY-MM-DD`), `nil` si dates invalides.
    let endDate: String?

    /// Pourcentage entier ; `nil` quand rien n'était prévu.
    var percent: Int? {
        guard planned > 0 else { return nil }
        return Int((Double(done) / Double(planned) * 100).rounded())
    }
}

func programmeBilan(
    weeks: Int,
    startedOn: String,
    sessions: [ProgrammeSessionProgress],
    extras: [ProgrammeExtraActivity]
) -> ProgrammeBilan {
    let rows: [ProgrammeBilanWeek] = weeks > 0
        ? (1...weeks).map { index in
            let inWeek = sessions.filter { $0.week == index }
            return ProgrammeBilanWeek(week: index, done: inWeek.filter(\.done).count, planned: inWeek.count)
        }
        : []

    var best = 0
    var run = 0
    for row in rows {
        run = row.complete ? run + 1 : 0
        best = max(best, run)
    }

    let end = weeks > 0 ? ProgrammeDate.addDays(startedOn, weeks * 7 - 1) : nil
    let extraCount: Int
    if let end {
        extraCount = extras.filter { $0.date >= startedOn && $0.date <= end }.count
    } else {
        extraCount = 0
    }

    return ProgrammeBilan(
        done: rows.reduce(0) { $0 + $1.done },
        planned: rows.reduce(0) { $0 + $1.planned },
        weeks: rows,
        bestStreak: best,
        extras: extraCount,
        endDate: end
    )
}

// MARK: - « Déjà montré » (une fois par exécution du programme)

func programmeBravoKey(programmeId: String, startedOn: String) -> String {
    "programme.bravo.\(programmeId).\(startedOn)"
}

func programmeBravoSeen(programmeId: String, startedOn: String, defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: programmeBravoKey(programmeId: programmeId, startedOn: startedOn))
}

func programmeBravoMarkSeen(programmeId: String, startedOn: String, defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: programmeBravoKey(programmeId: programmeId, startedOn: startedOn))
}
