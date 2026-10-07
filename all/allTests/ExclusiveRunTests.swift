//
//  ExclusiveRunTests.swift
//  allTests
//
//  `runExclusively` : la purge des données de l'iPhone ne doit courir ni pendant une
//  passe d'ingestion (`SerialPassGate`) ni pendant un échange de saisies
//  (`SaisieSyncCoordinator`), et aucun des deux ne doit démarrer pendant la purge.
//

import Testing
import Foundation
@testable import all

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var flag = false
    var count: Int { lock.withLock { value } }
    var isSet: Bool { lock.withLock { flag } }
    func bump() { lock.withLock { value += 1 } }
    func set() { lock.withLock { flag = true } }
}

struct SerialPassGateExclusiveTests {
    @Test func nothingStartsWhileTheExclusiveWorkRuns() async {
        let gate = SerialPassGate()
        let passes = Counter()

        let started: Bool = await gate.runExclusively {
            #expect(!gate.isIdle)
            return gate.request { passes.bump() }
        }

        #expect(started == false, "la demande est écartée")
        #expect(await gate.waitUntilIdle())
        #expect(passes.count == 0, "et ne court pas une fois la garde rendue")
        // La garde fonctionne de nouveau normalement ensuite.
        #expect(gate.request { passes.bump() })
        #expect(await gate.waitUntilIdle())
        #expect(passes.count == 1)
    }

    @Test func itWaitsForARunningPassToFinish() async {
        let gate = SerialPassGate()
        let finished = Counter()
        #expect(gate.request {
            Thread.sleep(forTimeInterval: 0.15)
            finished.set()
        })

        let sawFinished: Bool = await gate.runExclusively { finished.isSet }

        #expect(sawFinished, "le travail exclusif ne démarre qu'après la passe en cours")
        #expect(await gate.waitUntilIdle())
    }

    @Test func itReleasesTheGateWhenTheWorkThrows() async {
        struct Boom: Error {}
        let gate = SerialPassGate()
        do {
            try await gate.runExclusively { throw Boom() }
            Issue.record("devait lever")
        } catch {}
        #expect(gate.isIdle)
    }
}

struct SaisieSyncCoordinatorExclusiveTests {
    @Test func aRequestDuringTheExclusiveWorkRunsOneExchangeAfterwards() async {
        let passes = Counter()
        let coordinator = SaisieSyncCoordinator { passes.bump() }

        await coordinator.runExclusively {
            await coordinator.request()
            await coordinator.request()
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(passes.count == 0, "aucun échange pendant le travail exclusif")
        }

        // Les deux demandes d'avant ont donné UN échange, lancé à la fin du travail exclusif.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let idle = await coordinator.isIdle
            if passes.count > 0 && idle { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(passes.count == 1)
        #expect(await coordinator.isIdle)
    }

    @Test func itWaitsForARunningExchange() async {
        let finished = Counter()
        let coordinator = SaisieSyncCoordinator {
            try? await Task.sleep(nanoseconds: 120_000_000)
            finished.set()
        }
        await coordinator.request()

        let sawFinished: Bool = await coordinator.runExclusively { finished.isSet }

        #expect(sawFinished)
        #expect(await coordinator.isIdle)
    }

    @Test func withoutAnyRequestItLeavesTheCoordinatorIdleAndRunsNothing() async {
        let passes = Counter()
        let coordinator = SaisieSyncCoordinator { passes.bump() }

        await coordinator.runExclusively { }

        #expect(await coordinator.isIdle)
        #expect(passes.count == 0)
    }
}
