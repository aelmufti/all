//
//  ProgrammeProgress.swift
//  all (bridge-connect)
//
//  Portage Swift de `custom-connect/server/src/programme/progress.ts`
//  (incrément L7a, cf. `docs/stockage-local.md`) : rapprochement
//  séances/activités importées (`matchSessions`), avancement journalier
//  alimentation (`checkDay`), utilitaires de date calendaire (`addDays`/
//  `weekdayOf`/`weekOf`) et de planification (`buildPlan`/`sessionsPerWeek`).
//
//  `buildPlan` n'est appelé par AUCUNE route de cet incrément (`GET
//  api/programme` ne fait que LIRE `programme_plan`, jamais l'écrire :
//  `POST api/programme/activate`, seul appelant côté serveur, reste
//  `LocalPulseUnavailableError` — cf. `RealLocalPulseBackend`) : porté quand
//  même pour fidélité au fichier source et pour être prêt le jour où
//  l'activation locale est câblée. Ni appelé ni testé dans ce périmètre.
//

import Foundation

// MARK: - Types d'entrée/sortie (miroir `DoneSession`/`PlannedSession`/
// `ActivityHit`/`DayIntake`/`SessionStatus`/`SessionProgress`/`RuleProgress`/
// `DayProgress`)

struct ProgrammeEngineDoneSession {
    let week: Int
    let session: String
    let date: String
    let activityId: Int?
    let manual: Bool
}

struct ProgrammeEnginePlannedSession {
    let week: Int
    let session: String
    let date: String
}

struct ProgrammeEngineActivityHit {
    let id: Int
    let date: String
    let sport: String?
    let subSport: String?
    let durationS: Double?
}

struct ProgrammeEngineDayIntake {
    let date: String
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double
    let kcal: Double
}

enum ProgrammeEngineSessionStatus: String {
    case done, today, upcoming, missed
}

struct ProgrammeEngineSessionProgress {
    let week: Int
    let session: ProgrammeEngineTrainingSession
    let plannedOn: String?
    let status: ProgrammeEngineSessionStatus
    let done: Bool
    let date: String?
    let activityId: Int?
    let manual: Bool
}

/// Miroir de `RuleProgress['status']`/`SleepStatus` (TS) — partagé entre
/// `checkDay` (alimentation) et `ProgrammeSleepEngine` (mêmes quatre valeurs).
enum ProgrammeEngineStatus: String {
    case hit, under, over, unknown
}

struct ProgrammeEngineRuleProgress {
    let rule: ProgrammeEngineNutritionRule
    let targetMin: Double?
    let targetMax: Double?
    let value: Double?
    let status: ProgrammeEngineStatus
}

struct ProgrammeEngineDayProgress {
    let date: String
    let logged: Bool
    let rules: [ProgrammeEngineRuleProgress]
    let hits: Int
    let total: Int
}

enum ProgrammeProgressEngine {
    /// `yyyy-MM-dd`, toujours interprété en UTC — miroir de `` `${date}T00:00:00Z` ``
    /// (TS, `Date.parse`) : arithmétique de date calendaire pure, indépendante
    /// du fuseau de l'appareil (contrairement à `LocalDb.localOffsetSeconds`,
    /// utilisé seulement par le domaine sommeil, cf. `ProgrammeSleepEngine`).
    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func utcDate(_ key: String) -> Date? { utcFormatter.date(from: key) }

    /// Miroir de `addDays` (TS).
    static func addDays(_ date: String, _ days: Int) -> String {
        guard let base = utcDate(date) else { return date }
        return utcFormatter.string(from: base.addingTimeInterval(Double(days) * 86400))
    }

    /// Miroir de `weekdayOf` (TS, `getUTCDay()` : 0 = dimanche … 6 = samedi).
    static func weekdayOf(_ date: String) -> Int {
        guard let d = utcDate(date) else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // `Calendar.component(.weekday)` : 1 = dimanche … 7 = samedi.
        return calendar.component(.weekday, from: d) - 1
    }

    /// Miroir de `weekOf` (TS).
    static func weekOf(startedOn: String, date: String) -> Int {
        guard let start = utcDate(startedOn)?.timeIntervalSince1970,
              let day = utcDate(date)?.timeIntervalSince1970,
              day >= start
        else { return 0 }
        return Int((day - start) / (7 * 86400)) + 1
    }

    /// Miroir de `sessionsPerWeek` (TS).
    static func sessionsPerWeek(_ programme: ProgrammeEngineProgramme) -> Int {
        programme.weeks.reduce(0) { max($0, $1.sessions.count) }
    }

    /// Miroir de `buildPlan` (TS) — cf. en-tête de fichier : ni appelé ni
    /// testé dans cet incrément (aucune route d'activation locale), porté
    /// pour fidélité et pour un futur incrément.
    static func buildPlan(programme: ProgrammeEngineProgramme, startedOn: String, days: [Int]) -> [ProgrammeEnginePlannedSession] {
        let wanted = Array(Set(days)).filter { $0 >= 0 && $0 <= 6 }
        guard !wanted.isEmpty else { return [] }
        var plan: [ProgrammeEnginePlannedSession] = []
        for week in programme.weeks {
            let from = addDays(startedOn, (week.index - 1) * 7)
            var slots: [String] = []
            for offset in 0..<7 {
                let day = addDays(from, offset)
                if wanted.contains(weekdayOf(day)) { slots.append(day) }
            }
            for (i, session) in week.sessions.enumerated() where i < slots.count {
                plan.append(ProgrammeEnginePlannedSession(week: week.index, session: session.key, date: slots[i]))
            }
        }
        return plan
    }

