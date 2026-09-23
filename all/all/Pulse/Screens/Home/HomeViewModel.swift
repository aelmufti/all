//
//  HomeViewModel.swift
//  all (bridge-connect)
//
//  View-model de l'écran Accueil — port de la logique de calcul de
//  `custom-connect/web/src/app/pages/home/home.component.ts`, restreint au
//  périmètre annoncé par `PulseShellView` (« entraînement + intensité du
//  jour ») + FC « Maintenant » en option. Le sommeil, les pas/calories et la
//  nutrition (sections « Depuis le réveil »/« Nuit dernière » côté Angular)
//  ne sont pas repris ici : ils appartiennent à l'écran Santé.
//
//  Trois requêtes bloquantes (jour + activités + programme), l'intensité et
//  la FC en direct sont best-effort (une erreur n'empêche pas le reste de
//  s'afficher, comme `loadIntensity()` côté Angular).
//

import Foundation
import Observation

private let weekdayNamesSundayFirst = [
    "dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi",
]

@MainActor
@Observable
final class HomeViewModel {
    enum LoadState {
        case loading
        case loaded
        case failed(String)
    }

    struct Vital: Identifiable {
        let id: String
        let label: String
        let value: Int?
        let unit: String
    }

    struct WeekLead {
        let label: String
        let value: String
        let sub: String
    }

    struct WeekFact: Identifiable {
        var id: String { name }
        let name: String
        let value: String
    }

    struct SessionCardModel {
        let title: String
        let name: String
        let duration: String?
        let done: Bool
        let late: Bool
        let when: String?
        let meta: String
        let focus: String?
        let items: [HomeTrainingItem]
        let doneLabel: String
    }

    private(set) var state: LoadState = .loading

    private(set) var day: HomeDayDetail?
    private(set) var activities: [HomeActivity] = []
    private(set) var programme: [HomeProgrammeDomain] = []
    private(set) var intensity: HomeIntensityReport?
    private(set) var live: HomeLiveHeartRate?

    private let client: PulseAPIClient

    init(client: PulseAPIClient = .shared) {
        self.client = client
    }

    // MARK: - Chargement

