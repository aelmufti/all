//
//  ReloadKeepsContentTests.swift
//  allTests
//
//  Règle « garder l'ancien pendant qu'on rafraîchit » (audit des chargements
//  répétés) : un rechargement d'un écran déjà rempli garde son contenu, un
//  rechargement en échec ne le vide pas, les déclencheurs rapprochés sont
//  fusionnés (`ReloadGate`), un changement de date ne montre jamais les données
//  de l'ancienne date et une réponse périmée ne remplace pas la plus récente.
//  Tests au niveau view-model avec un backend local FACTICE (aucun réseau, aucune
//  donnée réelle, données SYNTHÉTIQUES). Le Sommeil a ses propres cas dans
//  `SommeilTonightTests.swift`.
//

import Testing
import Foundation
@testable import all

// MARK: - Backend scripté

/// Backend factice générique : réponses JSON par chemin, échecs à la demande,
/// réponses retenues (`hold`) puis libérées, compteur de requêtes par chemin.
final class ScriptedBackend: LocalPulseBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String: String] = [:]
    private var failing: Set<String> = []
    private var held: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var counts: [String: Int] = [:]

    func set(_ path: String, _ json: String) { lock.withLock { bodies[path] = json; failing.remove(path) } }
    func fail(_ path: String) { lock.withLock { _ = failing.insert(path) } }
    func hold(_ path: String) { lock.withLock { _ = held.insert(path) } }
    func count(_ path: String) -> Int { lock.withLock { counts[path] ?? 0 } }
    func release(_ path: String) {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            held.remove(path)
            return waiting.removeValue(forKey: path) ?? []
        }
        continuations.forEach { $0.resume() }
    }

    func handle(method: String, path: String, query: [String: String], body: Data?) async throws -> Data {
        lock.withLock { counts[path, default: 0] += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed: Bool = lock.withLock {
                if held.contains(path) {
                    waiting[path, default: []].append(continuation)
                    return false
                }
                return true
            }
            if proceed { continuation.resume() }
        }
        let outcome: String? = lock.withLock { failing.contains(path) ? nil : bodies[path] }
        guard let outcome else { throw LocalPulseUnavailableError() }
        return Data(outcome.utf8)
    }
}

private func scriptedClient(_ backend: ScriptedBackend) -> PulseAPIClient {
    PulseAPIClient(baseURLProvider: { nil }, localBackend: backend, modeProvider: { .phone })
}

