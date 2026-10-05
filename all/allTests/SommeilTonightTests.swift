//
//  SommeilTonightTests.swift
//  allTests
//
//  Carte « Ce soir » + carte par nuit de l'écran Sommeil : choix de la nuit à
//  venir (`SleepTonight`, pur), état du view-model (`SommeilViewModel`) avec un
//  backend local FACTICE (aucun réseau, aucune donnée réelle) : pas de doublon
//  quand la date affichée est la nuit à venir, pas de valeur périmée au
//  changement de date, repli sur l'idéal global après un échec. Données
//  SYNTHÉTIQUES uniquement.
//

import Testing
import Foundation
@testable import all

// MARK: - Fixtures

private func calendar(_ tz: String = "UTC") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    return c
}

/// Date locale (calendrier `cal`) — heure murale `h:m`.
private func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ m: Int = 0, cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: m))!
}

private func recoJSON(
    nightDate: String? = nil, nightIdeal: Double? = nil,
    workday: String? = "07:00", freeDay: String? = "09:00", waketime: String? = "07:30"
) -> String {
    var fields = ["\"nights\": 40", "\"status\": \"ok\"", "\"targetHours\": 8.0", "\"idealHours\": 8.0",
                  "\"latencyMin\": 0", "\"avgAwakeMin\": 0", "\"recommendedBedtime\": \"23:00\""]
    if let workday { fields.append("\"waketimeWorkday\": \"\(workday)\"") }
    if let freeDay { fields.append("\"waketimeFreeDay\": \"\(freeDay)\"") }
    if let waketime { fields.append("\"waketime\": \"\(waketime)\"") }
    if let nightDate { fields.append("\"nightDate\": \"\(nightDate)\"") }
    if let nightIdeal { fields.append("\"nightIdealHours\": \(nightIdeal)") }
    return "{" + fields.joined(separator: ",") + "}"
}

private func decodeReco(_ json: String) throws -> DashboardSleepRecommendation {
    try PulseAPIClient.decoder.decode(DashboardSleepRecommendation.self, from: Data(json.utf8))
}

// MARK: - Choix de la nuit à venir (pur)

struct SleepTonightChoiceTests {
    private func night(_ now: Date, cal: Calendar = calendar(), alarms: [Int: Int] = [:],
                       reco: DashboardSleepRecommendation? = nil) -> String {
        SleepTonight.upcomingNightDate(now: now, calendar: cal, alarms: alarms, reco: reco)
    }

    // 2026-10-05 = lundi (weekday 2) ; 2026-10-04 = dimanche (1).

    @Test func beforeAlarmIsTodayAfterAlarmIsTomorrow() {
        let cal = calendar()
        let alarms = [2: 7 * 60]  // lundi 07:00
        #expect(night(local(2026, 10, 5, 1, 0, cal: cal), alarms: alarms) == "2026-10-05")
        #expect(night(local(2026, 10, 5, 6, 59, cal: cal), alarms: alarms) == "2026-10-05")
        #expect(night(local(2026, 10, 5, 7, 0, cal: cal), alarms: alarms) == "2026-10-06")
        #expect(night(local(2026, 10, 5, 22, 0, cal: cal), alarms: alarms) == "2026-10-06")
    }

    @Test func todaysAlarmWinsOverUsualWakeTime() throws {
        let cal = calendar()
        let reco = try decodeReco(recoJSON(workday: "07:00"))
        // Alarme lundi 05:00 : à 06:00 elle est passée, alors que le lever habituel (07:00) ne l'est pas.
        #expect(night(local(2026, 10, 5, 6, 0, cal: cal), alarms: [2: 5 * 60], reco: reco) == "2026-10-06")
        // Sans alarme : lever habituel du type de jour (semaine → 07:00).
        #expect(night(local(2026, 10, 5, 6, 0, cal: cal), reco: reco) == "2026-10-05")
    }

    @Test func fallsBackToDayTypeThenGlobalUsualWakeTime() throws {
        let cal = calendar()
        // Dimanche 2026-10-04, 08:00 : lever habituel week-end 09:00 → pas encore passé.
        let withFree = try decodeReco(recoJSON(workday: "07:00", freeDay: "09:00", waketime: "07:30"))
        #expect(night(local(2026, 10, 4, 8, 0, cal: cal), reco: withFree) == "2026-10-04")
        // Lundi 08:00 : lever habituel semaine 07:00 → passé.
        #expect(night(local(2026, 10, 5, 8, 0, cal: cal), reco: withFree) == "2026-10-06")
        // Pas de lever par type de jour : lever global 09:30.
        let globalOnly = try decodeReco(recoJSON(workday: nil, freeDay: nil, waketime: "09:30"))
        #expect(night(local(2026, 10, 5, 9, 0, cal: cal), reco: globalOnly) == "2026-10-05")
        #expect(night(local(2026, 10, 5, 9, 30, cal: cal), reco: globalOnly) == "2026-10-06")
    }

