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
    let distanceM: Double?
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

    /// Miroir de `MIN_WALK_DISTANCE_M` (TS) — une marche plus courte ne compte
    /// jamais (ni séance, ni hors programme).
    static let minWalkDistanceM: Double = 4000

    /// Miroir de `isShortWalk` (TS, privée).
    private static func isShortWalk(_ activity: ProgrammeEngineActivityHit) -> Bool {
        activity.sport == "walking" && (activity.distanceM ?? 0) < minWalkDistanceM
    }

    /// Miroir de `dayDistance` (TS, privée) — écart en jours entre deux dates.
    private static func dayDistance(_ a: String, _ b: String) -> Double {
        guard let da = utcDate(a), let db = utcDate(b) else { return .infinity }
        return abs(da.timeIntervalSince(db)) / 86400
    }

    /// Miroir de `matches` (TS, privée).
    private static func matches(_ session: ProgrammeEngineTrainingSession, _ activity: ProgrammeEngineActivityHit) -> Bool {
        if isShortWalk(activity) { return false }
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

    /// Miroir de `matchSessions` (TS) — pointage manuel d'abord (`programme_done`),
    /// puis passe « jour exact » (activité du jour planifié), puis passe « même
    /// semaine » (séance dont le jour prévu est le plus proche). Une activité
    /// n'est jamais réclamée deux fois (`claimed`).
    static func matchSessions(
        programme: ProgrammeEngineProgramme, startedOn: String, activities: [ProgrammeEngineActivityHit],
        manual: [ProgrammeEngineDoneSession], plan: [ProgrammeEnginePlannedSession], today: String
    ) -> [ProgrammeEngineSessionProgress] {
        var claimed = Set<Int>()
        var manualByKey: [String: ProgrammeEngineDoneSession] = [:]
        for d in manual { manualByKey["\(d.week)|\(d.session)"] = d }
        var planByKey: [String: String] = [:]
        for p in plan { planByKey["\(p.week)|\(p.session)"] = p.date }

        struct Slot {
            let week: Int
            let session: ProgrammeEngineTrainingSession
            let plannedOn: String?
        }
        var slots: [Slot] = []
        var results: [Int: ProgrammeEngineSessionProgress] = [:]
        for week in programme.weeks {
            for session in week.sessions {
                let key = "\(week.index)|\(session.key)"
                let plannedOn = planByKey[key]
                let index = slots.count
                slots.append(Slot(week: week.index, session: session, plannedOn: plannedOn))
                if let forced = manualByKey[key] {
                    results[index] = ProgrammeEngineSessionProgress(
                        week: week.index, session: session, plannedOn: plannedOn, status: .done, done: true,
                        date: forced.date, activityId: forced.activityId, manual: true)
                    if let id = forced.activityId { claimed.insert(id) }
                }
            }
        }

        func claim(_ index: Int, _ hit: ProgrammeEngineActivityHit) {
            claimed.insert(hit.id)
            let slot = slots[index]
            results[index] = ProgrammeEngineSessionProgress(
                week: slot.week, session: slot.session, plannedOn: slot.plannedOn, status: .done, done: true,
                date: hit.date, activityId: hit.id, manual: false)
        }

        // Passe « jour exact ».
        for (index, slot) in slots.enumerated() where results[index] == nil {
            guard let plannedOn = slot.plannedOn else { continue }
            if let hit = activities.first(where: { !claimed.contains($0.id) && $0.date == plannedOn && matches(slot.session, $0) }) {
                claim(index, hit)
            }
        }

        // Passe « même semaine ».
        for a in activities where !claimed.contains(a.id) {
            var best = -1
            var bestDistance = Double.infinity
            for (index, slot) in slots.enumerated() where results[index] == nil {
                let from = addDays(startedOn, (slot.week - 1) * 7)
                guard a.date >= from && a.date < addDays(startedOn, slot.week * 7) else { continue }
                guard matches(slot.session, a) else { continue }
                let distance = slot.plannedOn.map { dayDistance($0, a.date) } ?? 0
                if distance < bestDistance {
                    best = index
                    bestDistance = distance
                }
            }
            if best >= 0 { claim(best, a) }
        }

        return slots.enumerated().map { index, slot in
            results[index] ?? ProgrammeEngineSessionProgress(
                week: slot.week, session: slot.session, plannedOn: slot.plannedOn,
                status: statusFor(done: false, plannedOn: slot.plannedOn, today: today),
                done: false, date: nil, activityId: nil, manual: false)
        }
    }

    /// Miroir de `extraActivities` (TS) — activités réclamées par aucune séance
    /// (auto ou manuelle), ordre chronologique, hors marches trop courtes.
    static func extraActivities(
        activities: [ProgrammeEngineActivityHit], sessions: [ProgrammeEngineSessionProgress]
    ) -> [ProgrammeEngineActivityHit] {
        let claimed = Set(sessions.compactMap(\.activityId))
        return activities.filter { !claimed.contains($0.id) && !isShortWalk($0) }
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