/// Mode de stockage pilotable depuis le test (relu à chaque chargement par les
/// view models, jamais capturé) — évite de muter `StorageModeStore.shared`
/// (`UserDefaults.standard`, partagé par tout le process de test).
final class ModeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: StorageMode
    init(_ mode: StorageMode) { current = mode }
    var mode: StorageMode {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<500 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - ReloadGate

@MainActor
private final class Latch {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func openUp() {
        open = true
        continuations.forEach { $0.resume() }
        continuations = []
    }
}

@MainActor
struct ReloadGateTests {
    /// Compte les exécutions et la concurrence maximale observée.
    @MainActor
    private final class Probe {
        var runs = 0
        var inFlight = 0
        var maxInFlight = 0
        let latch = Latch()
        func operation() async {
            runs += 1
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            await latch.wait()
            inFlight -= 1
        }
    }

    @Test func triggersDuringARunJoinIt() async {
        let gate = ReloadGate()
        let probe = Probe()
        let a = Task { await gate.run { await probe.operation() } }
        await waitUntil { probe.runs == 1 }
        let b = Task { await gate.run { await probe.operation() } }
        let c = Task { await gate.run { await probe.operation() } }
        try? await Task.sleep(for: .milliseconds(30))
        probe.latch.openUp()
        await a.value; await b.value; await c.value
        #expect(probe.runs == 1)
        #expect(probe.maxInFlight == 1)
        #expect(!gate.isRunning)
    }

    @Test func trailingRequestsReplayExactlyOnceAndNeverInParallel() async {
        let gate = ReloadGate()
        let probe = Probe()
        let a = Task { await gate.run { await probe.operation() } }
        await waitUntil { probe.runs == 1 }
        let b = Task { await gate.run(trailing: true) { await probe.operation() } }
        let c = Task { await gate.run(trailing: true) { await probe.operation() } }
        try? await Task.sleep(for: .milliseconds(30))
        probe.latch.openUp()
        await a.value; await b.value; await c.value
        #expect(probe.runs == 2)
        #expect(probe.maxInFlight == 1)
    }

    @Test func callerWaitsForTheEndOfTheReload() async {
        let gate = ReloadGate()
        let probe = Probe()
        var finished = false
        let a = Task { await gate.run { await probe.operation() }; finished = true }
        await waitUntil { probe.runs == 1 }
        #expect(!finished)  // un `.refreshable` attend la vraie fin
        probe.latch.openUp()
        await a.value
        #expect(finished)
    }

    @Test func aNewRunStartsOnceTheGateIsIdle() async {
        let gate = ReloadGate()
        let probe = Probe()
        probe.latch.openUp()
        await gate.run { await probe.operation() }
        await gate.run { await probe.operation() }
        #expect(probe.runs == 2)
    }
}

/// Façade de test vers la règle (statique, interne) du modificateur privé.
enum DayRolloverProbe {
    static func should(_ last: Date?, _ now: Date, _ cal: Calendar) -> Bool {
        foregroundReloadDecision(lastFired: last, now: now, calendar: cal)
    }
}

struct ForegroundThrottleTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ d: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m, second: s))!
    }

    @Test func shortBackgroundTripsDoNotReloadEveryScreen() {
        let last = date(5, 12, 0)
        #expect(!DayRolloverProbe.should(last, date(5, 12, 0, 10), cal))
        #expect(DayRolloverProbe.should(last, date(5, 12, 1), cal))
    }

    @Test func aNewDayAlwaysReloads() {
        #expect(DayRolloverProbe.should(date(5, 23, 59, 50), date(6, 0, 0, 5), cal))
    }

    @Test func neverFiredYetReloads() {
        #expect(DayRolloverProbe.should(nil, date(5, 12, 0), cal))
    }
}

// MARK: - Santé

@MainActor
struct HealthReloadTests {
    private let today = HealthViewModel.todayKey()

    private func key(daysBefore n: Int) -> String {
        HealthViewModel.formatDate(HealthViewModel.parseDate(today)!.addingTimeInterval(TimeInterval(-n) * 86_400))
    }

    private func dayJSON(_ date: String) -> String {
        """
        {"date":"\(date)","summary":{},"hr":[],"stress":[],"spo2":[],"respiration":[],
         "bodyBatteryPivot":[],"activities":[],
         "sleep":{"segments":[],"main":null,"stages":[],"score":null}}
        """
    }

    private let intensityJSON = """
        {"date":"x","minutes":10,"moderateMin":10,"vigorousMin":0,"coverage":0.9,"elapsed":1000,"bouts":[],
         "params":{"maxHeartRate":190,"moderateBpm":120,"vigorousBpm":150,"moderatePct":0.6,"vigorousPct":0.8,
         "minBoutS":600,"maxGapS":60,"dipToleranceS":30,"minCoverage":0.8,"source":"x","measuredAt":null,
         "hrCalcType":null,"restingHeartRate":55,"restingSource":"y"}}
        """

    private func make() -> (HealthViewModel, ScriptedBackend) {
        let backend = ScriptedBackend()
        backend.set("api/wellness/days", "[{\"date\":\"\(key(daysBefore: 1))\"},{\"date\":\"\(today)\"}]")
        for n in 0...3 {
            let d = key(daysBefore: n)
            backend.set("api/wellness/day/\(d)", dayJSON(d))
            backend.set("api/wellness/intensity/day/\(d)", intensityJSON)
        }
        return (HealthViewModel(client: scriptedClient(backend)), backend)
    }

    @Test func reloadKeepsTheDayUntilTheResponseArrives() async {
        let (vm, backend) = make()
        await vm.load()
        #expect(vm.hasContent && vm.day?.date == today)

        backend.hold("api/wellness/day/\(today)")
        let task = Task { await vm.reload() }
        await waitUntil { backend.count("api/wellness/day/\(today)") == 2 }
        #expect(vm.hasContent)
        #expect(vm.day?.date == today)
        #expect(vm.intensity != nil)
        #expect(!vm.isDayLoading)
        backend.release("api/wellness/day/\(today)")
        await task.value
        #expect(vm.day?.date == today)
    }

