//
//  NutritionLocalTests.swift
//  allTests
//
//  Valide l'incrément L5-Nutrition (`docs/stockage-local.md`) : `foods`/
//  `food_log` servis par `RealLocalPulseBackend`/`LocalDb`, décodés avec le
//  décodeur/modèles RÉELS de l'écran Nutrition (`PulseAPIClient.decoder`,
//  `NutritionDay`/`NutritionFrequentFood`/`NutritionFoodLite`/…,
//  `Pulse/Screens/Nutrition/NutritionModels.swift`) — même esprit que
//  `WeightLocalTests.swift`.
//
//  Réseau Open Food Facts (`nutrition/search`/`nutrition/barcode/:code`) :
//  AUCUN test ici ne touche le réseau — `OpenFoodFactsTransport` est
//  substitué par un double factice (`FakeOpenFoodFactsTransport`), même
//  principe que `PulseUploadTransport` (cf. `Sync/PulseUploader.swift`,
//  `PulseUploaderTests.swift`).
//

import Testing
import Foundation
@testable import all

// MARK: - Double factice Open Food Facts (aucun réseau)

private final class FakeOpenFoodFactsTransport: OpenFoodFactsTransport {
    private(set) var requests: [URLRequest] = []
    var handler: (URLRequest) throws -> (Data, URLResponse)

    init(handler: @escaping (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try handler(request)
    }
}

private struct FakeTransportError: Error {}

private func jsonResponse(_ url: URL, status: Int = 200, body: Data) -> (Data, URLResponse) {
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (body, response)
}

// MARK: - Aides communes

private func makeDb() throws -> LocalDb {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("nutrition-local-tests-\(UUID().uuidString).sqlite").path
    return try LocalDb(path: path)
}

private func makeBackend(offTransport: OpenFoodFactsTransport = FakeOpenFoodFactsTransport(handler: { _ in throw FakeTransportError() })) throws -> RealLocalPulseBackend {
    RealLocalPulseBackend(db: try makeDb(), offTransport: offTransport)
}

// MARK: - Seed

struct NutritionLocalTests {
    /// La table `foods` est semée au premier ouverture (`LocalDb.seedFoods`,
    /// port de `seed-foods.ts`) — vérifie juste qu'elle n'est pas vide et
    /// contient un aliment connu, pas les ~95 lignes une à une.
    @Test func seedIsPresentOnFirstOpen() throws {
        let db = try makeDb()
        let banane = try db.searchFoods(query: "Banane")
        #expect(!banane.isEmpty)
        #expect(banane.first?.kcal == 89)
    }

    /// `GET api/nutrition/foods?q=` — miroir de la recherche bibliothèque,
    /// doit trouver les aliments semés.
    @Test func foodsSearchHitsTheSeed() async throws {
        let backend = try makeBackend()
        let data = try await backend.handle(method: "GET", path: "api/nutrition/foods", query: ["q": "pomme"], body: nil)
        let results = try PulseAPIClient.decoder.decode([NutritionFoodLite].self, from: data)
        #expect(!results.isEmpty)
        #expect(results.contains { $0.name == "Pomme" })
    }

// MARK: - Journal (`day/:date`, `log`, `frequent`)
    private func addLog(_ backend: RealLocalPulseBackend, date: String, name: String, grams: Double, kcal: Double, protein: Double, ts: Int? = nil) async throws -> Int {
        var body = NutritionLogRequest(date: date, name: name)
        body.grams = grams
        body.kcal = kcal
        body.protein = protein
        body.ts = ts
        let data = try await backend.handle(method: "POST", path: "api/nutrition/log", query: [:], body: try PulseAPIClient.encoder.encode(body))
        return try PulseAPIClient.decoder.decode(NutritionLogResponse.self, from: data).id
    }

    private func day(_ backend: RealLocalPulseBackend, date: String) async throws -> NutritionDay {
        let data = try await backend.handle(method: "GET", path: "api/nutrition/day/\(date)", query: [:], body: nil)
        return try PulseAPIClient.decoder.decode(NutritionDay.self, from: data)
    }

