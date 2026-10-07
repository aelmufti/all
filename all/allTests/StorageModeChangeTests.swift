//
//  StorageModeChangeTests.swift
//  allTests
//
//  Confirmation d'un changement de mode Stockage (`Pulse/Core/StorageModeChange.swift`)
//  et état du bouton de purge (`LocalPurgeModel`). Aucun réseau ni donnée réelle :
//  `UserDefaults` de test, factices pour la purge.
//

import Testing
import Foundation
@testable import all

// MARK: - Confirmation du changement de mode

@MainActor
struct StorageModeChangeTests {
    private func makeStore(_ mode: StorageMode = .phone) -> (store: StorageModeStore, cleanup: () -> Void) {
        let suiteName = "storage-mode-change-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = StorageModeStore(defaults: defaults)
        store.mode = mode
        return (store, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func askingDoesNotChangeTheModeUntilConfirmed() {
        let (store, cleanup) = makeStore(.phone)
        defer { cleanup() }
        let change = StorageModeChangeController(store: store, hasSession: { true })

        change.request(.both)

        #expect(store.mode == .phone, "le sélecteur seul ne change rien")
        #expect(change.pending == .both)

        #expect(change.confirm() == .applied(.both))
        #expect(store.mode == .both)
        #expect(change.pending == nil)
    }

    @Test func cancellingLeavesTheModeUntouched() {
        let (store, cleanup) = makeStore(.pulse)
        defer { cleanup() }
        let change = StorageModeChangeController(store: store, hasSession: { true })

        change.request(.phone)
        change.cancel()

        #expect(store.mode == .pulse)
        #expect(change.pending == nil)
        #expect(change.confirm() == .none, "rien à confirmer après l'annulation")
        #expect(store.mode == .pulse)
    }

    @Test func askingForTheCurrentModeOpensNoConfirmation() {
        let (store, cleanup) = makeStore(.both)
        defer { cleanup() }
        let change = StorageModeChangeController(store: store, hasSession: { true })

        change.request(.both)

        #expect(change.pending == nil)
        #expect(change.confirm() == .none)
    }

    @Test func aLaterRequestReplacesTheEarlierOne() {
        let (store, cleanup) = makeStore(.phone)
        defer { cleanup() }
        let change = StorageModeChangeController(store: store, hasSession: { true })

        change.request(.pulse)
        change.request(.both)

        #expect(change.pending == .both)
        #expect(change.confirm() == .applied(.both))
    }

    /// La connexion à Pulse vient APRÈS la confirmation, et le mode n'est appliqué
    /// qu'une fois connecté (`PulseModeLoginSheet`) : `confirm()` ne l'applique pas.
    @Test func aServerModeWithoutSessionAsksForLoginAfterConfirmationAndAppliesNothing() {
        let (store, cleanup) = makeStore(.phone)
        defer { cleanup() }
        let change = StorageModeChangeController(store: store, hasSession: { false })

        change.request(.pulse)
        #expect(change.confirm() == .needsLogin(.pulse))
        #expect(store.mode == .phone)

        change.request(.both)
        #expect(change.confirm() == .needsLogin(.both))
        #expect(store.mode == .phone)
    }

    @Test func phoneNeverNeedsASession() {
        let (store, cleanup) = makeStore(.pulse)
        defer { cleanup() }
        let change = StorageModeChangeController(store: store, hasSession: { false })

        change.request(.phone)

        #expect(change.confirm() == .applied(.phone))
        #expect(store.mode == .phone)
    }

    @Test func eachModeHasItsOwnShortSingleSentence() {
        let sentences = StorageMode.allCases.map(\.changeConfirmation)
        #expect(Set(sentences).count == StorageMode.allCases.count)
        for sentence in sentences {
            #expect(!sentence.isEmpty)
            #expect(sentence.hasSuffix("."))
            #expect(!sentence.dropLast().contains("."), "une seule phrase : \(sentence)")
            #expect(sentence.count < 130)
        }
        #expect(StorageMode.both.changeConfirmationTitle == "Stockage : Les deux ?")
    }
}

// MARK: - Bouton de purge

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var _runs = 0
    private var _afters = 0
    private var _assessments = 0
    var blockers: [LocalPurgePlanner.Blocker]? = []
    var error: Error?

    var runs: Int { lock.withLock { _runs } }
    var afters: Int { lock.withLock { _afters } }
    var assessments: Int { lock.withLock { _assessments } }
    func assess() -> [LocalPurgePlanner.Blocker]? { lock.withLock { _assessments += 1; return blockers } }
    func run() throws -> LocalDataPurge.Report {
        try lock.withLock {
            _runs += 1
            if let error { throw error }
            // Une fois purgé, plus rien ne bloque.
            blockers = []
            return LocalDataPurge.Report(filesDeleted: 1)
        }
    }
    func after() { lock.withLock { _afters += 1 } }
}

@MainActor
struct LocalPurgeModelTests {
    private func makeModel(_ probe: Probe) -> LocalPurgeModel {
        LocalPurgeModel(
            assess: { probe.assess() }, run: { try probe.run() }, afterPurge: { probe.after() })
    }