    @Test func failedReloadKeepsTheScreenAndIntensity() async {
        let (vm, backend) = make()
        await vm.load()
        #expect(vm.intensity != nil)

        backend.fail("api/wellness/days")
        await vm.reload()
        #expect(vm.hasContent && vm.day != nil)
        #expect(vm.errorMessage != nil)

        backend.set("api/wellness/days", "[{\"date\":\"\(today)\"}]")
        backend.fail("api/wellness/intensity/day/\(today)")
        await vm.reload()
        #expect(vm.intensity != nil)
        #expect(!vm.intensityFailed)  // un échec de rechargement garde l'intensité affichée
    }

    @Test func firstLoadFailureShowsNoContent() async {
        let backend = ScriptedBackend()
        backend.fail("api/wellness/days")
        let vm = HealthViewModel(client: scriptedClient(backend))
        await vm.load()
        #expect(!vm.hasContent)
        #expect(vm.errorMessage != nil)
    }

    @Test func closeTriggersAreMerged() async {
        let (vm, backend) = make()
        await vm.load()
        backend.hold("api/wellness/days")
        let a = Task { await vm.reload() }
        await waitUntil { backend.count("api/wellness/days") == 2 }
        let b = Task { await vm.reload() }
        let c = Task { await vm.reloadForNewDay() }
        try? await Task.sleep(for: .milliseconds(30))
        backend.release("api/wellness/days")
        await a.value; await b.value; await c.value
        #expect(backend.count("api/wellness/days") == 2)
    }

    @Test func changingDateNeverShowsTheOldDate() async {
        let (vm, backend) = make()
        await vm.load()
        let yesterday = key(daysBefore: 1)

        backend.hold("api/wellness/day/\(yesterday)")
        let task = Task { await vm.shiftDay(by: -1) }
        await waitUntil { backend.count("api/wellness/day/\(yesterday)") == 1 }
        #expect(vm.date == yesterday)
        #expect(vm.day == nil)
        #expect(vm.intensity == nil)
        #expect(vm.isDayLoading)
        #expect(vm.hasContent)  // la page garde sa structure (emplacements réservés)
        backend.release("api/wellness/day/\(yesterday)")
        await task.value
        #expect(vm.day?.date == yesterday)
        #expect(!vm.isDayLoading)
    }

    @Test func lateResponseOfAQuittedDateIsIgnored() async {
        let (vm, backend) = make()
        await vm.load()
        let yesterday = key(daysBefore: 1)
        let before = key(daysBefore: 2)

        backend.hold("api/wellness/day/\(yesterday)")
        let slow = Task { await vm.selectDate(yesterday) }
        await waitUntil { backend.count("api/wellness/day/\(yesterday)") == 1 }
        await vm.selectDate(before)
        #expect(vm.day?.date == before)
        backend.release("api/wellness/day/\(yesterday)")
        await slow.value
        try? await Task.sleep(for: .milliseconds(30))
        #expect(vm.day?.date == before)
        #expect(vm.date == before)
    }

    @Test func reloadDoesNotBringAPastDayBackToToday() async {
        let (vm, _) = make()
        await vm.load()
        await vm.shiftDay(by: -1)
        let yesterday = key(daysBefore: 1)
        await vm.reload()
        #expect(vm.date == yesterday)
        #expect(vm.day?.date == yesterday)
        // Sur « aujourd'hui », en revanche, on suit le jour courant.
        await vm.shiftDay(by: 1)
        await vm.reload()
        #expect(vm.date == today)
    }
}

// MARK: - Activités

@MainActor
struct ActivitiesReloadTests {
    private func items(_ vm: ActivitiesViewModel) -> [Activity]? {
        if case .loaded(let list) = vm.state { return list }
        return nil
    }