    /// POST une entrée (grammes) puis GET `day/:date` : l'entrée et les
    /// totaux (macros × grammes/100, arrondi 0,1) sont fidèles au serveur.
    @Test func postLogThenDayReflectsEntryAndTotals() async throws {
        let backend = try makeBackend()
        let id = try await addLog(backend, date: "2026-09-23", name: "Poulet maison", grams: 150, kcal: 165, protein: 31, ts: 1_758_610_000)

        let d = try await day(backend, date: "2026-09-23")
        #expect(d.date == "2026-09-23")
        #expect(d.entries.count == 1)
        let entry = try #require(d.entries.first)
        #expect(entry.id == id)
        #expect(entry.name == "Poulet maison")
        #expect(entry.grams == 150)
        // 165 * 1.5 = 247.5 kcal ; 31 * 1.5 = 46.5 g protéines.
        #expect(entry.kcal == 247.5)
        #expect(entry.protein == 46.5)
        #expect(entry.ts == 1_758_610_000)
        #expect(d.totals.kcal == 247.5)
        #expect(d.totals.protein == 46.5)
        // Cibles jamais calculées localement dans cet incrément (cf. rapport) :
        // toujours neutres, PAS un `0` qui se ferait passer pour une vraie cible.
        #expect(d.targets.kcal == nil)
        #expect(d.remaining.kcal == nil)
        #expect(d.targetRanges == nil)
        #expect(d.programme == nil)
    }

    /// Deux entrées le même jour : les totaux s'additionnent (arrondi 0,1).
    @Test func multipleEntriesSumIntoTotals() async throws {
        let backend = try makeBackend()
        _ = try await addLog(backend, date: "2026-09-23", name: "Riz cuit", grams: 200, kcal: 130, protein: 2.7)
        _ = try await addLog(backend, date: "2026-09-23", name: "Poulet", grams: 100, kcal: 165, protein: 31)

        let d = try await day(backend, date: "2026-09-23")
        #expect(d.entries.count == 2)
        // (130*2 + 165) = 425 kcal ; (2.7*2 + 31) = 36.4 g protéines.
        #expect(d.totals.kcal == 425)
        #expect(abs(d.totals.protein! - 36.4) < 0.0001)
    }

    /// `proteinPerKg` — SEUL champ de cible calculé fidèlement (dépend des
    /// totaux réels + `settings.weightKg`, tenu à jour par L5-Poids), miroir
    /// de `weightKg && totals.protein ? round(...) : null` (TS).
    @Test func proteinPerKgUsesStoredWeightSetting() async throws {
        let db = try makeDb()
        try db.setSetting(key: "weightKg", value: "70")
        let backend = RealLocalPulseBackend(db: db)
        _ = try await addLog(backend, date: "2026-09-23", name: "Whey", grams: 30, kcal: 400, protein: 80)

        let d = try await day(backend, date: "2026-09-23")
        // 80*0.3 = 24 g protéines ; 24/70 = 0.342857 → arrondi 0,01 = 0.34.
        #expect(d.totals.protein == 24)
        #expect(d.proteinPerKg == 0.34)
    }

    /// Sans pesée locale (`settings.weightKg` absent), `proteinPerKg` reste
    /// `nil` — pas de valeur inventée.
    @Test func proteinPerKgIsNilWithoutWeightSetting() async throws {
        let backend = try makeBackend()
        _ = try await addLog(backend, date: "2026-09-23", name: "Whey", grams: 30, kcal: 400, protein: 80)
        let d = try await day(backend, date: "2026-09-23")
        #expect(d.proteinPerKg == nil)
    }

    /// `PUT api/nutrition/log/:id` — édite grammes/macros, le jour reflète
    /// la nouvelle valeur.
    @Test func editLogUpdatesEntry() async throws {
        let backend = try makeBackend()
        let id = try await addLog(backend, date: "2026-09-23", name: "Riz cuit", grams: 100, kcal: 130, protein: 2.7)

        var editBody = NutritionLogRequest(date: "2026-09-23", name: "Riz complet cuit")
        editBody.grams = 200
        editBody.kcal = 111
        editBody.protein = 2.6
        let editData = try await backend.handle(
            method: "PUT", path: "api/nutrition/log/\(id)", query: [:], body: try PulseAPIClient.encoder.encode(editBody))
        let ok = try PulseAPIClient.decoder.decode(NutritionOkResponse.self, from: editData)
        #expect(ok.ok == true)

        let d = try await day(backend, date: "2026-09-23")
        let entry = try #require(d.entries.first)
        #expect(entry.name == "Riz complet cuit")
        #expect(entry.grams == 200)
        #expect(entry.kcal == 222) // 111 * 2
    }