    @Test func buttonIsDisabledUntilTheCheckSaysYes() async {
        let probe = Probe()
        let model = makeModel(probe)
        #expect(!model.canPurge, "désactivé tant qu'on ne sait pas")
        #expect(await model.purge() == false)
        #expect(probe.runs == 0)

        await model.refresh()
        #expect(model.availability == .allowed)
        #expect(model.canPurge)
        #expect(model.blockedReason == nil)
    }

    @Test func blockedShowsAShortReasonAndNeverRuns() async {
        let probe = Probe()
        probe.blockers = [.unsentSaisies(3)]
        let model = makeModel(probe)

        await model.refresh()

        #expect(!model.canPurge)
        #expect(model.blockedReason == "3 saisies pas encore sur Pulse")
        #expect(await model.purge() == false)
        #expect(probe.runs == 0)
        #expect(probe.afters == 0)
    }

    @Test func unreadableStateKeepsTheButtonOff() async {
        let probe = Probe()
        probe.blockers = nil
        let model = makeModel(probe)

        await model.refresh()

        #expect(model.availability == .unknown)
        #expect(!model.canPurge)
    }

    @Test func aSuccessfulPurgeRunsTheAfterStepsThenRechecks() async {
        let probe = Probe()
        let model = makeModel(probe)
        await model.refresh()
        let checksBefore = probe.assessments

        #expect(await model.purge() == true)

        #expect(probe.runs == 1)
        #expect(probe.afters == 1, "écrans, réveil et ré-ingestion")
        #expect(probe.assessments == checksBefore + 1, "état relu après la purge")
        #expect(!model.isPurging)
        #expect(!model.failed)
    }

    @Test func aBlockAppearingSinceTheLastCheckStopsThePurgeAndShowsTheReason() async {
        let probe = Probe()
        let model = makeModel(probe)
        await model.refresh()
        probe.error = LocalDataPurge.Blocked(blockers: [.unsentSaisies(1)])

        #expect(await model.purge() == false)

        #expect(probe.afters == 0)
        #expect(model.blockedReason == "1 saisie pas encore sur Pulse")
        #expect(!model.failed)
    }

    @Test func anIOFailureIsReportedAndSkipsTheAfterSteps() async {
        struct Boom: Error {}
        let probe = Probe()
        let model = makeModel(probe)
        await model.refresh()
        probe.error = Boom()

        #expect(await model.purge() == false)

        #expect(model.failed)
        #expect(probe.afters == 0)
        #expect(model.availability == .allowed, "on peut réessayer")
    }
}

// MARK: - Réveil

@MainActor
struct WakeScheduleLocalPurgeTests {
    @Test func clearingForThePurgeEmptiesMemoryAndCacheWithoutPushing() throws {
        let suiteName = "wake-purge-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(try JSONEncoder().encode(["2": 420, "3": 450]), forKey: "pulse-wake-schedule")
        let store = WakeScheduleStore(defaults: defaults)
        #expect(store.minutesByWeekday == [2: 420, 3: 450])

        store.clearForLocalPurge()

        #expect(store.minutesByWeekday.isEmpty)
        #expect(WakeScheduleStore(defaults: defaults).minutesByWeekday.isEmpty, "le cache hors-ligne est vidé aussi")
    }
}
