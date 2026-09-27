//
//  HomeViewModel.swift
//  all (bridge-connect)
//
//  View-model de l'écran Accueil — port 1-1 de la logique de calcul de
//  `custom-connect/web/src/app/pages/home/home.component.ts` : FC
//  « Maintenant », entraînement de la semaine + intensité, séance du
//  jour/à venir, « Depuis le réveil » (pas/calories) et « Nuit dernière »
//  (durée, hypnogramme, régularité du coucher).
//
//  La requête jour + activités est bloquante ; programme, intensité, FC en
//  direct, dette de sommeil et nutrition sont best-effort (une erreur
//  n'empêche pas le reste de s'afficher, comme `loadSideData()` côté
//  Angular).
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

    // MARK: - « Depuis le réveil »

    struct WakeDelta {
        let sign: String
        let value: Double
        let hit: Bool
    }

    struct WakeMetric: Identifiable {
        let id: String
        let label: String
        let value: Double?
        /// Part de l'objectif atteinte (0…1+), `nil` sans objectif connu —
        /// position du point de jauge (`gauge().top` côté Angular).
        let reached: Double?
        let delta: WakeDelta?
    }

    // MARK: - « Nuit dernière »

    struct NightDelta {
        let label: String
        let short: Bool
    }

    struct NightMissing {
        let title: String
        let sub: String
    }

    struct HypnogramBlock: Identifiable {
        let id: Int
        let stage: HomeSleepStageKind
        let width: Double
    }

    struct BedtimeDot: Identifiable {
        var id: String { date }
        let date: String
        /// Position 0…1 le long de la bande — équivalent fraction de
        /// `d.at` (pourcentage) côté Angular.
        let at: Double
        let free: Bool
        let title: String
    }

    struct BedtimeTick: Identifiable {
        let id = UUID()
        let at: Double
        let label: String
    }

    struct Bedtime {
        let clock: String
        let bandLeft: Double
        let bandWidth: Double
        let meanAt: Double
        let dots: [BedtimeDot]
        let ticks: [BedtimeTick]
        let note: String
    }

    private(set) var state: LoadState = .loading

    private(set) var day: HomeDayDetail?
    private(set) var activities: [HomeActivity] = []
    private(set) var programme: [HomeProgrammeDomain] = []
    private(set) var intensity: HomeIntensityReport?
    private(set) var live: HomeLiveHeartRate?
    private(set) var sleepDebt: HomeSleepDebt?
    private(set) var dayTarget: HomeDayTargetAuto?
    private(set) var intake: HomeNutritionAmount?
    private(set) var intakeTarget: HomeNutritionAmount?

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
            // La FC live est rapatriée AVANT de décider du repli : elle arrive
            // par un canal séparé (`api/live/hr`, temps réel) de l'historique du
            // jour (`api/wellness/day`, alimenté par ingestion `.fit` par lots).
            async let liveTask: Void = refreshLive()
            var day = try await dayTask
            let activityList = try await activitiesTask
            self.activities = activityList.items
            await liveTask

            // Repli sur le dernier jour AVEC données — SAUF si la FC live est
            // joignable : dans ce cas on reste sur aujourd'hui (le direct
            // alimente le bpm, les panneaux se rempliront à la prochaine
            // ingestion). Sinon, au passage de minuit, on afficherait « périmé »
            // (jour n-1) alors qu'on mesure en direct à l'instant même.
            if !day.hasData && !isLiveNow {
                let recent: [HomeDaySummaryDate] = try await client.get(
                    "api/wellness/days", query: ["limit": "1"])
                if let latest = recent.last?.date, latest != today {
                    day = try await client.get("api/wellness/day/\(latest)")
                }
            }
            self.day = day
            state = .loaded

            // Best-effort : ne bloquent pas l'affichage principal (le live est
            // déjà rapatrié ci-dessus).
            async let programmeTask = loadProgramme(date: today)
            async let intensityTask = loadIntensity()
            async let sleepDebtTask = loadSleepDebt()
            async let nutritionTask = loadNutrition(date: today)
            _ = await (programmeTask, intensityTask, sleepDebtTask, nutritionTask)
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

    /// `GET api/stats/sleep-debt` — alimente `nightDelta` (écart de la nuit
    /// affichée vs l'habitude récente), `sleepDebt()` côté Angular.
    private func loadSleepDebt() async {
        do {
            sleepDebt = try await client.get("api/stats/sleep-debt")
        } catch {
            sleepDebt = nil
        }
    }

    /// `GET api/nutrition/day/:date` + `GET api/nutrition/targets` —
    /// alimente la jauge « Cal. mangées » de « Depuis le réveil »,
    /// `loadSideData()` côté Angular.
    private func loadNutrition(date: String) async {
        do {
            async let dayTask: HomeNutritionDayResponse = client.get("api/nutrition/day/\(date)")
            async let targetsTask: HomeNutritionTargetsResponse = client.get(
                "api/nutrition/targets", query: ["date": date])
            let day = try await dayTask
            let targets = try await targetsTask
            // Miroir de `intake.set(day.entries.length > 0 ? day.totals : null)`.
            intake = day.entries.isEmpty ? nil : day.totals
            intakeTarget = day.targets
            dayTarget = targets.auto
        } catch {
            intake = nil
            intakeTarget = nil
            dayTarget = nil
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
    var restingHr: Int? { day?.summary.restingHr.map { Int($0.rounded()) } }

    /// FC affichée : le direct s'il est fiable, sinon le dernier relevé du jour.
    var shownHr: Int? {
        if let live, live.enabled, live.reachable, !live.stale, let bpm = live.heartRate {
            return bpm
        }
        return lastHr
    }

    /// La montre livre une FC en direct exploitable — même condition que
    /// `shownHr`. Sert à ancrer « Maintenant » sur aujourd'hui plutôt que de
    /// retomber sur le dernier jour ingéré au passage de minuit.
    var isLiveNow: Bool {
        guard let live else { return false }
        return live.enabled && live.reachable && !live.stale && live.heartRate != nil
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

    // MARK: - « Depuis le réveil »

    private static let stepGoal = 10_000.0
    private static let paceBandTolerance = 0.06

    /// Fraction du jour écoulée (0…1) — `elapsed()` côté Angular : figée à 1
    /// pour un jour périmé (plus de rythme à suivre), sinon l'heure actuelle.
    private var elapsed: Double {
        if staleLabel != nil { return 1 }
        let now = Date()
        let minutes = Double(
            Calendar.current.component(.hour, from: now) * 60
                + Calendar.current.component(.minute, from: now))
        return min(minutes / 1440, 1)
    }

    var wake: [WakeMetric] {
        let summary = day?.summary
        let e = elapsed
        let burned = Self.sum(summary?.bmrKcal.map { $0 * e }, summary?.activeCalories)
        return [
            Self.gauge(id: "steps", label: "Pas marchés", value: summary?.steps, goal: Self.stepGoal, elapsed: e),
            Self.gauge(
                id: "burned", label: "Cal. brûlées", value: burned,
                goal: dayTarget?.expenditureKcal, elapsed: e),
            Self.gauge(
                id: "eaten", label: "Cal. mangées", value: intake?.kcal,
                goal: intakeTarget?.kcal, elapsed: e),
        ]
    }

    private static func sum(_ values: Double?...) -> Double? {
        let present = values.compactMap { $0 }
        return present.isEmpty ? nil : present.reduce(0, +)
    }

    private static func gauge(id: String, label: String, value: Double?, goal: Double?, elapsed: Double)
        -> WakeMetric
    {
        let reached: Double? = {
            guard let value, let goal, goal > 0 else { return nil }
            return min(value / goal, 1)
        }()
        return WakeMetric(
            id: id, label: label, value: value, reached: reached,
            delta: paceDelta(value: value, goal: goal, elapsed: elapsed))
    }

    private static func paceDelta(value: Double?, goal: Double?, elapsed: Double) -> WakeDelta? {
        guard let value, let goal else { return nil }
        let pace = goal * elapsed
        let diff = value - pace
        if abs(diff) <= max(pace * paceBandTolerance, 1) {
            return WakeDelta(sign: "±", value: 0, hit: true)
        }
        return WakeDelta(sign: diff < 0 ? "−" : "+", value: abs(diff).rounded(), hit: false)
    }

    // MARK: - « Nuit dernière »

    var nightDurationLabel: String? {
        guard let seconds = day?.sleep.main?.durationS, seconds > 0 else { return nil }
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600) / 60).rounded())
        return "\(hours) h \(String(format: "%02d", minutes))"
    }

    var nightDelta: NightDelta? {
        guard let seconds = day?.sleep.main?.durationS, seconds > 0,
            let habitHours = sleepDebt?.avgHours, habitHours > 0
        else { return nil }
        let deltaMin = Int((seconds / 60 - habitHours * 60).rounded())
        if abs(deltaMin) < 10 { return NightDelta(label: "conforme à ton habitude", short: false) }
        let sign = deltaMin < 0 ? "−" : "+"
        let absMin = abs(deltaMin)
        let label = "\(sign)\(absMin / 60) h \(String(format: "%02d", absMin % 60)) vs habitude"
        return NightDelta(label: label, short: deltaMin < 0)
    }

    var nightMissing: NightMissing {
        guard let date = day?.date else {
            return NightMissing(
                title: "Aucun relevé importé.",
                sub: "La nuit apparaîtra après la première synchronisation.")
        }
        return NightMissing(
            title: "La montre n'a pas rendu la nuit du \(Self.shortDate(date)).",
            sub: "Elle s'affichera dès que son fichier de sommeil sera importé.")
    }

    var hypnogram: [HypnogramBlock]? {
        let stages = day?.sleep.stages ?? []
        guard !stages.isEmpty else { return nil }
        return stages.enumerated().map { index, stage in
            HypnogramBlock(id: index, stage: stage.stage, width: max(Double(stage.to - stage.from), 1))
        }
    }

    // MARK: - Coucher moyen (régularité, domaine `sleep` du programme)

    private var sleepDomain: HomeProgrammeDomain? {
        programme.first { $0.kind == "sleep" && $0.active != nil }
    }

    private static let bedtimeSpreadMinSpan = 180.0

    /// Port de `bedtime()` côté Angular — axe de coucher (moyenne ± écart
    /// type) + un point par nuit récente, en fractions 0…1 (la vue applique
    /// la largeur réelle via `GeometryReader`, pas de pourcentages ici).
    var bedtime: Bedtime? {
        guard let detail = sleepDomain?.detail,
            let axis = detail.axis,
            let strip = detail.strip, !strip.isEmpty
        else { return nil }

        let onsets = strip.map { $0.onset }
        let low = min(onsets.min() ?? axis.onsetMean, axis.onsetMean - axis.onsetSd)
        let high = max(onsets.max() ?? axis.onsetMean, axis.onsetMean + axis.onsetSd)
        let pad = max(25, (high - low) * 0.15)
        var start = ((low - pad) / 30).rounded(.down) * 30
        var end = ((high + pad) / 30).rounded(.up) * 30
        if end - start < Self.bedtimeSpreadMinSpan {
            let middle = (start + end) / 2
            start = ((middle - Self.bedtimeSpreadMinSpan / 2) / 30).rounded(.down) * 30
            end = start + Self.bedtimeSpreadMinSpan
        }
        let span = end - start
        guard span > 0 else { return nil }
        func at(_ minute: Double) -> Double { (minute - start) / span }

        let step: Double = span <= 240 ? 60 : 120
        var ticks: [BedtimeTick] = []
        var minute = (start / step).rounded(.up) * step
        while minute <= end {
            let pos = at(minute)
            if pos >= 0.07 && pos <= 0.93 {
                ticks.append(BedtimeTick(at: pos, label: Self.tickHourLabel(minute)))
            }
            minute += step
        }

        let nights = detail.nights ?? strip.count
        let stale = (detail.staleDays ?? 0) > 3 && detail.to != nil
        let scope =
            stale
            ? "jusqu'au \(Self.shortDate(detail.to!))"
            : "à \(Int(axis.onsetSd.rounded())) min près"

        let dots = strip.map { night in
            BedtimeDot(
                date: night.date,
                at: min(max(at(night.onset), 0), 1),
                free: !night.workDay,
                title: "\(Self.shortDate(night.date)) · coucher \(Self.clockLabel(night.onset))")
        }

        return Bedtime(
            clock: Self.clockLabel(axis.onsetMean),
            bandLeft: at(axis.onsetMean - axis.onsetSd),
            bandWidth: at(axis.onsetMean + axis.onsetSd) - at(axis.onsetMean - axis.onsetSd),
            meanAt: at(axis.onsetMean),
            dots: dots,
            ticks: ticks,
            note: "\(nights) nuits · \(scope) · \(detail.hits ?? 0)/\(detail.total ?? 0) critères")
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

    /// Convertit une valeur en « espace axe » serveur (origine décalée de
    /// 12 h, cf. `HomeSleepAxis`) en heure d'horloge lisible — miroir de
    /// `clockLabel()` côté Angular.
    static func clockLabel(_ axisMinutes: Double) -> String {
        let wrapped =
            (axisMinutes.truncatingRemainder(dividingBy: 1440) + 1440)
            .truncatingRemainder(dividingBy: 1440)
        let minuteOfDay = Int(((wrapped + 720).truncatingRemainder(dividingBy: 1440)).rounded())
        let hours = (minuteOfDay / 60) % 24
        return "\(hours) h \(String(format: "%02d", minuteOfDay % 60))"
    }

    /// Étiquette d'une graduation de la bande de régularité — juste l'heure,
    /// sans les minutes (les graduations tombent toujours sur une heure
    /// ronde, pas de perte d'info). Miroir de la ligne `label:` inline du
    /// calcul de `ticks` côté Angular (`bedtime()`).
    static func tickHourLabel(_ axisMinute: Double) -> String {
        let hoursFloat = axisMinute / 60 + 12
        var mod = hoursFloat.truncatingRemainder(dividingBy: 24)
        if mod < 0 { mod += 24 }
        return "\(Int(mod.rounded(.down))) h"
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