    /// `DELETE api/nutrition/log/:id` — l'entrée disparaît du jour.
    @Test func deleteLogRemovesEntry() async throws {
        let backend = try makeBackend()
        let id = try await addLog(backend, date: "2026-09-23", name: "Riz cuit", grams: 100, kcal: 130, protein: 2.7)
        _ = try await backend.handle(method: "DELETE", path: "api/nutrition/log/\(id)", query: [:], body: nil)

        let d = try await day(backend, date: "2026-09-23")
        #expect(d.entries.isEmpty)
        #expect(d.totals.kcal == 0)
    }

    /// `foodId` connu : le serveur (ici le backend local) recalcule les
    /// macros depuis la fiche `foods`, ignore celles du corps — miroir
    /// d'`addLog` (TS).
    @Test func logWithKnownFoodIdRecomputesFromFoodSheet() async throws {
        let backend = try makeBackend()
        let foodData = try await backend.handle(
            method: "GET", path: "api/nutrition/foods", query: ["q": "Banane"], body: nil)
        let foods = try PulseAPIClient.decoder.decode([NutritionFoodLite].self, from: foodData)
        let banane = try #require(foods.first { $0.name == "Banane" })
        let foodId = try #require(banane.id)

        var body = NutritionLogRequest(date: "2026-09-23", name: "ignoré")
        body.foodId = foodId
        body.grams = 60 // moitié d'une banane (120 g pour 89 kcal/100g)
        body.kcal = 9999 // doit être ignoré au profit de la fiche `foods`
        let data = try await backend.handle(method: "POST", path: "api/nutrition/log", query: [:], body: try PulseAPIClient.encoder.encode(body))
        _ = try PulseAPIClient.decoder.decode(NutritionLogResponse.self, from: data)

        let d = try await day(backend, date: "2026-09-23")
        let entry = try #require(d.entries.first)
        #expect(entry.name == "Banane")
        // 89 kcal/100g * 60g = 53.4 kcal.
        #expect(entry.kcal == 53.4)
    }

    /// `frequent` — regroupe par aliment, trie par usages puis dernière
    /// utilisation, décodable dans le modèle réel de l'écran.
    @Test func frequentReturnsLoggedFoodsSortedByUses() async throws {
        let backend = try makeBackend()
        _ = try await addLog(backend, date: "2026-09-20", name: "Yaourt", grams: 125, kcal: 61, protein: 3.5, ts: 1)
        _ = try await addLog(backend, date: "2026-09-21", name: "Yaourt", grams: 125, kcal: 61, protein: 3.5, ts: 2)
        _ = try await addLog(backend, date: "2026-09-22", name: "Compote", grams: 90, kcal: 42, protein: 0.2, ts: 3)

        let data = try await backend.handle(method: "GET", path: "api/nutrition/frequent", query: [:], body: nil)
        let frequent = try PulseAPIClient.decoder.decode([NutritionFrequentFood].self, from: data)
        #expect(frequent.count == 2)
        let top = try #require(frequent.first)
        #expect(top.name == "Yaourt")
        #expect(top.uses == 2)
        #expect(top.grams == 125)
    }

    /// Date malformée sur `day/:date` : lève proprement.
    @Test func malformedDateThrowsCleanly() async throws {
        let backend = try makeBackend()
        await #expect(throws: (any Error).self) {
            _ = try await backend.handle(method: "GET", path: "api/nutrition/day/not-a-date", query: [:], body: nil)
        }
    }

// MARK: - Bibliothèque (`POST`/`PUT foods`)
    /// `POST api/nutrition/foods` — crée un aliment, la réponse décode dans
    /// le modèle réel (`NutritionFoodLite`) et la fiche est ensuite
    /// retrouvable par recherche.
    @Test func createFoodThenFindsItBySearch() async throws {
        let backend = try makeBackend()
        let body = NutritionFoodCreateRequest(
            name: "Galette maison", barcode: nil, kcal: 200, protein: 10, carbs: 20, fiber: 3, fat: 5,
            unitLabel: "galette", unitGrams: 50)
        let data = try await backend.handle(method: "POST", path: "api/nutrition/foods", query: [:], body: try PulseAPIClient.encoder.encode(body))
        let created = try PulseAPIClient.decoder.decode(NutritionFoodLite.self, from: data)
        #expect(created.id != nil)
        #expect(created.name == "Galette maison")
        #expect(created.unitGrams == 50)

        let searchData = try await backend.handle(method: "GET", path: "api/nutrition/foods", query: ["q": "Galette maison"], body: nil)
        let results = try PulseAPIClient.decoder.decode([NutritionFoodLite].self, from: searchData)
        #expect(results.contains { $0.id == created.id })
    }

