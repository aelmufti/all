//
//  ProfileLocalTests.swift
//  allTests
//
//  Valide l'incrément L6-Profil (`docs/stockage-local.md`) : `GET`/`PUT
//  api/profile` servis par `RealLocalPulseBackend`/`LocalDb` (table
//  `settings`, quatre clés `birthYear`/`sex`/`weightKg`/`heightCm`), décodés
//  avec le décodeur/modèle RÉEL de l'écran Paramètres (`PulseAPIClient.decoder`,
//  `SettingsProfile`, `Pulse/Screens/Settings/SettingsModels.swift`) — même
//  esprit que `WeightLocalTests`.
//

import Testing
import Foundation
@testable import all

struct ProfileLocalTests {
    private func makeBackend() throws -> RealLocalPulseBackend {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-local-tests-\(UUID().uuidString).sqlite").path
        let db = try LocalDb(path: path)
        return RealLocalPulseBackend(db: db)
    }

    private func getProfile(_ backend: RealLocalPulseBackend) async throws -> SettingsProfile {
        let data = try await backend.handle(method: "GET", path: "api/profile", query: [:], body: nil)
        return try PulseAPIClient.decoder.decode(SettingsProfile.self, from: data)
    }

    private func putProfile(
        _ backend: RealLocalPulseBackend,
        birthYear: Int? = nil, sex: String? = nil, weightKg: Double? = nil, heightCm: Double? = nil
    ) async throws -> SettingsProfile {
        var payload: [String: Any] = [:]
        if let birthYear { payload["birthYear"] = birthYear }
        if let sex { payload["sex"] = sex }
        if let weightKg { payload["weightKg"] = weightKg }
        if let heightCm { payload["heightCm"] = heightCm }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await backend.handle(method: "PUT", path: "api/profile", query: [:], body: body)
        return try PulseAPIClient.decoder.decode(SettingsProfile.self, from: data)
    }

    private func getWeight(_ backend: RealLocalPulseBackend) async throws -> WeightData {
        let data = try await backend.handle(method: "GET", path: "api/weight", query: ["days": "3660"], body: nil)
        return try PulseAPIClient.decoder.decode(WeightData.self, from: data)
    }

    /// Base vierge : les quatre champs sont `null` — miroir de
    /// `ProfileController.read` sur une table `settings` sans ces clés.
    @Test func getOnEmptyDbReturnsAllNil() async throws {
        let backend = try makeBackend()
        let profile = try await getProfile(backend)
        #expect(profile.birthYear == nil)
        #expect(profile.sex == nil)
        #expect(profile.weightKg == nil)
        #expect(profile.heightCm == nil)
    }

    /// PUT des quatre champs puis GET : reflète exactement ce qui a été
    /// écrit, décodé avec le modèle réel de l'écran Paramètres.
    @Test func putThenGetReflectsAllFields() async throws {
        let backend = try makeBackend()
        let updated = try await putProfile(backend, birthYear: 1990, sex: "female", weightKg: 61.5, heightCm: 168)

        #expect(updated.birthYear == 1990)
        #expect(updated.sex == "female")
        #expect(updated.weightKg == 61.5)
        #expect(updated.heightCm == 168)

        let refetched = try await getProfile(backend)
        #expect(refetched.birthYear == 1990)
        #expect(refetched.sex == "female")
        #expect(refetched.weightKg == 61.5)
        #expect(refetched.heightCm == 168)
    }

    /// PUT partiel (un seul champ à la fois) : les autres champs restent
    /// inchangés — miroir de `body.xxx != null` côté `ProfileController.update`.
    @Test func putIsPartial() async throws {
        let backend = try makeBackend()
        _ = try await putProfile(backend, birthYear: 1990, sex: "male", heightCm: 180)
        let updated = try await putProfile(backend, heightCm: 182)

        #expect(updated.birthYear == 1990)
        #expect(updated.sex == "male")
        #expect(updated.heightCm == 182)
    }

