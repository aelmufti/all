//
//  WeightLocalTests.swift
//  allTests
//
//  Valide l'incrément L5-Poids (`docs/stockage-local.md`) : `GET`/`POST
//  api/weight` + `DELETE api/weight/:date` servis par
//  `RealLocalPulseBackend`/`LocalDb` (table `weight_log` + `settings`),
//  décodés avec le décodeur/modèles RÉELS de l'écran Santé
//  (`PulseAPIClient.decoder`, `WeightData`/`WeightSaveResult`,
//  `Pulse/Screens/Health/HealthModels.swift`) — même esprit que
//  `LocalDayDetailTests.backendServesDayDetailDecodableByRealAppModel`.
//

import Testing
import Foundation
@testable import all

struct WeightLocalTests {
    private func makeBackend() throws -> RealLocalPulseBackend {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("weight-local-tests-\(UUID().uuidString).sqlite").path
        let db = try LocalDb(path: path)
        return RealLocalPulseBackend(db: db)
    }

    private func post(_ backend: RealLocalPulseBackend, date: String?, kg: Double) async throws -> WeightSaveResult {
        var payload: [String: Any] = ["kg": kg]
        if let date { payload["date"] = date }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await backend.handle(method: "POST", path: "api/weight", query: [:], body: body)
        return try PulseAPIClient.decoder.decode(WeightSaveResult.self, from: data)
    }

    private func getWeight(_ backend: RealLocalPulseBackend) async throws -> WeightData {
        let data = try await backend.handle(method: "GET", path: "api/weight", query: ["days": "3660"], body: nil)
        return try PulseAPIClient.decoder.decode(WeightData.self, from: data)
    }

    /// POST une pesée puis GET — vérifie la forme JSON réelle (décodage dans
    /// `WeightData`, comme le ferait `HealthViewModel.loadWeight`) et les
    /// valeurs `current`/`entries`/`series`.
    @Test func postThenGetReflectsSingleEntry() async throws {
        let backend = try makeBackend()

        let saved = try await post(backend, date: "2026-09-20", kg: 70.4)
        #expect(saved.date == "2026-09-20")
        #expect(saved.kg == 70.4)

        let weight = try await getWeight(backend)
        #expect(weight.current == 70.4)
        #expect(weight.currentDate == "2026-09-20")
        #expect(weight.deltaKg == nil) // une seule entrée : pas de delta (miroir `rows.length > 1`)
        #expect(weight.entries == 1)
        #expect(weight.series.count == 1)
        #expect(weight.series[0].date == "2026-09-20")
        #expect(weight.series[0].kg == 70.4)
        #expect(weight.series[0].avg == 70.4)
        #expect(weight.push.status == "idle")
        #expect(weight.push.kg == nil)
        #expect(weight.push.at == nil)
    }

    /// Deuxième pesée à une date ultérieure : `current`/`currentDate` suivent
    /// la plus récente, `deltaKg` = (dernière - première) de la fenêtre,
    /// arrondi à 0,1 — miroir exact de `WeightController.list`.
    @Test func secondEntryUpdatesCurrentAndDelta() async throws {
        let backend = try makeBackend()
        _ = try await post(backend, date: "2026-09-20", kg: 70.4)
        _ = try await post(backend, date: "2026-09-25", kg: 69.1)

        let weight = try await getWeight(backend)
        #expect(weight.current == 69.1)
        #expect(weight.currentDate == "2026-09-25")
        #expect(weight.entries == 2)
        // 69.1 - 70.4 = -1.3 (arrondi 0,1 déjà exact ici).
        #expect(abs((weight.deltaKg ?? 0) - (-1.3)) < 0.0001)
        #expect(weight.series.map { $0.date } == ["2026-09-20", "2026-09-25"])
    }

