//
//  WakeScheduleLocalTests.swift
//  allTests
//
//  Valide le backend local « réveil lié au profil » — `GET`/`PUT
//  api/wake-schedule` servis par `RealLocalPulseBackend`/`LocalDb` (miroir de
//  `WakeController` — `wake.controller.ts`). Même esprit que
//  `ProgrammeReadLocalTests`/`ProgrammeWriteLocalTests` : intégration
//  `RealLocalPulseBackend` + `LocalDb` temporaire, réponses décodées avec le
//  DTO réel du client (`WakeScheduleDTO`, `Pulse/Core/WakeScheduleStore.swift`).
//

import Testing
import Foundation
@testable import all

@Suite(.serialized)
struct WakeScheduleLocalTests {
    private func makeDb() throws -> LocalDb {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("wake-schedule-local-tests-\(UUID().uuidString).sqlite").path
        return try LocalDb(path: path)
    }

    private func get(_ backend: RealLocalPulseBackend) async throws -> WakeScheduleDTO {
        let data = try await backend.handle(method: "GET", path: "api/wake-schedule", query: [:], body: nil)
        return try PulseAPIClient.decoder.decode(WakeScheduleDTO.self, from: data)
    }

    private func put(_ backend: RealLocalPulseBackend, schedule: [String: Int]) async throws -> WakeScheduleDTO {
        let body = try JSONEncoder().encode(WakeScheduleDTO(schedule: schedule))
        let data = try await backend.handle(method: "PUT", path: "api/wake-schedule", query: [:], body: body)
        return try PulseAPIClient.decoder.decode(WakeScheduleDTO.self, from: data)
    }

    @Test func getIsEmptyByDefault() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let result = try await get(backend)
        #expect(result.schedule.isEmpty)
    }

    @Test func putValidThenGetRereadsSameMap() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let updated = try await put(backend, schedule: ["1": 420, "2": 405])
        #expect(updated.schedule == ["1": 420, "2": 405])

        let reread = try await get(backend)
        #expect(reread.schedule == ["1": 420, "2": 405])
    }

    @Test func putReplacesEntireSchedule() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        _ = try await put(backend, schedule: ["1": 420, "2": 405, "3": 390])
        let updated = try await put(backend, schedule: ["1": 450])
        #expect(updated.schedule == ["1": 450])

        let reread = try await get(backend)
        #expect(reread.schedule == ["1": 450])
    }

    @Test func putWithWeekday8Throws() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        await #expect(throws: (any Error).self) {
            _ = try await self.put(backend, schedule: ["8": 420])
        }
    }

    @Test func putWithWeekday0Throws() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        await #expect(throws: (any Error).self) {
            _ = try await self.put(backend, schedule: ["0": 420])
        }
    }

    @Test func putWithMinutes1440Throws() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        await #expect(throws: (any Error).self) {
            _ = try await self.put(backend, schedule: ["1": 1440])
        }
    }

    @Test func putWithNegativeMinutesThrows() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        await #expect(throws: (any Error).self) {
            _ = try await self.put(backend, schedule: ["1": -1])
        }
    }

    /// Entrée corrompue stockée directement en base (hors contrat PUT) :
    /// `GET` l'ignore silencieusement plutôt que de lever.
    @Test func getIgnoresCorruptedEntryAtRead() async throws {
        let db = try makeDb()
        try db.setSetting(key: "wakeSchedule", value: #"{"1":420,"9":100,"2":99999}"#)
        let backend = RealLocalPulseBackend(db: db)
        let result = try await get(backend)
        #expect(result.schedule == ["1": 420])
    }
}