    /// `weightKg` fourni par `PUT api/profile` atterrit AUSSI dans
    /// `weight_log` (jour calendaire courant) — divergence assumée vs le
    /// serveur (cf. commentaire de section dans `LocalPulseBackend.swift`) :
    /// `GET api/weight` doit refléter la même valeur, cohérence avec L5-Poids.
    @Test func putWeightKgAlsoLandsInWeightLog() async throws {
        let backend = try makeBackend()
        _ = try await putProfile(backend, weightKg: 72.3)

        let weight = try await getWeight(backend)
        #expect(weight.current == 72.3)
        #expect(weight.entries == 1)
        // Jour calendaire courant — vérifié via le format plutôt qu'une
        // valeur figée (même convention que `WeightLocalTests.postWithoutDateDefaultsToToday`).
        #expect(weight.currentDate?.count == 10)
        #expect(weight.currentDate?.contains("-") == true)

        let profile = try await getProfile(backend)
        #expect(profile.weightKg == 72.3)
    }

    /// `weightKg` du PUT profil reste cohérent avec une pesée déjà loggée le
    /// même jour via `POST api/weight` (Santé) : upsert sur la même date, pas
    /// une deuxième ligne.
    @Test func putWeightKgUpsertsTodaysWeightLogEntry() async throws {
        let backend = try makeBackend()

        _ = try await putProfile(backend, weightKg: 70.0)
        _ = try await putProfile(backend, weightKg: 71.5)

        let weight = try await getWeight(backend)
        #expect(weight.entries == 1)
        #expect(weight.current == 71.5)
    }

    /// `birthYear` hors bornes `[currentYear-110, currentYear-10]` — lève,
    /// rien n'est écrit.
    @Test func invalidBirthYearThrows() async throws {
        let backend = try makeBackend()
        let currentYear = Calendar.current.component(.year, from: Date())
        await #expect(throws: (any Error).self) {
            _ = try await self.putProfile(backend, birthYear: currentYear - 5)
        }
        await #expect(throws: (any Error).self) {
            _ = try await self.putProfile(backend, birthYear: currentYear - 111)
        }
        let profile = try await getProfile(backend)
        #expect(profile.birthYear == nil)
    }

    /// `sex` hors `{male, female}` — lève, rien n'est écrit.
    @Test func invalidSexThrows() async throws {
        let backend = try makeBackend()
        await #expect(throws: (any Error).self) {
            _ = try await self.putProfile(backend, sex: "other")
        }
        let profile = try await getProfile(backend)
        #expect(profile.sex == nil)
    }

    /// `heightCm` hors bornes `[100, 250]` — lève, rien n'est écrit.
    @Test func invalidHeightThrows() async throws {
        let backend = try makeBackend()
        await #expect(throws: (any Error).self) {
            _ = try await self.putProfile(backend, heightCm: 50)
        }
        await #expect(throws: (any Error).self) {
            _ = try await self.putProfile(backend, heightCm: 300)
        }
        let profile = try await getProfile(backend)
        #expect(profile.heightCm == nil)
    }

    /// `weightKg` hors bornes `[25, 300]` — lève, rien n'est écrit ni dans
    /// `settings` ni dans `weight_log`.
    @Test func invalidWeightKgThrows() async throws {
        let backend = try makeBackend()
        await #expect(throws: (any Error).self) {
            _ = try await self.putProfile(backend, weightKg: 400)
        }
        let profile = try await getProfile(backend)
        #expect(profile.weightKg == nil)
        let weight = try await getWeight(backend)
        #expect(weight.entries == 0)
    }

    /// Corps vide — lève proprement (pas de crash), miroir dégradé des autres
    /// routes d'écriture (`encodeWeightAdd`, `encodeNutritionLogAdd`…).
    @Test func missingBodyThrowsCleanly() async throws {
        let backend = try makeBackend()
        await #expect(throws: (any Error).self) {
            _ = try await backend.handle(method: "PUT", path: "api/profile", query: [:], body: nil)
        }
    }
}