    private func make() -> (ActivitiesViewModel, ScriptedBackend) {
        let backend = ScriptedBackend()
        backend.set("api/activities", #"{"total":1,"items":[{"id":1,"fileName":"a.fit"}]}"#)
        return (ActivitiesViewModel(client: scriptedClient(backend)), backend)
    }

    @Test func reloadKeepsTheListVisible() async {
        let (vm, backend) = make()
        await vm.load()
        #expect(items(vm)?.count == 1)

        backend.hold("api/activities")
        backend.set("api/activities", #"{"total":2,"items":[{"id":1,"fileName":"a.fit"},{"id":2,"fileName":"b.fit"}]}"#)
        backend.hold("api/activities")
        let task = Task { await vm.reload() }
        await waitUntil { backend.count("api/activities") == 2 }
        #expect(items(vm)?.count == 1)  // jamais .loading : la liste reste
        backend.release("api/activities")
        await task.value
        #expect(items(vm)?.count == 2)
    }

    @Test func failedReloadKeepsTheList() async {
        let (vm, backend) = make()
        await vm.load()
        backend.fail("api/activities")
        await vm.reload()
        #expect(items(vm)?.count == 1)
    }

    @Test func firstLoadFailureIsAFullScreenError() async {
        let backend = ScriptedBackend()
        backend.fail("api/activities")
        let vm = ActivitiesViewModel(client: scriptedClient(backend))
        await vm.load()
        if case .failed = vm.state {} else { Issue.record("échec plein écran attendu") }
    }

    @Test func triggersAreMergedAndSyncReplaysOnce() async {
        let (vm, backend) = make()
        await vm.load()
        backend.hold("api/activities")
        let a = Task { await vm.reload() }
        await waitUntil { backend.count("api/activities") == 2 }
        let b = Task { await vm.reload() }
        let c = Task { await vm.reload() }
        try? await Task.sleep(for: .milliseconds(30))
        backend.release("api/activities")
        await a.value; await b.value; await c.value
        #expect(backend.count("api/activities") == 2)

        backend.hold("api/activities")
        let d = Task { await vm.reload() }
        await waitUntil { backend.count("api/activities") == 3 }
        let e = Task { await vm.reload(trailing: true) }
        let f = Task { await vm.reload(trailing: true) }
        try? await Task.sleep(for: .milliseconds(30))
        backend.release("api/activities")
        await d.value; await e.value; await f.value
        #expect(backend.count("api/activities") == 4)
    }
}

// MARK: - Accueil

@MainActor
struct HomeReloadTests {
    private let dayJSON = """
        {"date":"x","summary":{},"hr":[],"stress":[],"spo2":[],"respiration":[],
         "sleep":{"main":null,"stages":[],"score":null}}
        """

    private func make() -> (HomeViewModel, ScriptedBackend) {
        let backend = ScriptedBackend()
        backend.set("api/wellness/day/\(HomeViewModel.todayKey())", dayJSON)
        backend.set("api/activities", #"{"total":0,"items":[]}"#)
        // Mode fixe : ces tests ne dépendent pas du réglage global de l'appareil.
        return (HomeViewModel(client: scriptedClient(backend), modeProvider: { .phone }), backend)
    }

    private func isLoaded(_ vm: HomeViewModel) -> Bool {
        if case .loaded = vm.state { return true }
        return false
    }

    @Test func reloadKeepsTheHomeLoaded() async {
        let (vm, backend) = make()
        await vm.load()
        #expect(isLoaded(vm))

        let path = "api/wellness/day/\(HomeViewModel.todayKey())"
        backend.hold(path)
        let task = Task { await vm.reload() }
        await waitUntil { backend.count(path) == 2 }
        #expect(isLoaded(vm))  // jamais le plein écran de chargement
        backend.release(path)
        await task.value
        #expect(isLoaded(vm))
    }

    @Test func failedReloadKeepsTheHome() async {
        let (vm, backend) = make()
        await vm.load()
        backend.fail("api/activities")
        await vm.reload()
        #expect(isLoaded(vm))
        #expect(vm.day != nil)
    }

    @Test func firstLoadFailureIsAFullScreenError() async {
        let backend = ScriptedBackend()
        let vm = HomeViewModel(client: scriptedClient(backend), modeProvider: { .phone })
        await vm.load()
        if case .failed = vm.state {} else { Issue.record("échec plein écran attendu") }
    }

    /// Source changée puis échec : l'ancienne source ne reste pas à l'écran comme
    /// si c'était la nouvelle (plein écran d'erreur, contenu vidé) — et le réessai
    /// voit toujours le changement tant qu'aucun chargement n'a abouti.
    @Test func failedReloadAfterASourceChangeDoesNotKeepTheOldSource() async {
        let box = ModeBox(.pulse)
        let backend = ScriptedBackend()
        backend.set("api/wellness/day/\(HomeViewModel.todayKey())", dayJSON)
        backend.set("api/activities", #"{"total":0,"items":[]}"#)
        let vm = HomeViewModel(client: scriptedClient(backend), modeProvider: { box.mode })
        await vm.load()
        #expect(isLoaded(vm) && vm.day != nil)

        box.mode = .phone
        backend.fail("api/activities")
        await vm.reload()
        if case .failed = vm.state {} else { Issue.record("échec plein écran attendu après changement de source") }
        #expect(vm.day == nil)

        // Un second échec : `loadedMode` n'a pas été avancé, la source est toujours « changée ».
        await vm.reload()
        if case .failed = vm.state {} else { Issue.record("le réessai doit toujours voir le changement de source") }

        backend.set("api/activities", #"{"total":0,"items":[]}"#)
        await vm.reload()
        #expect(isLoaded(vm) && vm.day != nil)

        // Source désormais alignée : un échec garde le contenu comme avant.
        backend.fail("api/activities")
        await vm.reload()
        #expect(isLoaded(vm) && vm.day != nil)
    }

    @Test func triggersAreMerged() async {
        let (vm, backend) = make()
        await vm.load()
        backend.hold("api/activities")
        let a = Task { await vm.reload() }
        await waitUntil { backend.count("api/activities") == 2 }
        let b = Task { await vm.reload() }
        let c = Task { await vm.reload() }
        try? await Task.sleep(for: .milliseconds(30))
        backend.release("api/activities")
        await a.value; await b.value; await c.value
        #expect(backend.count("api/activities") == 2)
    }
}

// MARK: - Programme

@MainActor
struct ProgrammeReloadTests {
    private func make() -> (ProgrammeViewModel, ScriptedBackend) {
        let backend = ScriptedBackend()
        backend.set("api/programme", #"{"date":"2026-10-05","domains":[]}"#)
        return (ProgrammeViewModel(client: scriptedClient(backend)), backend)
    }

    private func isLoaded(_ vm: ProgrammeViewModel) -> Bool {
        if case .loaded = vm.state { return true }
        return false
    }

    @Test func reloadKeepsTheContentAndFailureIsDiscreet() async {
        let (vm, backend) = make()
        await vm.load()
        #expect(isLoaded(vm))

        backend.hold("api/programme")
        let task = Task { await vm.reload() }
        await waitUntil { backend.count("api/programme") == 2 }
        #expect(isLoaded(vm))
        backend.release("api/programme")
        await task.value

        backend.fail("api/programme")
        await vm.reload()
        #expect(isLoaded(vm))
        #expect(vm.actionError != nil)
        #expect(vm.current != nil)
    }

    @Test func failedActionKeepsTheScreenInsteadOfReplacingItByAnError() async {
        let (vm, _) = make()
        await vm.load()
        await vm.activate(programmeId: "p", days: [1])  // `api/programme/activate` non scripté → échec
        #expect(isLoaded(vm))
        #expect(vm.actionError != nil)
        #expect(vm.current != nil)
    }

    @Test func firstLoadFailureIsAFullScreenError() async {
        let backend = ScriptedBackend()
        let vm = ProgrammeViewModel(client: scriptedClient(backend))
        await vm.load()
        if case .failed = vm.state {} else { Issue.record("échec plein écran attendu") }
    }
}

// MARK: - Nutrition

@MainActor
struct NutritionReloadTests {
    private func dayJSON(_ date: String) -> String {
        """
        {"date":"\(date)","entries":[],
         "totals":{"kcal":0,"protein":0,"carbs":0,"fat":0,"fiber":0},
         "targets":{"kcal":2100,"protein":null,"carbs":null,"fat":null,"fiber":20},
         "targetRanges":null,"programme":null,
         "remaining":{"kcal":2100,"protein":null,"carbs":null,"fat":null,"fiber":20},"proteinPerKg":null}
        """
    }

    private let targetJSON = """
        {"date":"x","mode":"auto",
         "manual":{"kcal":1800,"protein":null,"carbs":null,"fat":null,"fiber":null},
         "manualMin":{"kcal":null,"protein":null,"carbs":null,"fat":null,"fiber":null},
         "manualMax":{"kcal":null,"protein":null,"carbs":null,"fat":null,"fiber":null},
         "programme":null,
         "targets":{"kcal":1800,"protein":null,"carbs":null,"fat":null,"fiber":null},
         "source":"manual",
         "auto":{"status":"unavailable","source":"formula","missing":["weightKg"],
           "targetKcal":null,"expenditureKcal":null,"deficitKcal":null,
           "macros":{"proteinG":null,"fatG":null,"carbsG":null,"fiberG":null,"proteinPerKg":null,
             "basePerKg":1.9,"bonuses":[],"proteinCapped":false,"proteinCutFloor":false,
             "proteinPerMealG":null,"proteinIntakes":null,"fatFloorG":null,
             "fatFromFloor":false,"fatCutForCarbs":false,"carbsFloorG":null,
             "carbsBelowFloor":false,"shares":null,"programme":null},
           "guard":"none",
           "detail":{"restingKcal":null,"watchActiveKcal":null,"sessionKcal":0,"activeKcal":null,"sessions":[]}},
         "settings":{"weeklyLossPct":0.7,"deficitKcal":500,"sportFactor":1,
           "proteinPerKg":1.9,"floorKcal":1500,"weeklyAlertKcal":600}}
        """

    private let weeklyJSON = """
        {"days":[],"loggedDays":5,"partialDays":1,"emptyDays":1,"avgDeficitKcal":420,
         "avgIntakeKcal":2100,"avgExpenditureKcal":2520,"alert":false,"thresholdKcal":600}
        """

    private let suggestionsJSON = """
        {"remaining":{"kcal":null,"protein":null,"carbs":null,"fat":null,"fiber":null},"items":[],"reason":"no-targets"}
        """

    private func script(_ backend: ScriptedBackend, date: String) {
        backend.set("api/nutrition/day/\(date)", dayJSON(date))
        backend.set("api/nutrition/targets", targetJSON)
        backend.set("api/nutrition/weekly", weeklyJSON)
        backend.set("api/nutrition/timing/\(date)", #"{"meal":null}"#)
        backend.set("api/nutrition/suggestions/\(date)", suggestionsJSON)
        backend.set("api/nutrition/frequent", "[]")
    }

    private func make(date: String = "2026-10-05") -> (NutritionViewModel, ScriptedBackend) {
        let backend = ScriptedBackend()
        script(backend, date: date)
        return (NutritionViewModel(client: scriptedClient(backend), date: date), backend)
    }

    private func isLoaded(_ vm: NutritionViewModel) -> Bool {
        if case .loaded = vm.state { return true }
        return false
    }

    @Test func reloadKeepsTheContentAndFailureIsDiscreet() async {
        let (vm, backend) = make()
        await vm.load()
        #expect(isLoaded(vm) && vm.day != nil)

        backend.hold("api/nutrition/weekly")
        let task = Task { await vm.reload() }
        await waitUntil { backend.count("api/nutrition/weekly") == 2 }
        #expect(isLoaded(vm))
        #expect(vm.day != nil)
        #expect(!vm.isDateLoading)
        backend.release("api/nutrition/weekly")
        await task.value

        backend.fail("api/nutrition/weekly")
        await vm.reload()
        #expect(isLoaded(vm))
        #expect(vm.day != nil)
        #expect(vm.actionError != nil)
    }

    @Test func failedWriteKeepsTheScreen() async {
        let (vm, _) = make()
        await vm.load()
        await vm.deleteEntry(1)  // `DELETE api/nutrition/log/1` non scripté → échec
        #expect(isLoaded(vm))
        #expect(vm.day != nil)
        #expect(vm.actionError != nil)
    }

    @Test func changingDateNeverShowsTheOldDate() async {
        let (vm, backend) = make()
        await vm.load()
        script(backend, date: "2026-10-04")

        backend.hold("api/nutrition/weekly")
        vm.shiftDay(by: -1)
        #expect(vm.date == "2026-10-04")
        #expect(vm.day == nil)
        #expect(vm.targetInfo == nil)
        #expect(vm.isDateLoading)
        #expect(isLoaded(vm))  // la page garde sa structure (emplacements réservés)
        await waitUntil { backend.count("api/nutrition/weekly") == 2 }
        backend.release("api/nutrition/weekly")
        await waitUntil { !vm.isDateLoading }
        #expect(vm.day?.date == "2026-10-04")
    }

    @Test func lateResponseOfAQuittedDateIsIgnored() async {
        let (vm, backend) = make()
        await vm.load()
        script(backend, date: "2026-10-04")
        script(backend, date: "2026-10-03")

        backend.hold("api/nutrition/day/2026-10-04")
        vm.shiftDay(by: -1)
        await waitUntil { backend.count("api/nutrition/day/2026-10-04") == 1 }
        vm.shiftDay(by: -1)
        await waitUntil { vm.day?.date == "2026-10-03" }
        backend.release("api/nutrition/day/2026-10-04")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.date == "2026-10-03")
        #expect(vm.day?.date == "2026-10-03")
    }

    /// Changer de jour pendant une suppression : l'opération aboutit, mais sa
    /// relecture (jour d'avant) ne remplace pas l'affichage du jour courant.
    @Test func deleteFinishingAfterADateChangeDoesNotShowTheOldDay() async {
        let (vm, backend) = make()
        await vm.load()
        script(backend, date: "2026-10-04")
        backend.set("api/nutrition/log/1", "{}")

        backend.hold("api/nutrition/day/2026-10-05")
        let operation = Task { await vm.deleteEntry(1) }
        await waitUntil { backend.count("api/nutrition/day/2026-10-05") == 2 }
        vm.shiftDay(by: -1)
        await waitUntil { vm.day?.date == "2026-10-04" }
        backend.release("api/nutrition/day/2026-10-05")
        await operation.value
        try? await Task.sleep(for: .milliseconds(50))

        #expect(backend.count("api/nutrition/log/1") == 1)  // l'écriture a bien eu lieu
        #expect(vm.date == "2026-10-04")
        #expect(vm.day?.date == "2026-10-04")
        #expect(vm.actionError == nil)
        #expect(!vm.isMutating)
    }

    /// Même cas pour l'ajout rapide : la relecture du jour d'avant ne remplace
    /// pas le jour affiché.
    @Test func quickAddFinishingAfterADateChangeDoesNotShowTheOldDay() async {
        let (vm, backend) = make()
        await vm.load()
        script(backend, date: "2026-10-04")
        backend.set("api/nutrition/log", #"{"id":7}"#)

        backend.hold("api/nutrition/day/2026-10-05")
        let food = NutritionFrequentFood(
            foodId: nil, name: "Pomme", uses: 3, grams: 150, units: nil, unitLabel: nil,
            unitGrams: nil, lastTs: nil, kcal: 80, protein: 0.4, carbs: 20, fiber: 3, fat: 0.3)
        let operation = Task { await vm.quickAdd(food) }
        await waitUntil { backend.count("api/nutrition/day/2026-10-05") == 2 }
        vm.shiftDay(by: -1)
        await waitUntil { vm.day?.date == "2026-10-04" }
        backend.release("api/nutrition/day/2026-10-05")
        await operation.value
        try? await Task.sleep(for: .milliseconds(50))

        #expect(backend.count("api/nutrition/log") == 1)
        #expect(vm.date == "2026-10-04")
        #expect(vm.day?.date == "2026-10-04")
        #expect(vm.actionError == nil)
    }

    @Test func triggersAreMerged() async {
        let (vm, backend) = make()
        await vm.load()
        backend.hold("api/nutrition/frequent")
        let a = Task { await vm.reload() }
        await waitUntil { backend.count("api/nutrition/frequent") == 2 }
        let b = Task { await vm.reload() }
        let c = Task { await vm.reload() }
        try? await Task.sleep(for: .milliseconds(30))
        backend.release("api/nutrition/frequent")
        await a.value; await b.value; await c.value
        #expect(backend.count("api/nutrition/frequent") == 2)
    }
}

// MARK: - Stats

@MainActor
struct DashboardSourceChangeTests {
    private let sleepDebtJSON = """
        {"nights":0,"targetHours":7,"debtHours":0,"avgHours":0,"deficitNights":0,"avgInBedHours":0,
         "avgAwakeMin":0,"detail":[]}
        """

    private func script(_ backend: ScriptedBackend) {
        backend.set("api/stats/tab-training", """
            {"days":30,"count":0,"totalS":0,"perWeek":0,"avgHr":null,"activeKcal":0,"deltaPct":null,
             "weeks":[],"shares":[],"streak":{"best":0,"current":0},"zones":[],
             "records":{"longestSession":null,"longestDistance":null,"bestPace":null,"heaviestWeek":null,"maxHr":null}}
            """)
        backend.set("api/stats/tab-health", """
            {"days":30,"restingHr":54,"respiration":null,"spo2Night":null,"stress":null,"weightKg":null,
             "sleepHours":null,"restingSeries":[],"restingDelta":null,"respirationSeries":[],
             "respirationBand":null,"spo2Buckets":[],"spo2Nights":0,"weightSeries":[],"weightDelta":null,
             "correlations":[]}
            """)
        backend.set("api/stats/tab-nutrition", """
            {"days":30,"kcalPerDay":null,"expenditurePerDay":null,"balance":null,"proteinPerDay":null,
             "daysLogged":0,"completeDays":0,"entriesPerDay":0,"series":[],"macros":[],
             "topFoods":[],"totalEntries":0}
            """)
        backend.set("api/stats/sleep-debt", sleepDebtJSON)
        backend.set("api/stats/sleep-insights", """
            {"stressImpact":{"nights":0,"r":null,"significant":false,"buckets":[]},
             "fragmentation":{"nights":0,"avgArousals":0,"avgAwakeMin":0,"avgLongestMin":0,"series":[]},
             "composition":{"nights":0,"deep":0,"light":0,"rem":0,"wasoPct":0,
               "ref":{"deep":{"lo":13,"hi":23},"light":{"lo":45,"hi":62},"rem":{"lo":20,"hi":25}}},
             "spo2Arousal":null}
            """)
        backend.set("api/stats/sleep-regularity", #"{"nights":1,"score":null}"#)
        backend.set("api/wellness/days", "[]")
    }

    /// Source changée puis échec : plus aucune donnée de l'ancienne source (plein
    /// écran d'erreur côté vue, via `hasAnyData`), et le réessai voit toujours le
    /// changement ; une fois la source alignée, un échec garde le contenu.
    @Test func failedLoadAfterASourceChangeDoesNotKeepTheOldSource() async {
        let box = ModeBox(.pulse)
        let backend = ScriptedBackend()
        script(backend)
        let vm = DashboardViewModel(client: scriptedClient(backend), modeProvider: { box.mode })
        await vm.load()
        #expect(vm.state == .loaded && vm.hasAnyData)

        box.mode = .phone
        backend.fail("api/stats/sleep-debt")
        await vm.reload()
        if case .failed = vm.state {} else { Issue.record("échec attendu") }
        #expect(!vm.hasAnyData)  // ni l'ancienne source à l'écran…

        await vm.reload()  // …ni oubli du changement au réessai
        #expect(!vm.hasAnyData)

        backend.set("api/stats/sleep-debt", sleepDebtJSON)
        await vm.reload()
        #expect(vm.state == .loaded && vm.hasAnyData)

        backend.fail("api/stats/sleep-debt")
        await vm.reload()
        #expect(vm.hasAnyData)
        if case .failed = vm.state {} else { Issue.record("échec attendu") }
    }
}