    @Test func withoutAnyWakeInfoItIsTomorrow() throws {
        let cal = calendar()
        #expect(night(local(2026, 10, 5, 1, 0, cal: cal)) == "2026-10-06")
        let none = try decodeReco(recoJSON(workday: nil, freeDay: nil, waketime: nil))
        #expect(night(local(2026, 10, 5, 1, 0, cal: cal), reco: none) == "2026-10-06")
    }

    @Test func midnightCrossing() {
        let cal = calendar()
        let alarms = [2: 7 * 60, 3: 7 * 60]  // lundi et mardi 07:00
        // Lundi 23:59 → nuit de mardi ; mardi 00:00 → toujours la nuit de mardi (réveil à venir).
        #expect(night(local(2026, 10, 5, 23, 59, cal: cal), alarms: alarms) == "2026-10-06")
        #expect(night(local(2026, 10, 6, 0, 0, cal: cal), alarms: alarms) == "2026-10-06")
        // Fin de mois : le lendemain de 31/10 est le 01/11.
        #expect(night(local(2026, 10, 31, 22, 0, cal: cal), alarms: [:], reco: nil) == "2026-11-01")
    }

    @Test func dstChangesDoNotShiftTheChoice() {
        let paris = calendar("Europe/Paris")
        let sundayAlarm = [1: 7 * 60]
        // Fin d'heure d'été : dimanche 2026-10-25, 03:00 → 02:00 (journée de 25 h).
        #expect(night(local(2026, 10, 25, 1, 30, cal: paris), cal: paris, alarms: sundayAlarm) == "2026-10-25")
        #expect(night(local(2026, 10, 25, 6, 59, cal: paris), cal: paris, alarms: sundayAlarm) == "2026-10-25")
        #expect(night(local(2026, 10, 25, 7, 0, cal: paris), cal: paris, alarms: sundayAlarm) == "2026-10-26")
        // Début d'heure d'été : dimanche 2026-03-29, 02:00 → 03:00 (journée de 23 h).
        #expect(night(local(2026, 3, 29, 3, 30, cal: paris), cal: paris, alarms: sundayAlarm) == "2026-03-29")
        #expect(night(local(2026, 3, 29, 8, 0, cal: paris), cal: paris, alarms: sundayAlarm) == "2026-03-30")
    }
}

// MARK: - Backend factice

/// Backend local factice : répond à `sleep-recommendation` (reco synthétique par
/// date), enregistre les dates demandées, peut RETENIR une réponse (`hold`) puis
/// la libérer, ou échouer (`fail`). Toute autre route échoue.
private final class FakeRecoBackend: LocalPulseBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var requestedDates: [String] = []
    private var held: Set<String> = []
    private var failing: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    var requested: [String] { lock.withLock { requestedDates } }
    func hold(_ date: String) { lock.withLock { _ = held.insert(date) } }
    func fail(_ date: String) { lock.withLock { _ = failing.insert(date) } }
    func release(_ date: String) {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            held.remove(date)
            return waiting.removeValue(forKey: date) ?? []
        }
        continuations.forEach { $0.resume() }
    }

    func handle(method: String, path: String, query: [String: String], body: Data?) async throws -> Data {
        guard path == "api/stats/sleep-recommendation", let date = query["date"] else {
            throw LocalPulseUnavailableError()
        }
        lock.withLock { requestedDates.append(date) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed: Bool = lock.withLock {
                if held.contains(date) {
                    waiting[date, default: []].append(continuation)
                    return false
                }
                return true
            }
            if proceed { continuation.resume() }
        }
        if lock.withLock({ failing.contains(date) }) { throw LocalPulseUnavailableError() }
        return Data(recoJSON(nightDate: date, nightIdeal: 7.5).utf8)
    }
}

/// Horloge modifiable pour les tests.
private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<500 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func makeVM(
    _ backend: FakeRecoBackend, clock: Clock, alarms: [Int: Int] = [:]
) -> SommeilViewModel {
    let client = PulseAPIClient(baseURLProvider: { nil }, localBackend: backend, modeProvider: { .phone })
    return SommeilViewModel(client: client, now: { clock.now }, calendar: { calendar() }, alarms: { alarms })
}