    /// Re-POST sur la MÊME date : upsert (`ON CONFLICT(date) DO UPDATE`), pas
    /// une deuxième ligne — `entries` doit rester à 1.
    @Test func postOnSameDateUpserts() async throws {
        let backend = try makeBackend()
        _ = try await post(backend, date: "2026-09-20", kg: 70.4)
        _ = try await post(backend, date: "2026-09-20", kg: 71.2)

        let weight = try await getWeight(backend)
        #expect(weight.entries == 1)
        #expect(weight.current == 71.2)
    }

    /// `POST` sans `date` : retombe sur le jour calendaire courant
    /// (`todayDateKey`, miroir `todayKey()` TS) — vérifié via le format
    /// `YYYY-MM-DD` plutôt qu'une valeur figée (le test tournerait n'importe
    /// quel jour).
    @Test func postWithoutDateDefaultsToToday() async throws {
        let backend = try makeBackend()
        let saved = try await post(backend, date: nil, kg: 80)
        #expect(saved.date.count == 10)
        #expect(saved.date.contains("-"))
    }

    /// `DELETE` : la ligne disparaît (`entries` retombe à 0, `current` à
    /// `nil`) et `settings.weightKg` reflète la nouvelle dernière pesée (ici,
    /// plus aucune — la clé n'est PAS remise à zéro, miroir de `syncProfile`
    /// TS qui ne touche rien si `!latest`, cf. `LocalDb.syncWeightProfile`) ;
    /// vérifié séparément ci-dessous avec une pesée restante.
    @Test func deleteRemovesEntry() async throws {
        let backend = try makeBackend()
        _ = try await post(backend, date: "2026-09-20", kg: 70.4)

        let deleteData = try await backend.handle(method: "DELETE", path: "api/weight/2026-09-20", query: [:], body: nil)
        let ok = try JSONSerialization.jsonObject(with: deleteData) as? [String: Bool]
        #expect(ok?["ok"] == true)

        let weight = try await getWeight(backend)
        #expect(weight.entries == 0)
        #expect(weight.current == nil)
        #expect(weight.series.isEmpty)
    }

    /// `settings.weightKg` (lu directement via `LocalDb.settingValue`) suit la
    /// dernière pesée restante après une suppression — vérifie
    /// `syncWeightProfile` au-delà de la seule réponse HTTP `api/weight`.
    @Test func deleteResyncsSettingsToRemainingLatest() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("weight-local-tests-\(UUID().uuidString).sqlite").path
        let db = try LocalDb(path: path)
        let backend = RealLocalPulseBackend(db: db)

        _ = try await post(backend, date: "2026-09-20", kg: 70.4)
        _ = try await post(backend, date: "2026-09-25", kg: 69.0)
        #expect(try db.settingValue(key: "weightKg") == "69")

        _ = try await backend.handle(method: "DELETE", path: "api/weight/2026-09-25", query: [:], body: nil)
        #expect(try db.settingValue(key: "weightKg") == "70.4")
    }

    /// `kg` hors bornes [25, 300] (miroir `MIN_KG`/`MAX_KG` TS) : la requête
    /// lève, rien n'est écrit.
    @Test func outOfRangeKgThrows() async throws {
        let backend = try makeBackend()
        await #expect(throws: (any Error).self) {
            _ = try await self.post(backend, date: "2026-09-20", kg: 400)
        }
        await #expect(throws: (any Error).self) {
            _ = try await self.post(backend, date: "2026-09-20", kg: 10)
        }
        let weight = try await getWeight(backend)
        #expect(weight.entries == 0)
    }

    /// Date malformée sur `POST`/`DELETE` : lève proprement (pas de crash),
    /// miroir dégradé du `BadRequestException` côté serveur.
    @Test func malformedDateThrowsCleanly() async throws {
        let backend = try makeBackend()
        await #expect(throws: (any Error).self) {
            _ = try await self.post(backend, date: "20-09-2026", kg: 70)
        }
        await #expect(throws: (any Error).self) {
            _ = try await backend.handle(method: "DELETE", path: "api/weight/not-a-date", query: [:], body: nil)
        }
    }
}