    func load() async {
        state = .loading
        do {
            let today = Self.todayKey()
            async let dayTask: HomeDayDetail = client.get("api/wellness/day/\(today)")
            async let activitiesTask: HomeActivityListResponse = client.get(
                "api/activities", query: ["limit": "40"])
            var day = try await dayTask
            let activityList = try await activitiesTask
            self.activities = activityList.items

            if !day.hasData {
                let recent: [HomeDaySummaryDate] = try await client.get(
                    "api/wellness/days", query: ["limit": "1"])
                if let latest = recent.last?.date, latest != today {
                    day = try await client.get("api/wellness/day/\(latest)")
                }
            }
            self.day = day
            state = .loaded

            // Best-effort : ne bloquent pas l'affichage principal.
            async let programmeTask = loadProgramme(date: today)
            async let intensityTask = loadIntensity()
            async let liveTask = refreshLive()
            _ = await (programmeTask, intensityTask, liveTask)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func loadProgramme(date: String) async {
        do {
            let response: HomeProgrammeResponse = try await client.get(
                "api/programme", query: ["date": date])
            programme = response.domains
        } catch {
            programme = []
        }
    }

    private func loadIntensity() async {
        do {
            intensity = try await client.get("api/wellness/intensity")
        } catch {
            intensity = nil
        }
    }

    /// FC en direct — appelée au chargement puis en boucle par la vue
    /// (`.task` annulée automatiquement à la disparition de l'écran).
    func refreshLive() async {
        do {
            live = try await client.get("api/live/hr")
        } catch {
            live = nil
        }
    }

    func startLive() async {
        do {
            live = try await client.post("api/live/hr/start")
        } catch {
            // Best-effort : un échec de démarrage laisse simplement le dernier état connu.
        }
    }

    func stopLive() async {
        do {
            live = try await client.post("api/live/hr/stop")
        } catch {
            // idem
        }
    }

    // MARK: - « Maintenant »

    private var trainingDomain: HomeProgrammeDomain? {
        programme.first { $0.kind == "training" && $0.active != nil }
    }

    private static func last(_ samples: [HomeSample]) -> Int? {
        guard let last = samples.last else { return nil }
        return Int(last.value.rounded())
    }

    var lastHr: Int? { Self.last(day?.hr ?? []) }
    var restingHr: Int? { day?.summary.restingHr }

    /// FC affichée : le direct s'il est fiable, sinon le dernier relevé du jour.
    var shownHr: Int? {
        if let live, live.enabled, live.reachable, !live.stale, let bpm = live.heartRate {
            return bpm
        }
        return lastHr
    }

    var vitals: [Vital] {
        [
            Vital(id: "stress", label: "Stress", value: Self.last(day?.stress ?? []), unit: ""),
            Vital(id: "spo2", label: "Oxygène", value: Self.last(day?.spo2 ?? []), unit: "%"),
            Vital(
                id: "resp", label: "Respiration", value: Self.last(day?.respiration ?? []),
                unit: "/min"),
        ]
    }

    /// `stale()` côté Angular : le jour affiché n'est pas celui d'aujourd'hui.
    var staleLabel: String? {
        guard let date = day?.date, date != Self.todayKey() else { return nil }
        guard let refDate = Self.parseDateKey(date) else { return nil }
        let days = Calendar.current.dateComponents(
            [.day], from: Calendar.current.startOfDay(for: refDate),
            to: Calendar.current.startOfDay(for: Date())
        ).day ?? 0
        return "périmé · \(days) j"
    }

    var lastReadingLabel: String? {
        guard let ts = day?.hr.last?.ts else { return nil }
        let minutes = Int((Date().timeIntervalSince1970 - Double(ts)) / 60)
        if minutes < 1 { return "à l'instant" }
        if minutes < 60 { return "il y a \(minutes) min" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 { return "il y a \(hours) h" }
        return "il y a \(Int((Double(hours) / 24).rounded())) j"
    }

    // MARK: - Semaine d'entraînement

    /// Date de référence : celle du jour affiché (repli sur aujourd'hui si absente).
    private var refDate: Date {
        (day?.date).flatMap(Self.parseDateKey) ?? Date()
    }

    private var weekMonday: Date { Self.startOfWeek(refDate) }

    private var weekIndex: Int {
        let calendar = Calendar.current
        let days =
            calendar.dateComponents(
                [.day], from: weekMonday, to: calendar.startOfDay(for: refDate)
            ).day ?? 0
        return max(0, min(6, days))
    }

    /// Minutes d'entraînement faites, par jour de la semaine (lundi → dimanche).
    private var weekDoneMinutesByDay: [Double] {
        var minutes = [Double](repeating: 0, count: 7)
        let calendar = Calendar.current
        for activity in activities {
            guard let startTime = activity.startTime,
                let start = Self.parseISODate(startTime)
            else { continue }
            let dayIndex =
                calendar.dateComponents(
                    [.day], from: weekMonday, to: calendar.startOfDay(for: start)
                ).day ?? -1
            guard dayIndex >= 0, dayIndex <= 6 else { continue }
            minutes[dayIndex] += ((activity.durationS ?? 0) / 60).rounded()
        }
        return minutes
    }

    private var weekCumulated: [Double] {
        var running = 0.0
        return weekDoneMinutesByDay.map { minutes in
            running += minutes
            return running
        }
    }

    struct WeekPlan {
        let planned: Int
        let done: Int
        let minutes: Double
    }

    private var weekPlan: WeekPlan {
        var planned = 0
        var done = 0
        var minutes = 0.0
        let calendar = Calendar.current
        for session in trainingDomain?.detail?.sessions ?? [] {
            guard let plannedOn = session.plannedOn, let date = Self.parseDateKey(plannedOn)
            else { continue }
            let dayIndex =
                calendar.dateComponents(
                    [.day], from: weekMonday, to: calendar.startOfDay(for: date)
                ).day ?? -1
            guard dayIndex >= 0, dayIndex <= 6 else { continue }
            planned += 1
            minutes += session.session.minMinutes ?? 0
            if session.done { done += 1 }
        }
        return WeekPlan(planned: planned, done: done, minutes: minutes)
    }

    var weekRangeLabel: String {
        let sunday = Calendar.current.date(byAdding: .day, value: 6, to: weekMonday) ?? weekMonday
        let dayNumber: (Date) -> Int = { Calendar.current.component(.day, from: $0) }
        return "lun. \(dayNumber(weekMonday)) — dim. \(dayNumber(sunday))"
    }

    var weekLead: WeekLead {
        let goal = weekPlan.minutes
        let done = weekCumulated[weekIndex]
        if goal <= 0 {
            return WeekLead(
                label: "Cette semaine", value: Self.spanLabel(done), sub: "de séance enregistrée")
        }
        let remaining = goal - done
        if remaining <= 0 {
            return WeekLead(
                label: "Semaine tenue", value: Self.spanLabel(done),
                sub: "sur les \(Self.spanLabel(goal)) prévues")
        }
        return WeekLead(
            label: "Reste à faire", value: Self.spanLabel(remaining), sub: "pour tenir la semaine")
    }

    /// Part de l'objectif hebdomadaire d'entraînement atteinte, jour par
    /// jour jusqu'à aujourd'hui (0…1+) — support d'un graphique de
    /// progression simplifié (`WeekProgressChart`).
    var trainingShare: [Double] {
        let goal = weekPlan.minutes
        guard goal > 0 else { return [] }
        return Array(weekCumulated.prefix(weekIndex + 1)).map { $0 / goal }
    }

    /// Idem côté intensité — directement dérivé de `current.days` (déjà
    /// cumulé jour par jour depuis lundi côté serveur, cf. `intensity.service.ts`).
    var intensityShare: [Double] {
        guard let goal = intensity?.current.goal, goal > 0, let days = intensity?.current.days
        else { return [] }
        return days.map { $0.cumulative / goal }
    }

    var weekFacts: [WeekFact] {
        let plan = weekPlan
        let done = weekCumulated[weekIndex]
        var facts: [WeekFact] = []
        if plan.minutes > 0 {
            facts.append(
                WeekFact(name: "Séances", value: "\(Self.spanLabel(done)) / \(Self.spanLabel(plan.minutes))"))
        } else {
            let weekday = weekdayNamesSundayFirst[Calendar.current.component(.weekday, from: refDate) - 1]
            facts.append(WeekFact(name: "Cumulé à \(weekday)", value: Self.spanLabel(done)))
        }
        if let week = intensity?.current {
            facts.append(
                WeekFact(
                    name: week.light ? "Intensité (semaine légère)" : "Intensité",
                    value: "\(Int(week.minutes.rounded())) min / \(Int(week.goal.rounded())) min"))
        }
        let count = activities.filter { activity in
            guard let startTime = activity.startTime, let start = Self.parseISODate(startTime)
            else { return false }
            let dayIndex =
                Calendar.current.dateComponents(
                    [.day], from: weekMonday, to: Calendar.current.startOfDay(for: start)
                ).day ?? -1
            return dayIndex >= 0 && dayIndex <= 6
        }.count
        facts.append(
            WeekFact(
                name: "Séances faites",
                value: plan.planned > 0 ? "\(plan.done) sur \(plan.planned)" : "\(count)"))
        return facts
    }

    var weekNote: String {
        let planned = weekPlan.minutes > 0
        guard let week = intensity?.current else {
            return planned
                ? "Le trait plein monte avec les minutes déjà faites, le pointillé oblique donne le rythme régulier."
                : "Le trait plein monte avec les minutes déjà faites ; aucun objectif n'est fixé cette semaine."
        }
        let goalNote = "Objectif d'intensité \(Self.goalReasonLabel(week.reason))."
        return planned
            ? "Chaque trait monte vers son propre objectif, le pointillé oblique donne le rythme régulier. \(goalNote)"
            : "Le trait monte vers l'objectif, le pointillé oblique donne le rythme régulier. \(goalNote) Aucune séance n'est programmée cette semaine."
    }

    // MARK: - Séance (jour ou à venir)

    var session: SessionCardModel? {
        guard let sessions = trainingDomain?.detail?.sessions, !sessions.isEmpty else { return nil }
        let today = Self.todayKey()
        let pending = sessions.filter { !$0.done }
        let ahead = pending
            .filter { ($0.plannedOn ?? "") > today && $0.plannedOn != nil }
            .sorted { ($0.plannedOn ?? "") < ($1.plannedOn ?? "") }
        let behind = pending
            .filter { ($0.plannedOn ?? "") < today && $0.plannedOn != nil }
            .sorted { ($0.plannedOn ?? "") > ($1.plannedOn ?? "") }

        let target =
            sessions.first { $0.plannedOn == today && !$0.done }
            ?? sessions.first { $0.done && $0.date == today }
            ?? ahead.first
            ?? behind.first
            ?? pending.first
        guard let target else { return nil }

        let late = !target.done && (target.plannedOn ?? "") < today && target.plannedOn != nil
        let title: String
        if target.done {
            title = "Séance du jour"
        } else if target.plannedOn == today {
            title = "Séance du jour"
        } else if late {
            title = "Séance en retard"
        } else {
            title = "Prochaine séance"
        }

        let detail = trainingDomain?.detail
        let weeks = trainingDomain?.active?.weeks ?? 0
        return SessionCardModel(
            title: title,
            name: target.session.name,
            duration: target.session.minMinutes.map { "\(Int($0)) min" },
            done: target.done,
            late: late,
            when: target.done ? nil : Self.whenLabel(target.plannedOn, today: today),
            meta: Self.sessionMeta(week: target.week, weeks: weeks, detail: detail),
            focus: detail?.focus?.first { $0.index == target.week }?.focus,
            items: target.session.items ?? [],
            doneLabel: target.date.map { "faite le \(Self.shortDate($0))" } ?? "faite"
        )
    }

    // MARK: - Utilitaires de date (miroir des fonctions libres du composant Angular)

    static func todayKey() -> String {
        dateKey(Date())
    }

    static func dateKey(_ date: Date) -> String {
        let calendar = Calendar.current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Parse une clé `YYYY-MM-DD` en date locale à midi (comme
    /// `new Date(\`${date}T12:00:00\`)` côté Angular — évite les soucis de
    /// bascule de jour liés au fuseau).
    static func parseDateKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        return Calendar.current.date(from: components)
    }

    static func parseISODate(_ iso: String) -> Date? {
        if let date = isoFormatterWithFractional.date(from: iso) { return date }
        return isoFormatter.date(from: iso)
    }

    private static let isoFormatter = ISO8601DateFormatter()
    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func startOfWeek(_ date: Date) -> Date {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: date)  // 1 = dimanche … 7 = samedi
        let offset = (weekday + 5) % 7  // jours depuis lundi
        return calendar.date(byAdding: .day, value: -offset, to: dayStart) ?? dayStart
    }

    static func spanLabel(_ minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        let hours = total / 60
        let rest = total % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(String(format: "%02d", rest))"
    }

    static func shortDate(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3 else { return iso }
        return "\(parts[2])/\(parts[1])"
    }

    static func whenLabel(_ plannedOn: String?, today: String) -> String? {
        guard let plannedOn else { return nil }
        if plannedOn == today { return "aujourd'hui" }
        guard let plannedDate = parseDateKey(plannedOn), let todayDate = parseDateKey(today) else {
            return nil
        }
        let days =
            Calendar.current.dateComponents(
                [.day], from: Calendar.current.startOfDay(for: todayDate),
                to: Calendar.current.startOfDay(for: plannedDate)
            ).day ?? 0
        if days < 0 { return "en retard depuis le \(shortDate(plannedOn))" }
        if days == 1 { return "demain" }
        let weekday = weekdayNamesSundayFirst[Calendar.current.component(.weekday, from: plannedDate) - 1]
        return days < 7 ? weekday : "\(weekday) \(shortDate(plannedOn))"
    }

    static func sessionMeta(week: Int, weeks: Int, detail: HomeProgrammeDetail?) -> String {
        var parts: [String] = []
        parts.append(weeks > 0 ? "semaine \(week) sur \(weeks)" : "semaine \(week)")
        let done = detail?.done ?? 0
        let total = detail?.total ?? 0
        if total > 0 { parts.append("\(done) séance\(done > 1 ? "s" : "") sur \(total)") }
        let missed = detail?.missed ?? 0
        if missed > 0 { parts.append("\(missed) en retard") }
        return parts.joined(separator: " · ")
    }

    static func goalReasonLabel(_ reason: IntensityGoalReason) -> String {
        switch reason {
        case .seed: return "par défaut, faute de semaine assez mesurée"
        case .raised: return "en hausse : vos six dernières semaines montent"
        case .lowered: return "en baisse : vos six dernières semaines baissent"
        case .light: return "allégé après trois semaines tenues de justesse"
        case .held: return "stable, au niveau de vos six dernières semaines"
        case .pinned: return "fixé à la main"
        case .skipped: return "inchangé, faute de mesures récentes"
        }
    }
}