// MARK: - Carte « Ce soir » (view-model)

@MainActor
struct SommeilTonightViewModelTests {
    /// Lundi 2026-10-05, 12:00 UTC.
    private let noon = Clock(local(2026, 10, 5, 12, cal: calendar()))

    @Test func tonightLoadsForTomorrowAndIgnoresSelectedDate() async {
        let backend = FakeRecoBackend()
        let vm = makeVM(backend, clock: noon)
        #expect(vm.tonightCard == .placeholder)
        await vm.refreshTonight()
        #expect(vm.tonightDate == "2026-10-06")
        #expect(backend.requested == ["2026-10-06"])
        // Mardi (semaine) : réveil 07:00 (lever habituel), durée idéale de CETTE nuit 7,5 h → 23:30.
        guard case .plan(let plan) = vm.tonightCard else { Issue.record("pas de plan"); return }
        #expect(plan.bedtime == "23:30")
        #expect(plan.wakeMinutes == 7 * 60)
        #expect(plan.isNightSpecific)

        // Naviguer ailleurs ne touche ni la date ni la reco de « Ce soir ».
        await vm.selectDate("2026-10-01")
        await waitUntil { backend.requested.contains("2026-10-01") }
        await waitUntil { vm.nightReco != .loading }
        #expect(vm.tonightDate == "2026-10-06")
        guard case .plan(let after) = vm.tonightCard else { Issue.record("pas de plan"); return }
        #expect(after == plan)
    }

    @Test func alarmOfTheTargetDayIsTheWakeTimeShown() async {
        let backend = FakeRecoBackend()
        // Alarme mardi (3) 06:15.
        let vm = makeVM(backend, clock: noon, alarms: [3: 6 * 60 + 15])
        await vm.refreshTonight()
        guard case .plan(let plan) = vm.tonightCard else { Issue.record("pas de plan"); return }
        #expect(plan.wakeMinutes == 6 * 60 + 15)
        #expect(plan.bedtime == "22:45")  // 06:15 − 7 h 30
    }

    @Test func afterMidnightTargetsTodayAndRefinesOnceTheRecoIsKnown() async {
        // Mardi 2026-10-06, 01:00, sans alarme : le premier choix (reco inconnue) est
        // demain ; le lever habituel reçu (07:00) ramène à aujourd'hui → 2ᵉ requête.
        let backend = FakeRecoBackend()
        let vm = makeVM(backend, clock: Clock(local(2026, 10, 6, 1, cal: calendar())))
        await vm.refreshTonight()
        #expect(backend.requested == ["2026-10-07", "2026-10-06"])
        #expect(vm.tonightDate == "2026-10-06")
        guard case .plan(let plan) = vm.tonightCard else { Issue.record("pas de plan"); return }
        #expect(plan.bedtime == "23:30")
        #expect(plan.isNightSpecific)
    }

    @Test func noDuplicateWhenDisplayedDateIsTheUpcomingNight() async {
        // 01:00 mardi : la date affichée par défaut est aujourd'hui = la nuit à venir.
        let backend = FakeRecoBackend()
        let vm = makeVM(backend, clock: Clock(local(2026, 10, 6, 1, cal: calendar())))
        await vm.refreshTonight()
        #expect(vm.date == vm.tonightDate)
        #expect(vm.nightCard == .hidden)
        // Une autre date affiche bien sa carte (une fois chargée).
        await vm.selectDate("2026-10-05")
        await waitUntil { vm.nightReco != .loading }
        if case .plan = vm.nightCard {} else { Issue.record("carte par nuit attendue") }
    }

    @Test func tonightChangesWhenTheWakeTimePasses() async {
        let backend = FakeRecoBackend()
        let clock = Clock(local(2026, 10, 5, 6, 0, cal: calendar()))
        let vm = makeVM(backend, clock: clock, alarms: [2: 7 * 60])  // lundi 07:00
        await vm.refreshTonight()
        #expect(vm.tonightDate == "2026-10-05")
        let count = backend.requested.count

        // Même nuit visée : pas de nouvelle requête.
        await vm.refreshTonight(force: false)
        #expect(backend.requested.count == count)

        // 07:30 : le réveil est passé → nuit de demain, rechargée.
        clock.now = local(2026, 10, 5, 7, 30, cal: calendar())
        await vm.refreshTonight(force: false)
        #expect(vm.tonightDate == "2026-10-06")
        #expect(backend.requested.last == "2026-10-06")
        if case .plan = vm.tonightCard {} else { Issue.record("plan attendu") }
    }