    /// `PUT api/nutrition/foods/:id` — édite une fiche existante.
    @Test func updateFoodChangesFields() async throws {
        let backend = try makeBackend()
        let createData = try await backend.handle(
            method: "POST", path: "api/nutrition/foods", query: [:],
            body: try PulseAPIClient.encoder.encode(NutritionFoodCreateRequest(name: "Test", barcode: nil, kcal: 100, protein: 1, carbs: 1, fiber: 1, fat: 1, unitLabel: nil, unitGrams: nil)))
        let created = try PulseAPIClient.decoder.decode(NutritionFoodLite.self, from: createData)
        let id = try #require(created.id)

        let updateBody = NutritionFoodCreateRequest(name: "Test modifié", barcode: nil, kcal: 150, protein: 2, carbs: 2, fiber: 2, fat: 2, unitLabel: nil, unitGrams: nil)
        let updateData = try await backend.handle(method: "PUT", path: "api/nutrition/foods/\(id)", query: [:], body: try PulseAPIClient.encoder.encode(updateBody))
        let updated = try PulseAPIClient.decoder.decode(NutritionFoodLite.self, from: updateData)
        #expect(updated.name == "Test modifié")
        #expect(updated.kcal == 150)
    }

// MARK: - Open Food Facts (Part B — réseau simulé, jamais réel)
    /// `GET api/nutrition/search` — mappe une réponse OFF factice vers
    /// `[NutritionFoodLite]`, vérifie l'URL/les champs de requête EXACTS
    /// (mêmes que le serveur : `search.openfoodfacts.org/search`, `langs=fr`,
    /// `page_size=50`, `fields=...`, en-tête `User-Agent`).
    @Test func searchMapsOffHitsToFoodLite() async throws {
        let fixture = Data(
            """
            {"hits":[
              {"code":"3017620422003","product_name":"Yaourt Test","nutriments":{"energy-kcal_100g":80,"proteins_100g":5,"carbohydrates_100g":10,"fiber_100g":0.5,"fat_100g":2},"serving_quantity":125}
            ]}
            """.utf8)
        let transport = FakeOpenFoodFactsTransport { request in
            jsonResponse(request.url!, body: fixture)
        }
        let backend = try makeBackend(offTransport: transport)

        let data = try await backend.handle(method: "GET", path: "api/nutrition/search", query: ["q": "yaourt"], body: nil)
        let results = try PulseAPIClient.decoder.decode([NutritionFoodLite].self, from: data)
        #expect(results.count == 1)
        let item = try #require(results.first)
        #expect(item.id == nil) // jamais encore enregistré, miroir `Omit<Food, 'id'>`.
        #expect(item.barcode == "3017620422003")
        #expect(item.name == "Yaourt Test")
        #expect(item.kcal == 80)
        #expect(item.unitLabel == "portion")
        #expect(item.unitGrams == 125)

        let request = try #require(transport.requests.first)
        let url = try #require(request.url)
        #expect(url.host == "search.openfoodfacts.org")
        #expect(url.path == "/search")
        let query = url.query ?? ""
        #expect(query.contains("q=yaourt"))
        #expect(query.contains("langs=fr"))
        #expect(query.contains("page_size=50"))
        #expect(query.contains("fields=code,product_name,nutriments,serving_quantity"))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Pulse/1.0 (self-hosted)")
    }