    /// Miroir de `matches` (TS, privée).
    private static func matches(_ session: ProgrammeEngineTrainingSession, _ activity: ProgrammeEngineActivityHit) -> Bool {
        if session.sport != (activity.sport ?? "") { return false }
        if let subSport = session.subSport, subSport != (activity.subSport ?? "") { return false }
        if let minMinutes = session.minMinutes, (activity.durationS ?? 0) / 60 < Double(minMinutes) { return false }
        return true
    }

    /// Miroir de `statusFor` (TS, privée, `progress.ts`).
    private static func statusFor(done: Bool, plannedOn: String?, today: String) -> ProgrammeEngineSessionStatus {
        if done { return .done }
        guard let plannedOn else { return .upcoming }
        if plannedOn == today { return .today }
        return plannedOn < today ? .missed : .upcoming
    }

    /// Miroir de `matchSessions` (TS) — rapproche chaque séance catalogue
    /// d'une activité importée (fenêtre de semaine ou date planifiée) ou d'un
    /// pointage manuel (`programme_done`), une activité n'étant jamais
    /// réclamée deux fois (`claimed`).
    static func matchSessions(
        programme: ProgrammeEngineProgramme, startedOn: String, activities: [ProgrammeEngineActivityHit],
        manual: [ProgrammeEngineDoneSession], plan: [ProgrammeEnginePlannedSession], today: String
    ) -> [ProgrammeEngineSessionProgress] {
        var out: [ProgrammeEngineSessionProgress] = []
        var claimed = Set<Int>()
        var manualByKey: [String: ProgrammeEngineDoneSession] = [:]
        for d in manual { manualByKey["\(d.week)|\(d.session)"] = d }
        var planByKey: [String: String] = [:]
        for p in plan { planByKey["\(p.week)|\(p.session)"] = p.date }

        for week in programme.weeks {
            for session in week.sessions {
                let key = "\(week.index)|\(session.key)"
                let plannedOn = planByKey[key]
                if let forced = manualByKey[key] {
                    out.append(ProgrammeEngineSessionProgress(
                        week: week.index, session: session, plannedOn: plannedOn, status: .done, done: true,
                        date: forced.date, activityId: forced.activityId, manual: true))
                    if let id = forced.activityId { claimed.insert(id) }
                    continue
                }
                let windowMatch: (ProgrammeEngineActivityHit) -> Bool
                if let plannedOn {
                    windowMatch = { $0.date == plannedOn }
                } else {
                    let from = addDays(startedOn, (week.index - 1) * 7)
                    let to = addDays(startedOn, week.index * 7)
                    windowMatch = { $0.date >= from && $0.date < to }
                }
                let hit = activities.first { !claimed.contains($0.id) && windowMatch($0) && matches(session, $0) }
                if let hit { claimed.insert(hit.id) }
                out.append(ProgrammeEngineSessionProgress(
                    week: week.index, session: session, plannedOn: plannedOn,
                    status: statusFor(done: hit != nil, plannedOn: plannedOn, today: today),
                    done: hit != nil, date: hit?.date, activityId: hit?.id, manual: false))
            }
        }
        return out
    }

    /// Miroir du champ `metric` de `NutritionRule` — sélectionne le champ de
    /// `ProgrammeEngineDayIntake` correspondant.
    private static func metricValue(_ intake: ProgrammeEngineDayIntake, metric: String) -> Double {
        switch metric {
        case "protein": return intake.protein
        case "carbs": return intake.carbs
        case "fat": return intake.fat
        case "kcal": return intake.kcal
        case "fiber": return intake.fiber
        default: return 0
        }
    }

    /// Miroir de `checkDay` (TS) — bornes recadrées par kilo de poids si
    /// `rule.perKg`, valeur/bornes arrondies à l'entier (`Math.round`).
    static func checkDay(programme: ProgrammeEngineProgramme, intake: ProgrammeEngineDayIntake?, weightKg: Double?, date: String) -> ProgrammeEngineDayProgress {
        var rules: [ProgrammeEngineRuleProgress] = []
        for rule in programme.rules {
            let scale: Double? = rule.perKg ? weightKg : 1
            let min: Double? = (rule.min != nil && scale != nil) ? (rule.min! * scale!).rounded() : nil
            let max: Double? = (rule.max != nil && scale != nil) ? (rule.max! * scale!).rounded() : nil
            let value: Double? = intake.map { metricValue($0, metric: rule.metric).rounded() }
            var status: ProgrammeEngineStatus = .unknown
            if let value, min != nil || max != nil {
                if let min, value < min {
                    status = .under
                } else if let max, value > max {
                    status = .over
                } else {
                    status = .hit
                }
            }
            rules.append(ProgrammeEngineRuleProgress(rule: rule, targetMin: min, targetMax: max, value: value, status: status))
        }
        return ProgrammeEngineDayProgress(
            date: date, logged: intake != nil, rules: rules,
            hits: rules.filter { $0.status == .hit }.count, total: rules.count)
    }
}