    @Test func tonightShowsPlaceholderWhileANewNightLoads() async {
        let backend = FakeRecoBackend()
        let clock = Clock(local(2026, 10, 5, 6, 0, cal: calendar()))
        let vm = makeVM(backend, clock: clock, alarms: [2: 7 * 60])
        await vm.refreshTonight()
        backend.hold("2026-10-06")
        clock.now = local(2026, 10, 5, 8, 0, cal: calendar())
        let task = Task { await vm.refreshTonight(force: false) }
        await waitUntil { backend.requested.last == "2026-10-06" }
        #expect(vm.tonightCard == .placeholder)  // jamais l'heure de la nuit d'avant
        backend.release("2026-10-06")
        await task.value
        if case .plan = vm.tonightCard {} else { Issue.record("plan attendu") }
    }

    @Test func failureWithoutFallbackIsUnavailable() async {
        let backend = FakeRecoBackend()
        backend.fail("2026-10-06")
        let vm = makeVM(backend, clock: noon)
        await vm.refreshTonight()
        #expect(vm.tonightCard == .unavailable)
    }
}

// MARK: - Carte par nuit (view-model)

@MainActor
struct SommeilNightCardViewModelTests {
    private let noon = Clock(local(2026, 10, 5, 12, cal: calendar()))

    @Test func placeholderWhileTheDateLoadsNeverTheStaleValue() async {
        let backend = FakeRecoBackend()
        let vm = makeVM(backend, clock: noon)
        await vm.refreshTonight()

        await vm.selectDate("2026-10-03")
        await waitUntil { vm.nightReco != .loading }
        guard case .plan(let first) = vm.nightCard else { Issue.record("plan attendu"); return }
        #expect(first.isNightSpecific)

        // Date suivante retenue : la carte ne montre PAS l'heure de 10-03.
        backend.hold("2026-10-02")
        await vm.selectDate("2026-10-02")
        await waitUntil { backend.requested.contains("2026-10-02") }
        #expect(vm.nightCard == .placeholder)

        backend.release("2026-10-02")
        await waitUntil { vm.nightReco != .loading }
        guard case .plan(let second) = vm.nightCard else { Issue.record("plan attendu"); return }
        #expect(second.isNightSpecific)
        #expect(second.bedtime == "23:30")
    }

    @Test func failureFallsBackToGlobalIdealOnceKnown() async {
        let backend = FakeRecoBackend()
        let vm = makeVM(backend, clock: noon)
        await vm.refreshTonight()  // reco de repli (idéal global 8 h)

        // Jeudi 2026-10-01 (semaine, lever 07:00).
        backend.hold("2026-10-01")
        backend.fail("2026-10-01")
        await vm.selectDate("2026-10-01")
        await waitUntil { backend.requested.contains("2026-10-01") }
        #expect(vm.nightCard == .placeholder)  // échec pas encore connu

        backend.release("2026-10-01")
        await waitUntil { vm.nightReco != .loading }
        #expect(vm.nightReco == .failed)
        guard case .plan(let plan) = vm.nightCard else { Issue.record("repli attendu"); return }
        #expect(!plan.isNightSpecific)
        #expect(plan.idealHours == 8.0)
        #expect(plan.bedtime == "23:00")  // 07:00 − 8 h
    }

    @Test func failureWithoutAnyFallbackHidesTheCard() async {
        let backend = FakeRecoBackend()
        backend.fail("2026-10-06")
        backend.fail("2026-10-01")
        let vm = makeVM(backend, clock: noon)
        await vm.refreshTonight()
        await vm.selectDate("2026-10-01")
        await waitUntil { vm.nightReco != .loading }
        #expect(vm.nightCard == .hidden)
    }

    @Test func lateResponseOfAPreviousDateIsIgnored() async {
        let backend = FakeRecoBackend()
        let vm = makeVM(backend, clock: noon)
        await vm.refreshTonight()

        backend.hold("2026-10-02")
        await vm.selectDate("2026-10-02")
        await waitUntil { backend.requested.contains("2026-10-02") }
        await vm.selectDate("2026-10-03")
        await waitUntil { vm.nightReco != .loading }
        #expect(vm.date == "2026-10-03")

        backend.release("2026-10-02")
        try? await Task.sleep(for: .milliseconds(100))
        guard case .ready(let reco) = vm.nightReco else { Issue.record("reco attendue"); return }
        #expect(reco.nightDate == "2026-10-03")
    }
}