    /// Terme trop court (< 2 caractères) : aucune requête réseau, réponse `[]`
    /// — miroir exact du serveur (`if (term.length < 2) return [];`).
    @Test func searchWithShortTermSkipsNetworkEntirely() async throws {
        let transport = FakeOpenFoodFactsTransport { _ in throw FakeTransportError() }
        let backend = try makeBackend(offTransport: transport)
        let data = try await backend.handle(method: "GET", path: "api/nutrition/search", query: ["q": "a"], body: nil)
        let results = try PulseAPIClient.decoder.decode([NutritionFoodLite].self, from: data)
        #expect(results.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    /// Échec réseau sur `search` : SILENCIEUX, `[]` — miroir exact du
    /// `try {...} catch { return []; }` serveur (décision de cet incrément,
    /// cf. rapport : diverge volontairement de `barcode`, qui lève).
    @Test func searchNetworkFailureIsSilent() async throws {
        let transport = FakeOpenFoodFactsTransport { _ in throw FakeTransportError() }
        let backend = try makeBackend(offTransport: transport)
        let data = try await backend.handle(method: "GET", path: "api/nutrition/search", query: ["q": "yaourt"], body: nil)
        let results = try PulseAPIClient.decoder.decode([NutritionFoodLite].self, from: data)
        #expect(results.isEmpty)
    }

    /// Code-barres déjà connu en bibliothèque locale : `source: "local"`,
    /// AUCUNE requête réseau.
    @Test func barcodeHitsLocalLibraryFirstWithoutNetwork() async throws {
        let db = try makeDb()
        try db.insertFood(barcode: "1234567890123", name: "Local Food", kcal: 100, protein: 5, carbs: 10, fiber: 1, fat: 2, unitLabel: nil, unitGrams: nil)
        let transport = FakeOpenFoodFactsTransport { _ in throw FakeTransportError() }
        let backend = RealLocalPulseBackend(db: db, offTransport: transport)

        let data = try await backend.handle(method: "GET", path: "api/nutrition/barcode/1234567890123", query: [:], body: nil)
        let result = try PulseAPIClient.decoder.decode(NutritionBarcodeResult.self, from: data)
        #expect(result.found == true)
        #expect(result.source == "local")
        #expect(result.food?.name == "Local Food")
        #expect(transport.requests.isEmpty)
    }

    /// Code-barres inconnu localement, trouvé sur Open Food Facts : crée la
    /// fiche (`source: "openfoodfacts"`), persistée en base pour la suite.
    @Test func barcodeFallsBackToOpenFoodFactsAndPersists() async throws {
        let fixture = Data(
            """
            {"status":1,"product":{"product_name":"Produit OFF","nutriments":{"energy-kcal_100g":250,"proteins_100g":8,"carbohydrates_100g":30,"fiber_100g":2,"fat_100g":9},"serving_quantity":"45"}}
            """.utf8)
        let transport = FakeOpenFoodFactsTransport { request in jsonResponse(request.url!, body: fixture) }
        let db = try makeDb()
        let backend = RealLocalPulseBackend(db: db, offTransport: transport)

        let data = try await backend.handle(method: "GET", path: "api/nutrition/barcode/3017620422003", query: [:], body: nil)
        let result = try PulseAPIClient.decoder.decode(NutritionBarcodeResult.self, from: data)
        #expect(result.found == true)
        #expect(result.source == "openfoodfacts")
        #expect(result.food?.name == "Produit OFF")
        #expect(result.food?.unitGrams == 45) // `serving_quantity` chaîne, miroir `parseFloat`.

        // Persisté : une deuxième recherche du même code-barres retombe sur
        // la branche locale (aucun 2ᵉ appel réseau).
        let secondData = try await backend.handle(method: "GET", path: "api/nutrition/barcode/3017620422003", query: [:], body: nil)
        let second = try PulseAPIClient.decoder.decode(NutritionBarcodeResult.self, from: secondData)
        #expect(second.source == "local")
        #expect(transport.requests.count == 1)

        let request = try #require(transport.requests.first)
        #expect(request.url?.host == "world.openfoodfacts.org")
        #expect(request.url?.path == "/api/v2/product/3017620422003.json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Pulse/1.0 (self-hosted)")
    }

    /// Produit vraiment absent d'OFF (`status: 0`) : `{found:false}` gracieux,
    /// PAS une erreur.
    @Test func barcodeNotFoundOnOffReturnsFoundFalseWithoutThrowing() async throws {
        let fixture = Data(#"{"status":0}"#.utf8)
        let transport = FakeOpenFoodFactsTransport { request in jsonResponse(request.url!, body: fixture) }
        let backend = try makeBackend(offTransport: transport)

        let data = try await backend.handle(method: "GET", path: "api/nutrition/barcode/9999999999999", query: [:], body: nil)
        let result = try PulseAPIClient.decoder.decode(NutritionBarcodeResult.self, from: data)
        #expect(result.found == false)
    }

    /// Échec réseau sur `barcode` : LÈVE (divergence assumée vs `search`,
    /// cf. rapport) — `lookupBarcode()` affiche un message dédié dans ce cas.
    @Test func barcodeNetworkFailureThrows() async throws {
        let transport = FakeOpenFoodFactsTransport { _ in throw FakeTransportError() }
        let backend = try makeBackend(offTransport: transport)
        await #expect(throws: (any Error).self) {
            _ = try await backend.handle(method: "GET", path: "api/nutrition/barcode/1234567890123", query: [:], body: nil)
        }
    }

    /// Code-barres malformé (pas 6-14 chiffres) : lève proprement, AUCUN
    /// réseau.
    @Test func malformedBarcodeThrowsWithoutNetwork() async throws {
        let transport = FakeOpenFoodFactsTransport { _ in throw FakeTransportError() }
        let backend = try makeBackend(offTransport: transport)
        await #expect(throws: (any Error).self) {
            _ = try await backend.handle(method: "GET", path: "api/nutrition/barcode/abc", query: [:], body: nil)
        }
        #expect(transport.requests.isEmpty)
    }

// MARK: - Stubs neutres (`targets`/`weekly`/`timing`/`suggestions`)
    /// `GET api/nutrition/targets` — décode dans le modèle réel, `status`
    /// `"unavailable"` (jamais un objectif fabriqué).
    @Test func targetsStubDecodesAsUnavailable() async throws {
        let backend = try makeBackend()
        let data = try await backend.handle(method: "GET", path: "api/nutrition/targets", query: [:], body: nil)
        let info = try PulseAPIClient.decoder.decode(NutritionTargetInfo.self, from: data)
        #expect(info.auto.status == "unavailable")
        #expect(info.auto.targetKcal == nil)
        #expect(info.targets.kcal == nil)
        #expect(info.auto.macros.programme == nil)
        #expect(info.auto.guardStatus == "none")
    }

    /// `GET api/nutrition/weekly` — décode dans le modèle réel, `alert`
    /// toujours `false`, `thresholdKcal` = seuil par défaut (`600`, pas un
    /// résultat de calcul).
    @Test func weeklyStubDecodesWithDefaultThreshold() async throws {
        let backend = try makeBackend()
        let data = try await backend.handle(method: "GET", path: "api/nutrition/weekly", query: ["date": "2026-09-23"], body: nil)
        let weekly = try PulseAPIClient.decoder.decode(NutritionWeekly.self, from: data)
        #expect(weekly.alert == false)
        #expect(weekly.avgDeficitKcal == nil)
        #expect(weekly.thresholdKcal == 600)
    }

    /// `GET api/nutrition/timing/:date` — `{"meal": null}`, décodable et non
    /// lu par l'écran (champ mort dans `NutritionView`, cf. rapport).
    @Test func timingStubDecodesWithNoMeal() async throws {
        let backend = try makeBackend()
        let data = try await backend.handle(method: "GET", path: "api/nutrition/timing/2026-09-23", query: [:], body: nil)
        let timing = try PulseAPIClient.decoder.decode(NutritionTimingResponse.self, from: data)
        #expect(timing.meal == nil)
    }

    /// `GET api/nutrition/suggestions/:date` — `reason: "no-targets"`, items
    /// vide, `remaining` neutre — forme EXACTE renvoyée aussi par le serveur
    /// quand aucune cible n'est calculable.
    @Test func suggestionsStubDecodesAsNoTargets() async throws {
        let backend = try makeBackend()
        let data = try await backend.handle(method: "GET", path: "api/nutrition/suggestions/2026-09-23", query: [:], body: nil)
        let suggestions = try PulseAPIClient.decoder.decode(NutritionSuggestionsResponse.self, from: data)
        #expect(suggestions.items.isEmpty)
        #expect(suggestions.reason == "no-targets")
        #expect(suggestions.remaining.kcal == nil)
    }
}
