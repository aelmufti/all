//
//  LocalPulseBackend.swift
//  all (bridge-connect)
//
//  Portage réel du backend local « Pulse embarqué » (incréments
//  L1+L2+L3+L4+L5, cf. `docs/stockage-local.md`) — remplace
//  `StubLocalPulseBackend` (L0) pour les routes qu'il sait vraiment servir
//  depuis `LocalDb`. Toute autre route continue de lever
//  `LocalPulseUnavailableError` (`Pulse/Core/PulseAPIClient.swift`), à faire
//  pour un incrément ultérieur (SpO2 report, programme…).
//
//  Portée L4 : `GET api/stats/tab-health`, `sleep-debt`, `sleep-insights`,
//  `sleep-regularity`, `tab-training` (miroir partiel), `tab-nutrition` —
//  calcul dans `Local/DashboardStats.swift` (portage de `stats.controller.ts`),
//  câblage ici seulement. Cf. l'en-tête de ce fichier pour le détail des
//  divergences assumées.
//
//  Portée L1 : `GET api/wellness/days`, `GET api/wellness/dates`.
//
//  Portée L2 : `GET api/wellness/day/:date` (dont `bodyBatteryPivot`, portage
//  du simulateur `body-battery.ts` — cf. `Local/BodyBattery.swift` et
//  `LocalDb.pivotSeries`/`bodyBatteryStart`).
//
//  Portée L3 (cf. `docs/stockage-local.md`) : `GET api/activities` (liste
//  réelle, `activities`/`LocalDb.activities(limit:offset:)`) et
//  `GET api/activities/:id` (détail — résumé + flux/segments recalculés à la
//  volée depuis le `.fit` brut retrouvé dans le spool, cf.
//  `findSpoolFileURL`/`FitActivityExtractor`, miroir de
//  `ActivitiesController.detail`). `activities`/`sportCalories` dans
//  `day/:date` restent `[]`/`0` (pas dans le périmètre de `WellnessController.day`
//  ni côté serveur, cf. commentaire déjà présent sur `LocalWellnessDayDetailDTO`).
//
//  Portée L5 : `GET`/`POST api/weight`, `DELETE api/weight/:date` — miroir de
//  `WeightController` (`weight.controller.ts`), `weight_log`/`settings`
//  ajoutées à `LocalDb`. `push` (statut de transmission vers la montre)
//  toujours à l'état neutre `idle` : le téléphone pousse le poids
//  directement (`BLEManager.requestWatchWeightWrite`), il n'y a pas de file
//  d'attente `weightPush` locale à refléter (cf. `LocalWeightPushDTO`).
//

import Foundation
import os

/// Construit le backend local par défaut de `PulseAPIClient.shared` :
/// `RealLocalPulseBackend` si `LocalDb` s'ouvre (cas normal), sinon
/// `StubLocalPulseBackend` en repli (ex. `Application Support` inaccessible)
/// — jamais un crash au lancement pour une base locale qui ne sert qu'au
/// mode Téléphone/Les deux (`StorageModeStore`), potentiellement jamais
/// activé par l'utilisateur.
enum LocalPulseBackendFactory {
    private static let log = Logger(subsystem: "CleanYourRoom.all", category: "local-backend")

    static func make() -> LocalPulseBackend {
        do {
            return try RealLocalPulseBackend()
        } catch {
            log.error("LocalDb indisponible, repli sur StubLocalPulseBackend : \(error.localizedDescription, privacy: .public)")
            return StubLocalPulseBackend()
        }
    }
}

// MARK: - Couture d'injection réseau Open Food Facts (incrément L5-Nutrition)
//
// Même principe que `PulseUploadTransport` (`Sync/PulseUploader.swift`,
// autorisation réseau active) : un protocole minimal entre
// `RealLocalPulseBackend` et `URLSession`, substitué par un test double dans
// `allTests` — AUCUN test de ce dépôt n'appelle jamais
// `URLSessionOpenFoodFactsTransport` (la seule conformance qui `.data(for:)`
// réellement, réseau AUTORISÉ explicitement par l'utilisateur, 2026-09-29).

protocol OpenFoodFactsTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Implémentation réelle — session éphémère dédiée (pas de cookies/cache
/// partagés avec `PulseAPIClient.shared`, sans rapport avec Pulse).
struct URLSessionOpenFoodFactsTransport: OpenFoodFactsTransport {
    private let session = URLSession(configuration: .ephemeral)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

final class RealLocalPulseBackend: LocalPulseBackend {
    private let db: LocalDb
    /// Source des octets bruts `.fit` pour `GET api/activities/:id`
    /// (`findSpoolFileURL`) — `nil` si `SpoolStore` n'a pas pu s'ouvrir (même
    /// politique de repli que `LocalDb`, cf. `LocalPulseBackendFactory`) :
    /// le détail retombe alors systématiquement sur la branche « fichier
    /// absent » (résumé seul), jamais un crash.
    private let spool: SpoolStore?
    /// Couture d'injection réseau Open Food Facts — même principe que
    /// `PulseUploadTransport` (`Sync/PulseUploader.swift`) : substituée par un
    /// test double dans `allTests`, jamais `URLSessionOpenFoodFactsTransport`
    /// (la seule conformance qui touche vraiment le réseau) en test.
    private let offTransport: OpenFoodFactsTransport

    init() throws {
        db = try LocalDb()
        spool = try? SpoolStore()
        offTransport = URLSessionOpenFoodFactsTransport()
    }

    /// Init testable : base (et spool, optionnel, et transport OFF factice
    /// optionnel) déjà construits (fichiers temporaires en test).
    init(db: LocalDb, spool: SpoolStore? = nil, offTransport: OpenFoodFactsTransport = URLSessionOpenFoodFactsTransport()) {
        self.db = db
        self.spool = spool
        self.offTransport = offTransport
    }

    func handle(method: String, path: String, query: [String: String], body: Data?) async throws -> Data {
        let route = path.hasPrefix("api/") ? String(path.dropFirst(4)) : path

        switch (method, route) {
        case ("GET", "wellness/dates"):
            return try JSONEncoder().encode(db.dates())

        case ("GET", "wellness/days"):
            // Même bornage que `WellnessController.days` (`limit`, 1...3660,
            // défaut 30) — `days` (fenêtre glissante en jours) n'est PAS
            // reproduit ici : en L1 l'historique local est de toute façon
            // borné à ce que le spool contient, `limit` suffit à cadrer
            // l'affichage (cf. rapport d'incrément).
            let requested = query["limit"].flatMap(Int.init) ?? 30
            let limit = min(max(requested, 1), 3660)
            let rows = try db.days(limit: limit)
            return try JSONEncoder().encode(rows.map(LocalWellnessDayRowDTO.init))

        case ("GET", "activities"):
            return try encodeActivityList(query: query)

        case ("GET", let r) where r.hasPrefix("activities/"):
            return try encodeActivityDetail(idString: String(r.dropFirst("activities/".count)))

        case ("GET", let r) where r.hasPrefix("wellness/day/"):
            let date = String(r.dropFirst("wellness/day/".count))
            return try encodeDayDetail(date: date)

        // MARK: Dashboard / Stats (incrément L4, cf. `Local/DashboardStats.swift`)
        //
        // `stats/tab-health`/`stats/sleep-debt`/`stats/sleep-insights`/
        // `stats/sleep-regularity`/`stats/tab-nutrition` : miroir fidèle.
        // `stats/tab-training` : miroir partiel (`zones` toujours vide, cf.
        // en-tête de `DashboardStats.swift`). `stats/sleep-recommendation`
        // n'est PAS servi (best-effort côté `DashboardViewModel`, `try?`) :
        // retombe sur le `default` ci-dessous, `LocalPulseUnavailableError`.

        case ("GET", "stats/tab-health"):
            return try DashboardStatsBackend.tabHealth(db: db, query: query)

        case ("GET", "stats/tab-training"):
            return try DashboardStatsBackend.tabTraining(db: db, query: query)

        case ("GET", "stats/tab-nutrition"):
            return try DashboardStatsBackend.tabNutrition(db: db, query: query)

        case ("GET", "stats/sleep-debt"):
            return try DashboardStatsBackend.sleepDebt(db: db, query: query)

        case ("GET", "stats/sleep-insights"):
            return try DashboardStatsBackend.sleepInsights(db: db, query: query)

        case ("GET", "stats/sleep-regularity"):
            return try DashboardStatsBackend.sleepRegularity(db: db, query: query)

        case ("GET", "weight"):
            return try encodeWeightList(query: query)

        case ("POST", "weight"):
            return try encodeWeightAdd(body: body)

        case ("DELETE", let r) where r.hasPrefix("weight/"):
            return try encodeWeightDelete(date: String(r.dropFirst("weight/".count)))

        // MARK: Nutrition (incrément L5-Nutrition — cf. section dédiée plus bas)

        case ("GET", let r) where r.hasPrefix("nutrition/day/"):
            return try encodeNutritionDay(date: String(r.dropFirst("nutrition/day/".count)))

        case ("GET", "nutrition/frequent"):
            return try encodeNutritionFrequent(query: query)

        case ("GET", "nutrition/foods"):
            return try encodeNutritionFoodsSearch(query: query)

        case ("POST", "nutrition/foods"):
            return try encodeNutritionFoodCreate(body: body)

        case ("PUT", let r) where r.hasPrefix("nutrition/foods/"):
            return try encodeNutritionFoodUpdate(idString: String(r.dropFirst("nutrition/foods/".count)), body: body)

        case ("POST", "nutrition/log"):
            return try encodeNutritionLogAdd(body: body)

        case ("PUT", let r) where r.hasPrefix("nutrition/log/"):
            return try encodeNutritionLogUpdate(idString: String(r.dropFirst("nutrition/log/".count)), body: body)

        case ("DELETE", let r) where r.hasPrefix("nutrition/log/"):
            return try encodeNutritionLogDelete(idString: String(r.dropFirst("nutrition/log/".count)))

        // Stubs neutres — targets/weekly/timing/suggestions non portés (cf.
        // en-tête de section « Nutrition — stubs neutres »).
        case ("GET", "nutrition/targets"):
            return try encodeNutritionTargetsStub()

        case ("GET", "nutrition/weekly"):
            return try encodeNutritionWeeklyStub()

        case ("GET", let r) where r.hasPrefix("nutrition/timing/"):
            return encodeNutritionTimingStub()

        case ("GET", let r) where r.hasPrefix("nutrition/suggestions/"):
            return try encodeNutritionSuggestionsStub()

        // Réseau Open Food Facts — SEUL réseau autorisé en mode Téléphone
        // (cf. CLAUDE.md, autorisation explicite 2026-09-29).
        case ("GET", "nutrition/search"):
            return try await encodeNutritionSearch(query: query)

        case ("GET", let r) where r.hasPrefix("nutrition/barcode/"):
            return try await encodeNutritionBarcode(code: String(r.dropFirst("nutrition/barcode/".count)))

        default:
            throw LocalPulseUnavailableError()
        }
    }

    private static let datePattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)

    private func encodeDayDetail(date: String) throws -> Data {
        let range = NSRange(date.startIndex..<date.endIndex, in: date)
        guard Self.datePattern.firstMatch(in: date, range: range) != nil else {
            throw LocalPulseUnavailableError()
        }
        let detail = try db.dayDetail(date: date)
        return try JSONEncoder().encode(LocalWellnessDayDetailDTO(detail))
    }

    // MARK: - Poids (incrément L5, miroir `WeightController` — `weight.controller.ts`)

    private static let weightMinKg = 25.0
    private static let weightMaxKg = 300.0

    /// Miroir du bornage `Math.min(Math.max(parseInt(daysParam ?? '90', 10)
    /// || 90, 7), 3660)` : `parseInt` invalide OU **nul** (`0 || 90` en JS,
    /// `0` est "falsy") retombe sur 90, pas sur 7.
    private func encodeWeightList(query: [String: String]) throws -> Data {
        let parsed = query["days"].flatMap(Int.init)
        let requested = (parsed != nil && parsed != 0) ? parsed! : 90
        let days = min(max(requested, 7), 3660)
        let list = try db.weightList(days: days)
        return try JSONEncoder().encode(LocalWeightDataDTO(list))
    }

    /// Miroir de `WeightController.add` : `date` optionnel (défaut = jour
    /// calendaire local, cf. `todayDateKey`), `kg` fini et arrondi à 0,1 kg,
    /// bornes [25, 300]. Toute violation lève (le corps JSON exact importe
    /// peu, `HealthViewModel.saveWeight` affiche un message générique sur
    /// n'importe quelle erreur).
    private func encodeWeightAdd(body: Data?) throws -> Data {
        guard let body else { throw LocalWeightValidationError(reason: "Corps de requête manquant") }
        let request = try JSONDecoder().decode(LocalWeightAddRequest.self, from: body)

        let date = request.date ?? Self.todayDateKey()
        let dateRange = NSRange(date.startIndex..<date.endIndex, in: date)
        guard Self.datePattern.firstMatch(in: date, range: dateRange) != nil else {
            throw LocalWeightValidationError(reason: "Date invalide")
        }
        guard let rawKg = request.kg, rawKg.isFinite else {
            throw LocalWeightValidationError(reason: "Poids invalide")
        }
        let kg = (rawKg * 10).rounded() / 10
        guard kg >= Self.weightMinKg && kg <= Self.weightMaxKg else {
            throw LocalWeightValidationError(
                reason: "Le poids doit être entre \(Int(Self.weightMinKg)) et \(Int(Self.weightMaxKg)) kg")
        }

        try db.upsertWeight(date: date, kg: kg)
        try db.syncWeightProfile()
        return try JSONEncoder().encode(LocalWeightSaveResultDTO(date: date, kg: kg))
    }

    /// Miroir de `WeightController.remove`.
    private func encodeWeightDelete(date: String) throws -> Data {
        let dateRange = NSRange(date.startIndex..<date.endIndex, in: date)
        guard Self.datePattern.firstMatch(in: date, range: dateRange) != nil else {
            throw LocalWeightValidationError(reason: "Date invalide")
        }
        try db.deleteWeight(date: date)
        try db.syncWeightProfile()
        return try JSONEncoder().encode(LocalWeightDeleteResultDTO(ok: true))
    }

    /// Miroir de `todayKey()`/`dateKey()` (TS, `time.ts`) : jour calendaire
    /// **local** (composants du calendrier de l'appareil), à distinguer de la
    /// coupure UTC utilisée par `LocalDb.weightList` pour `since` (même
    /// divergence de convention que le serveur entre `todayKey()` et
    /// `toISOString()`).
    private static func todayDateKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Activités (incrément L3, miroir `ActivitiesController.list`/`detail`)

    /// Même bornage que `ActivitiesController.list` (`limit` 1...500, défaut
    /// 50 ; `offset` ≥ 0, défaut 0).
    private func encodeActivityList(query: [String: String]) throws -> Data {
        let requestedLimit = query["limit"].flatMap(Int.init) ?? 50
        let limit = min(max(requestedLimit, 1), 500)
        let requestedOffset = query["offset"].flatMap(Int.init) ?? 0
        let offset = max(requestedOffset, 0)

        let total = try db.activitiesCount()
        let items = try db.activities(limit: limit, offset: offset).map(LocalActivityListItemDTO.init)
        return try JSONEncoder().encode(LocalActivityListResponseDTO(total: total, items: items))
    }

    /// Miroir de `ActivitiesController.detail` : id inconnu → erreur propre
    /// (`LocalActivityNotFoundError`, équivalent du `NotFoundException`
    /// Nest) ; id connu mais `.fit` brut introuvable dans le spool → résumé
    /// seul avec flux/segments vides (`track: []`, `streams: null`), miroir
    /// EXACT de la branche `!fs.existsSync(filePath)` côté serveur.
    private func encodeActivityDetail(idString: String) throws -> Data {
        guard let id = Int(idString), let found = try db.activity(id: id) else {
            throw LocalActivityNotFoundError(idString: idString)
        }
        guard let fileURL = findSpoolFileURL(hash: found.fileHash) else {
            return try JSONEncoder().encode(LocalActivityDetailDTO(
                row: found.row, track: [], streams: nil, laps: [], sets: [], splits: [], hrZones: []))
        }
        // Pas de garde try/catch ici : un `.fit` illisible/corrompu doit
        // remonter une erreur exploitable à l'écran (`ActivityDetailViewModel`
        // l'affiche via `error.localizedDescription`, cf. `FitDecodeError`),
        // pas un détail silencieusement vide — même esprit que le serveur, où
        // un `parseDetail` en échec produirait une exception non rattrapée.
        let data = try Data(contentsOf: fileURL)
        let file = try FitDecoder.decode(data)
        let detail = FitActivityExtractor.extractDetail(messages: file.messages)
        return try JSONEncoder().encode(LocalActivityDetailDTO(row: found.row, detail: detail))
    }

    /// Retrouve les octets bruts d'une activité par son hash — le spool
    /// (`SpoolStore.entries`) est indexé par identité MONTRE
    /// (`WatchFileID`), pas par hash de contenu, donc pas de raccourci : on
    /// hache chaque entrée à la volée (`PulseUploader.sha256Hex`, même
    /// fonction que `LocalIngestor`) jusqu'à trouver la correspondance.
    /// Coût O(n) sur le nombre d'entrées du spool — acceptable à l'échelle
    /// d'un usage personnel (dizaines à quelques centaines de fichiers), pas
    /// d'index dédié en L3.
    private func findSpoolFileURL(hash: String) -> URL? {
        guard let spool else { return nil }
        for entry in spool.entries.values {
            let url = spool.fileURL(for: entry)
            guard let entryHash = try? PulseUploader.sha256Hex(ofFileAt: url) else { continue }
            if entryHash == hash { return url }
        }
        return nil
    }

    // MARK: - Nutrition (incrément L5-Nutrition, miroir `NutritionController`
    // — `nutrition.controller.ts`)
    //
    // Portée FIDÈLE (aucun réseau) : `day/:date` (entrées + totaux — PAS les
    // cibles, cf. plus bas), `frequent`, `foods` (recherche/création/édition
    // bibliothèque), `log` (ajout/édition/suppression). Table `foods` semée
    // au premier ouverture depuis `LocalDb.seedFoods` (port de `seed-foods.ts`).
    //
    // `targets`/`remaining`/`targetRanges`/`programme` de `day/:date` :
    // TOUJOURS neutres (`null`) — le calcul de l'objectif du jour
    // (`computeDayTarget`/`target.ts`, ~640 lignes, dépend du profil/de la
    // montre/des séances) n'est PAS porté dans cet incrément, cf. section
    // « stubs neutres » plus bas. Seul `proteinPerKg` reste fidèle (dépend
    // seulement des totaux réels + `settings.weightKg`, déjà tenu à jour par
    // L5-Poids, `LocalDb.syncWeightProfile`).

    private func encodeNutritionDay(date: String) throws -> Data {
        let range = NSRange(date.startIndex..<date.endIndex, in: date)
        guard Self.datePattern.firstMatch(in: date, range: range) != nil else {
            throw LocalNutritionValidationError(reason: "Date invalide")
        }
        let rows = try db.foodLog(date: date)
        let entries = rows.map { row in
            LocalNutritionEntryDTO(
                id: row.id, name: row.name, grams: row.grams, kcal: row.kcal, protein: row.protein,
                carbs: row.carbs, fiber: row.fiber, fat: row.fat, unitLabel: row.unitLabel,
                unitQty: row.unitQty, ts: row.ts)
        }

        func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        var sumKcal = 0.0, sumProtein = 0.0, sumCarbs = 0.0, sumFiber = 0.0, sumFat = 0.0
        for row in rows {
            sumKcal += row.kcal ?? 0
            sumProtein += row.protein ?? 0
            sumCarbs += row.carbs ?? 0
            sumFiber += row.fiber ?? 0
            sumFat += row.fat ?? 0
        }
        let totals = LocalNutritionMacrosDTO(
            kcal: round1(sumKcal), protein: round1(sumProtein), carbs: round1(sumCarbs),
            fat: round1(sumFat), fiber: round1(sumFiber))

        // `proteinPerKg` — miroir de `weightKg && totals.protein ? round(...) :
        // null` (TS) : seul champ de `day()` calculable sans le portage de
        // `target.ts` (dépend juste des totaux réels + `settings.weightKg`,
        // synchronisé par L5-Poids sur chaque écriture de pesée).
        let weightKg = (try db.settingValue(key: "weightKg")).flatMap(Double.init)
        let proteinPerKg: Double?
        if let weightKg, weightKg != 0, sumProtein != 0 {
            proteinPerKg = ((sumProtein / weightKg) * 100).rounded() / 100
        } else {
            proteinPerKg = nil
        }

        let neutralMacros = LocalNutritionMacrosDTO(kcal: nil, protein: nil, carbs: nil, fat: nil, fiber: nil)
        let day = LocalNutritionDayDTO(
            date: date, entries: entries, totals: totals, targets: neutralMacros,
            targetRanges: nil, programme: nil, remaining: neutralMacros, proteinPerKg: proteinPerKg)
        return try JSONEncoder().encode(day)
    }

    /// Miroir de `NutritionController.frequent` — bornage `limit` identique
    /// (1...40, défaut 12). Le calcul (regroupement/médiane/repli pour-100 g)
    /// vit dans `LocalDb.frequentFoods(limit:)`.
    private func encodeNutritionFrequent(query: [String: String]) throws -> Data {
        let requested = query["limit"].flatMap(Int.init) ?? 12
        let limit = min(max(requested, 1), 40)
        let rows = try db.frequentFoods(limit: limit)
        let items = rows.map { row in
            LocalNutritionFrequentDTO(
                foodId: row.foodId, name: row.name, uses: row.uses, grams: row.grams, units: row.units,
                unitLabel: row.unitLabel, unitGrams: row.unitGrams, lastTs: row.lastTs,
                kcal: row.kcal, protein: row.protein, carbs: row.carbs, fiber: row.fiber, fat: row.fat)
        }
        return try JSONEncoder().encode(items)
    }

    /// Miroir de `NutritionController.foods` (recherche bibliothèque locale) —
    /// `LIKE %terme%` sur `name`, 20 résultats max.
    private func encodeNutritionFoodsSearch(query: [String: String]) throws -> Data {
        let term = (query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = try db.searchFoods(query: term)
        return try JSONEncoder().encode(rows.map(LocalNutritionFoodDTO.init))
    }

    private func encodeNutritionFoodCreate(body: Data?) throws -> Data {
        guard let body else { throw LocalNutritionValidationError(reason: "Corps de requête manquant") }
        let req = try JSONDecoder().decode(LocalNutritionFoodBodyDTO.self, from: body)
        guard let name = req.name, !name.isEmpty else { throw LocalNutritionValidationError(reason: "Missing name") }
        let unit = try resolveNutritionUnit(unitLabel: req.unitLabel, unitGrams: req.unitGrams)
        let row = try db.insertFood(
            barcode: req.barcode, name: name, kcal: req.kcal, protein: req.protein, carbs: req.carbs,
            fiber: req.fiber, fat: req.fat, unitLabel: unit.unitLabel, unitGrams: unit.unitGrams)
        return try JSONEncoder().encode(LocalNutritionFoodDTO(row))
    }

    /// Divergence mineure assumée vs `NutritionController.updateFood` : id
    /// inconnu lève ici une erreur diagnostique (`Aliment introuvable`) plutôt
    /// que de renvoyer un corps vide/`undefined` (comportement Nest non
    /// spécifié pour ce cas limite côté serveur) — plus honnête pour l'écran,
    /// qui n'appelle de toute façon `PUT` qu'avec un `pId` déjà connu.
    private func encodeNutritionFoodUpdate(idString: String, body: Data?) throws -> Data {
        guard let id = Int(idString) else { throw LocalNutritionValidationError(reason: "Invalid id") }
        guard let body else { throw LocalNutritionValidationError(reason: "Corps de requête manquant") }
        let req = try JSONDecoder().decode(LocalNutritionFoodBodyDTO.self, from: body)
        guard let name = req.name, !name.isEmpty else { throw LocalNutritionValidationError(reason: "Missing name") }
        let unit = try resolveNutritionUnit(unitLabel: req.unitLabel, unitGrams: req.unitGrams)
        guard let row = try db.updateFood(
            id: id, barcode: req.barcode, name: name, kcal: req.kcal, protein: req.protein, carbs: req.carbs,
            fiber: req.fiber, fat: req.fat, unitLabel: unit.unitLabel, unitGrams: unit.unitGrams)
        else {
            throw LocalNutritionValidationError(reason: "Aliment introuvable")
        }
        return try JSONEncoder().encode(LocalNutritionFoodDTO(row))
    }

    /// Miroir de `resolveUnit` (TS).
    private func resolveNutritionUnit(unitLabel: String?, unitGrams: Double?) throws -> (unitLabel: String?, unitGrams: Double?) {
        guard let grams = unitGrams else { return (nil, nil) }
        guard grams.isFinite, grams > 0, grams <= 2000 else {
            throw LocalNutritionValidationError(reason: "Invalid unit weight")
        }
        let label = (unitLabel ?? "").trimmingCharacters(in: .whitespaces)
        return (label.isEmpty ? "unité" : label, (grams * 10).rounded() / 10)
    }

    /// Miroir de `NutritionController.addLog` — repli sur la fiche `foods`
    /// (macros pour-100 g + unité) si `foodId` est fourni et connu, sinon les
    /// macros du corps servent telles quelles.
    private func encodeNutritionLogAdd(body: Data?) throws -> Data {
        guard let body else { throw LocalNutritionValidationError(reason: "Corps de requête manquant") }
        let req = try JSONDecoder().decode(LocalNutritionLogBodyDTO.self, from: body)
        let dateRange = NSRange(req.date.startIndex..<req.date.endIndex, in: req.date)
        guard Self.datePattern.firstMatch(in: req.date, range: dateRange) != nil else {
            throw LocalNutritionValidationError(reason: "Date invalide")
        }

        var kcal = req.kcal, protein = req.protein, carbs = req.carbs, fiber = req.fiber, fat = req.fat
        var name = req.name
        var unitLabel = req.unitLabel
        var unitGrams = req.unitGrams
        if let foodId = req.foodId, let food = try db.food(id: foodId) {
            kcal = food.kcal; protein = food.protein; carbs = food.carbs; fiber = food.fiber; fat = food.fat
            name = food.name
            if unitGrams == nil {
                unitLabel = food.unitLabel
                unitGrams = food.unitGrams
            }
        }
        guard let name, !name.isEmpty else { throw LocalNutritionValidationError(reason: "Missing name") }

        let portion = try resolveNutritionPortion(units: req.units, grams: req.grams, unitLabel: unitLabel, unitGrams: unitGrams)
        let factor = portion.grams / 100
        func scale(_ v: Double?) -> Double? { v.map { (($0 * factor) * 10).rounded() / 10 } }
        let ts = req.ts ?? Int(Date().timeIntervalSince1970)

        let id = try db.insertLog(
            date: req.date, foodId: req.foodId, name: name, grams: portion.grams,
            kcal: scale(kcal), protein: scale(protein), carbs: scale(carbs), fiber: scale(fiber), fat: scale(fat),
            unitLabel: portion.label, unitQty: portion.units, ts: ts)
        return try JSONEncoder().encode(LocalNutritionLogIdDTO(id: id))
    }

    /// Miroir de `NutritionController.updateLog` — PAS de repli `foodId`
    /// (le serveur ne le fait pas non plus sur `PUT`, seulement `POST`) : les
    /// macros du corps (pour-100 g, cf. `NutritionViewModel.editEntry`) sont
    /// utilisées telles quelles.
    private func encodeNutritionLogUpdate(idString: String, body: Data?) throws -> Data {
        guard let id = Int(idString) else { throw LocalNutritionValidationError(reason: "Invalid id") }
        guard let body else { throw LocalNutritionValidationError(reason: "Corps de requête manquant") }
        let req = try JSONDecoder().decode(LocalNutritionLogBodyDTO.self, from: body)
        guard let name = req.name, !name.isEmpty else { throw LocalNutritionValidationError(reason: "Missing name") }

        let portion = try resolveNutritionPortion(units: req.units, grams: req.grams, unitLabel: req.unitLabel, unitGrams: req.unitGrams)
        let factor = portion.grams / 100
        func scale(_ v: Double?) -> Double? { v.map { (($0 * factor) * 10).rounded() / 10 } }
        let ts = req.ts ?? Int(Date().timeIntervalSince1970)

        try db.updateLog(
            id: id, name: name, grams: portion.grams,
            kcal: scale(req.kcal), protein: scale(req.protein), carbs: scale(req.carbs), fiber: scale(req.fiber), fat: scale(req.fat),
            unitLabel: portion.label, unitQty: portion.units, ts: ts)
        return try JSONEncoder().encode(LocalNutritionOkDTO(ok: true))
    }

    private func encodeNutritionLogDelete(idString: String) throws -> Data {
        guard let id = Int(idString) else { throw LocalNutritionValidationError(reason: "Invalid id") }
        try db.deleteLog(id: id)
        return try JSONEncoder().encode(LocalNutritionOkDTO(ok: true))
    }

    /// Miroir de `resolvePortion` (TS).
    private func resolveNutritionPortion(
        units: Double?, grams: Double?, unitLabel: String?, unitGrams: Double?
    ) throws -> (grams: Double, units: Double?, label: String?) {
        if let units {
            guard units.isFinite, units > 0, units <= 200 else {
                throw LocalNutritionValidationError(reason: "Invalid units")
            }
            guard let unitGrams, unitGrams.isFinite, unitGrams > 0, unitGrams <= 2000 else {
                throw LocalNutritionValidationError(reason: "Invalid unit weight")
            }
            let gramsValue = (units * unitGrams * 10).rounded() / 10
            guard gramsValue > 0, gramsValue <= 5000 else { throw LocalNutritionValidationError(reason: "Invalid grams") }
            let label = (unitLabel ?? "").trimmingCharacters(in: .whitespaces)
            return (gramsValue, units, label.isEmpty ? "unité" : label)
        }
        guard let grams, grams > 0, grams <= 5000 else { throw LocalNutritionValidationError(reason: "Invalid grams") }
        return (grams, nil, nil)
    }

    // MARK: - Nutrition — stubs neutres (`targets`/`weekly`/`timing`/`suggestions`)
    //
    // NON portés dans cet incrément : `target.ts` (~640 lignes, profil +
    // montre + séances + programme) calcule l'objectif calorique/macros
    // automatique dont dépendent `targets`, `weekly` (moyenne 7 j vs objectif)
    // et indirectement `suggestions` (a besoin d'un reliquat). `timing`
    // corrèle le dernier repas au stress ambiant — capteur de stress existe
    // localement (`wellness_samples`) mais la fenêtre de calcul n'est pas
    // portée non plus. Réponses ci-dessous : formes JSON MINIMALES qui
    // décodent dans les modèles réels de l'écran (`NutritionTargetInfo`,
    // `NutritionWeekly`, `NutritionTimingResponse`, `NutritionSuggestionsResponse`)
    // sans jamais fabriquer de valeur — tout ce qui serait un résultat de
    // calcul non fait est `null`/vide, jamais un `0` qui se ferait passer
    // pour un vrai objectif. `NutritionView` gère déjà ces formes sans rendu
    // trompeur : `status == "unavailable"` bascule la carte Objectif sur
    // « — kcal » (branche déjà existante, utilisée aussi côté serveur quand
    // le profil est incomplet) ; `suggestions.items == []` masque la carte
    // Suggestions ; `timing.meal == nil` ne change rien (champ non lu par
    // `NutritionView`, qui recalcule sa propre frise depuis `day.entries`).
    // À faire dans un futur incrément dédié (« L5-Nutrition-analytics ») :
    // portage de `target.ts`/`computeWeekly`/`timing`/`suggestions` réels.

    private func encodeNutritionTargetsStub() throws -> Data {
        try JSONEncoder().encode(LocalNutritionTargetsStubDTO())
    }

    /// `thresholdKcal` (seul champ non-optionnel sans repli honnête à `0`) =
    /// `DEFAULT_TARGET_SETTINGS.weeklyAlertKcal` (target.ts) — la seule
    /// valeur qui ne fabrique rien : c'est le SEUIL par défaut, pas un
    /// résultat de calcul.
    private func encodeNutritionWeeklyStub() throws -> Data {
        try JSONEncoder().encode(LocalNutritionWeeklyStubDTO())
    }

    /// `{"meal": null}` — forme exacte que renvoie aussi le serveur quand
    /// aucun repas n'a d'horodatage dans la fenêtre (`if (!last) return {meal:
    /// null}`), donc pas seulement un stub dégradé : c'est un état réel valide
    /// du contrat. `NutritionTimingResponse.meal` est `Optional`.
    private func encodeNutritionTimingStub() -> Data {
        Data(#"{"meal": null}"#.utf8)
    }

    /// `reason: "no-targets"` — forme exacte renvoyée par le serveur quand
    /// aucune cible n'est calculable (`remaining.kcal == null && remaining.protein
    /// == null`), qui est TOUJOURS notre cas ici puisque les cibles ne sont
    /// jamais calculées localement.
    private func encodeNutritionSuggestionsStub() throws -> Data {
        try JSONEncoder().encode(LocalNutritionSuggestionsStubDTO(
            remaining: LocalNutritionMacrosDTO(kcal: nil, protein: nil, carbs: nil, fat: nil, fiber: nil),
            items: [], reason: "no-targets"))
    }

    // MARK: - Nutrition — Open Food Facts (Part B, réseau AUTORISÉ)
    //
    // Seul réseau du backend local — autorisation explicite utilisateur
    // (2026-09-29, cf. CLAUDE.md), déclenché uniquement par une action de
    // l'utilisateur dans l'écran Nutrition (recherche en ligne / scan). Même
    // URL/champs/en-têtes que `NutritionController.searchOpenFoodFacts`/
    // `fetchOpenFoodFacts` (TS) — copie fidèle, PAS de réinvention.
    //
    // Dégradation choisie (décision de cet incrément, cf. rapport) :
    // `search` reste SILENCIEUSE sur tout échec (miroir exact du
    // `try {...} catch { return [] }` serveur — `searchOnline()` afficherait
    // sinon « Aucun résultat » à tort en cas de coupure réseau, mais c'est le
    // comportement serveur reproduit fidèlement ici) ; `barcode` en revanche
    // LÈVE sur un échec réseau/HTTP/décodage (`lookupBarcode()` affiche déjà
    // un message dédié dans ce cas, cf. `NutritionViewModel.lookupBarcode`) —
    // seul un résultat OFF « produit inconnu » légitime (`status != 1`) reste
    // un `{found:false}` gracieux, jamais une erreur.

    private static let openFoodFactsUserAgent = "Pulse/1.0 (self-hosted)"

    private func encodeNutritionSearch(query: [String: String]) async throws -> Data {
        let term = (query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return try JSONEncoder().encode([LocalNutritionOffFoodDTO]()) }
        let products = await searchOpenFoodFacts(term: term)
        return try JSONEncoder().encode(products)
    }

    /// Miroir de `NutritionController.searchOpenFoodFacts` (TS) — même URL
    /// (`search.openfoodfacts.org/search`), mêmes champs, même en-tête
    /// `User-Agent`, même délai (7 s), même dédoublonnage par nom
    /// insensible à la casse, même plafond (20 résultats). Silencieux sur
    /// tout échec (transport, statut HTTP, décodage) — jamais lancé, cf.
    /// en-tête de section. Passe par `offTransport` (injectable en test),
    /// jamais `URLSession` directement.
    private func searchOpenFoodFacts(term: String) async -> [LocalNutritionOffFoodDTO] {
        guard var components = URLComponents(string: "https://search.openfoodfacts.org/search") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "langs", value: "fr"),
            URLQueryItem(name: "page_size", value: "50"),
            URLQueryItem(name: "fields", value: "code,product_name,nutriments,serving_quantity"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(Self.openFoodFactsUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 7

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await offTransport.data(for: request)
        } catch {
            return []
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        guard let decoded = try? JSONDecoder().decode(OffSearchResponseDTO.self, from: data) else { return [] }

        var seen = Set<String>()
        var out: [LocalNutritionOffFoodDTO] = []
        for hit in decoded.hits ?? [] {
            guard out.count < 20 else { break }
            let name = (hit.productName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let kcal = hit.nutriments?.energyKcal100g else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let serving = Self.servingGrams(hit.servingQuantity?.value)
            out.append(LocalNutritionOffFoodDTO(
                barcode: hit.code, name: name, kcal: kcal, protein: hit.nutriments?.proteins100g,
                carbs: hit.nutriments?.carbohydrates100g, fiber: hit.nutriments?.fiber100g, fat: hit.nutriments?.fat100g,
                unitLabel: serving != nil ? "portion" : nil, unitGrams: serving))
        }
        return out
    }

    /// Miroir de `NutritionController.barcode` — code-barres déjà connu en
    /// bibliothèque locale d'abord (`source: "local"`, aucun réseau), sinon
    /// Open Food Facts (`source: "openfoodfacts"`, aliment créé en
    /// bibliothèque sur trouvaille — miroir exact de `createFood` serveur).
    private func encodeNutritionBarcode(code: String) async throws -> Data {
        guard code.range(of: "^[0-9]{6,14}$", options: .regularExpression) != nil else {
            throw LocalNutritionValidationError(reason: "Invalid barcode")
        }
        if let local = try db.food(barcode: code) {
            return try JSONEncoder().encode(LocalNutritionBarcodeResultDTO(found: true, source: "local", food: LocalNutritionFoodDTO(local)))
        }
        guard let off = try await fetchOpenFoodFacts(code: code) else {
            return try JSONEncoder().encode(LocalNutritionBarcodeResultDTO(found: false, source: nil, food: nil))
        }
        let created = try db.insertFood(
            barcode: code, name: off.name, kcal: off.kcal, protein: off.protein, carbs: off.carbs,
            fiber: off.fiber, fat: off.fat, unitLabel: off.unitLabel, unitGrams: off.unitGrams)
        return try JSONEncoder().encode(LocalNutritionBarcodeResultDTO(found: true, source: "openfoodfacts", food: LocalNutritionFoodDTO(created)))
    }

    /// Miroir de `NutritionController.fetchOpenFoodFacts` (TS) — même URL
    /// (`world.openfoodfacts.org/api/v2/product/{code}.json`), mêmes champs,
    /// même en-tête, même délai (6 s). Diverge volontairement du serveur en
    /// LEVANT sur un échec transport/HTTP/décodage (cf. en-tête de section) —
    /// seul `status != 1`/produit absent (« vraiment pas trouvé ») renvoie
    /// `nil` proprement. Passe par `offTransport` (injectable en test).
    private func fetchOpenFoodFacts(code: String) async throws -> LocalNutritionOffFoodDTO? {
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(code).json?fields=product_name,nutriments,serving_quantity") else {
            throw LocalNutritionValidationError(reason: "Code-barres invalide")
        }
        var request = URLRequest(url: url)
        request.setValue(Self.openFoodFactsUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 6

        let (data, response) = try await offTransport.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalNutritionNetworkError(status: (response as? HTTPURLResponse)?.statusCode)
        }
        let decoded = try JSONDecoder().decode(OffProductResponseDTO.self, from: data)
        guard decoded.status == 1, let product = decoded.product else { return nil }

        let trimmedName = product.productName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (trimmedName?.isEmpty == false) ? trimmedName! : "Produit \(code)"
        let serving = Self.servingGrams(product.servingQuantity?.value)
        return LocalNutritionOffFoodDTO(
            barcode: nil, name: name, kcal: product.nutriments?.energyKcal100g, protein: product.nutriments?.proteins100g,
            carbs: product.nutriments?.carbohydrates100g, fiber: product.nutriments?.fiber100g, fat: product.nutriments?.fat100g,
            unitLabel: serving != nil ? "portion" : nil, unitGrams: serving)
    }

    /// Miroir de `servingGrams` (TS).
    private static func servingGrams(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, raw > 0, raw <= 2000 else { return nil }
        return (raw * 10).rounded() / 10
    }
}

/// `GET api/activities/:id` sur un id inconnu (absent de `activities`, ou
/// segment non numérique) — miroir de `NotFoundException()` côté Nest
/// (`ActivitiesController.detail`). Message stable, affiché tel quel par
/// `ActivityDetailViewModel` (`error.localizedDescription`).
struct LocalActivityNotFoundError: Error, LocalizedError {
    let idString: String
    var errorDescription: String? { "Activité introuvable (\(idString))." }
}

/// `POST api/weight`/`DELETE api/weight/:date` sur une entrée invalide —
/// miroir du `BadRequestException` côté Nest (`WeightController`). Message
/// diagnostique seulement : l'écran affiche son propre message générique
/// (« Poids refusé… ») sur n'importe quelle erreur, cf. `HealthViewModel.saveWeight`.
struct LocalWeightValidationError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// DTO d'encodage JSON — mêmes clés que `WellnessDayRow`
/// (`Pulse/Screens/Health/HealthModels.swift`) et son sous-ensemble
/// `DashboardWellnessDayRow` (`Pulse/Screens/Dashboard/DashboardModels.swift`),
/// pour que `PulseAPIClient.decoder` décode ce JSON exactement comme une
/// réponse serveur — les écrans ne savent jamais que la réponse vient d'ici.
/// `bodyBatteryHigh`/`bodyBatteryLow`/`sportCalories` : toujours absents
/// (`nil`, encodés comme `null`) — non implémentés en L1 (cf. rapport :
/// nécessitent respectivement le simulateur "pivot" et les activités,
/// `wellness/body-battery.ts`, `activities` table — L3+/L4). Les deux
/// modèles côté écran les typent `Optional`, `null` décode donc sans erreur.
private struct LocalWellnessDayRowDTO: Encodable {
    let date: String
    let restingHr: Double?
    let bmrKcal: Double?
    let steps: Double?
    let activeCalories: Double?
    let distanceM: Double?
    let minHr: Double?
    let maxHr: Double?
    let avgStress: Double?
    let bodyBatteryHigh: Double?
    let bodyBatteryLow: Double?
    let sleepDurationS: Double?
    let sleepScore: Double?
    let sportCalories: Double?

    init(_ row: LocalDb.DayRow) {
        date = row.date
        restingHr = row.restingHr
        bmrKcal = row.bmrKcal
        steps = row.steps
        activeCalories = row.activeCalories
        distanceM = row.distanceM
        minHr = row.minHr
        maxHr = row.maxHr
        avgStress = row.avgStress
        bodyBatteryHigh = nil
        bodyBatteryLow = nil
        sleepDurationS = row.sleepDurationS
        sleepScore = row.sleepScore
        sportCalories = nil
    }
}

// MARK: - DTO d'encodage JSON — `GET wellness/day/:date` (incrément L2)
//
// Même forme que le corps renvoyé par `WellnessController.day` — mêmes clés
// que `WellnessDayDetail`/`WellnessDaySummary`/`WellnessDaySleep`/`WellnessSample`
// (`Pulse/Screens/Health/HealthModels.swift`), consommées aussi par le
// sous-ensemble `HomeDayDetail` de l'Accueil (`Pulse/Screens/Home/HomeModels.swift`
// — mêmes clés, moins `summary.bodyBattery*`/`sportCalories`, `bodyBatteryPivot`,
// `activities`, `counterSeries`, ignorées par `Decodable` si présentes).

private struct LocalSampleDTO: Encodable {
    let ts: Double
    let value: Double
}

private struct LocalCounterPointDTO: Encodable {
    let minute: Int
    let steps: Double
    let activeCalories: Double
}

private struct LocalSleepIntervalDTO: Encodable {
    let from: Double
    let to: Double
}

private struct LocalSleepStageDTO: Encodable {
    let from: Double
    let to: Double
    let stage: String
}

private struct LocalSleepMainDTO: Encodable {
    let from: Double
    let to: Double
    let durationS: Double
}

private struct LocalDaySleepDTO: Encodable {
    let segments: [LocalSleepIntervalDTO]
    let main: LocalSleepMainDTO?
    let stages: [LocalSleepStageDTO]
    let score: Double?
}

/// Toujours `[]`, MÊME après L3 : `WellnessController.day` peuple ce champ
/// via `activityIntervals` (une requête par plage horaire sur `activities`,
/// distincte de `ActivitiesController.list`/`detail`) — non porté ici, hors
/// périmètre explicite de la tâche d'incrément L3 (qui ne couvre QUE
/// `api/activities`/`api/activities/:id`, cf. rapport). Lacune connue,
/// assumée : le bloc « activités du jour » de `wellness/day/:date` reste
/// vide en mode Téléphone tant qu'un futur incrément ne porte pas
/// `activityIntervals`. Le type existe (plutôt qu'un `[Int]` vide arbitraire)
/// pour rester prêt côté forme JSON ce jour-là.
private struct LocalActivityDTO: Encodable {
    let id: Int
    let sport: String?
    let subSport: String?
    let startTs: Double
    let durationS: Double?
    let calories: Double?
}

/// `bodyBatteryHigh`/`bodyBatteryLow` : toujours `nil` — miroir fidèle du
/// serveur, qui ne les calcule PAS dans `day()` (contrairement à `days()`) ;
/// la colonne `wellness_days.body_battery_high/low` d'où ils viendraient
/// sinon n'est écrite nulle part côté ingestion serveur non plus (vérifié :
/// aucun `INSERT`/`UPDATE` sur ces colonnes dans `custom-connect/server/src`).
private struct LocalWellnessDaySummaryDTO: Encodable {
    let restingHr: Double?
    let bmrKcal: Double?
    let bodyBatteryHigh: Double?
    let bodyBatteryLow: Double?
    let steps: Double?
    let activeCalories: Double?
    let distanceM: Double?
    let sportCalories: Double?
}

private struct LocalWellnessDayDetailDTO: Encodable {
    let date: String
    let summary: LocalWellnessDaySummaryDTO
    let counterSeries: [LocalCounterPointDTO]
    let hr: [LocalSampleDTO]
    let stress: [LocalSampleDTO]
    let spo2: [LocalSampleDTO]
    let respiration: [LocalSampleDTO]
    let bodyBatteryPivot: [LocalSampleDTO]
    let activities: [LocalActivityDTO]
    let sleep: LocalDaySleepDTO

    init(_ detail: LocalDb.DayDetail) {
        date = detail.date
        summary = LocalWellnessDaySummaryDTO(
            restingHr: detail.restingHr, bmrKcal: detail.bmrKcal,
            bodyBatteryHigh: nil, bodyBatteryLow: nil,
            steps: detail.steps, activeCalories: detail.activeCalories, distanceM: detail.distanceM,
            // Toujours 0, MÊME après L3 : même lacune assumée que le champ
            // `activities` ci-dessus (`sportCalories` serveur vient de
            // `activityIntervals`/la même requête bornée par plage horaire,
            // non portée ici) — cf. commentaire de `LocalActivityDTO`.
            sportCalories: 0)
        counterSeries = detail.counterSeries.map {
            LocalCounterPointDTO(minute: $0.minute, steps: $0.steps, activeCalories: $0.activeCalories)
        }
        hr = detail.hr.map { LocalSampleDTO(ts: $0.ts, value: $0.value) }
        stress = detail.stress.map { LocalSampleDTO(ts: $0.ts, value: $0.value) }
        spo2 = detail.spo2.map { LocalSampleDTO(ts: $0.ts, value: $0.value) }
        respiration = detail.respiration.map { LocalSampleDTO(ts: $0.ts, value: $0.value) }
        bodyBatteryPivot = detail.bodyBatteryPivot.map { LocalSampleDTO(ts: $0.ts, value: $0.value) }
        activities = []
        sleep = LocalDaySleepDTO(
            segments: detail.sleepSegments.map { LocalSleepIntervalDTO(from: $0.from, to: $0.to) },
            main: detail.sleepMain.map { LocalSleepMainDTO(from: $0.from, to: $0.to, durationS: $0.durationS) },
            stages: detail.sleepStages.map { LocalSleepStageDTO(from: $0.from, to: $0.to, stage: $0.stage) },
            score: detail.sleepScore)
    }
}

// MARK: - DTO d'encodage JSON — `GET/POST/DELETE api/weight` (incrément L5)
//
// Mêmes clés que `WeightData`/`WeightSeriesPoint`/`WeightPush`/`WeightSaveResult`
// (`Pulse/Screens/Health/HealthModels.swift`) — `minKg`/`maxKg`/`rangeDays` en
// plus, ignorés silencieusement par `Decodable` (mêmes clés que la réponse
// serveur, gardées pour fidélité au miroir plutôt qu'utilité côté écran).

/// `push` : toujours à l'état neutre `idle`/`nil`/`nil` — le backend local ne
/// pousse RIEN vers la montre lui-même (le téléphone écrit directement via
/// `BLEManager.requestWatchWeightWrite`, indépendamment du mode de stockage,
/// cf. `HealthViewModel.saveWeight`) ; il n'y a donc jamais de file d'attente
/// `weightPush` locale à refléter ici. Renvoyer autre chose qu'`idle`
/// inventerait un statut de transmission qui n'existe pas côté backend local.
private struct LocalWeightPushDTO: Encodable {
    let status: String
    let kg: Double?
    let at: String?
}

private struct LocalWeightSeriesPointDTO: Encodable {
    let date: String
    let kg: Double
    let avg: Double
}

private struct LocalWeightDataDTO: Encodable {
    let current: Double?
    let currentDate: String?
    let deltaKg: Double?
    let minKg: Double?
    let maxKg: Double?
    let entries: Int
    let rangeDays: Int
    let series: [LocalWeightSeriesPointDTO]
    let push: LocalWeightPushDTO

    init(_ list: LocalDb.WeightList) {
        current = list.current
        currentDate = list.currentDate
        deltaKg = list.deltaKg
        minKg = list.minKg
        maxKg = list.maxKg
        entries = list.entries
        rangeDays = list.rangeDays
        series = list.series.map { LocalWeightSeriesPointDTO(date: $0.date, kg: $0.kg, avg: $0.avg) }
        push = LocalWeightPushDTO(status: "idle", kg: nil, at: nil)
    }
}

/// Corps de `POST api/weight` — miroir de `{ date?: string; kg?: number }`
/// (TS). Champs optionnels : la validation (`encodeWeightAdd`) distingue
/// "absent" (→ défaut/erreur dédiée) de "présent mais invalide".
private struct LocalWeightAddRequest: Decodable {
    let date: String?
    let kg: Double?
}

private struct LocalWeightSaveResultDTO: Encodable {
    let date: String
    let kg: Double
}

private struct LocalWeightDeleteResultDTO: Encodable {
    let ok: Bool
}

// MARK: - DTO d'encodage JSON — `GET api/activities`/`GET api/activities/:id` (incrément L3)
//
// Mêmes clés que `Activity`/`ActivityListResponse`/`ActivityStreams`/
// `ActivityLap`/`ActivitySet`/`ActivitySplit`/`HrZone`/`ActivityDetail`
// (`Pulse/Screens/Activities/ActivityModels.swift`) — et, pour la LISTE
// (`id`/`startTime`/`durationS`, sous-ensemble), du `HomeActivity` de
// l'Accueil (`Pulse/Screens/Home/HomeModels.swift`), qui tape la MÊME route.

private struct LocalActivityListItemDTO: Encodable {
    let id: Int
    let fileName: String
    let sport: String?
    let subSport: String?
    let startTime: String?
    let durationS: Double?
    let distanceM: Double?
    let calories: Double?
    let avgHr: Double?
    let maxHr: Double?

    init(_ row: LocalDb.ActivityRow) {
        id = row.id
        fileName = row.fileName
        sport = row.sport
        subSport = row.subSport
        startTime = row.startTime
        durationS = row.durationS
        distanceM = row.distanceM
        calories = row.calories
        avgHr = row.avgHr
        maxHr = row.maxHr
    }
}

private struct LocalActivityListResponseDTO: Encodable {
    let total: Int
    let items: [LocalActivityListItemDTO]
}

private struct LocalActivityStreamsDTO: Encodable {
    let time: [Double?]
    let hr: [Double?]
    let speed: [Double?]
    let altitude: [Double?]
    let distance: [Double?]

    init(_ streams: FitActivityExtractor.Streams) {
        time = streams.time
        hr = streams.hr
        speed = streams.speed
        altitude = streams.altitude
        distance = streams.distance
    }
}

private struct LocalActivityLapDTO: Encodable {
    let index: Int
    let durationS: Double?
    let distanceM: Double?
    let avgHr: Double?
    let maxHr: Double?

    init(_ lap: FitActivityExtractor.Lap) {
        index = lap.index
        durationS = lap.durationS
        distanceM = lap.distanceM
        avgHr = lap.avgHr
        maxHr = lap.maxHr
    }
}

private struct LocalActivitySetDTO: Encodable {
    let index: Int
    let durationS: Double?
    let category: String?
    let repetitions: Double?

    init(_ set: FitActivityExtractor.SetRow) {
        index = set.index
        durationS = set.durationS
        category = set.category
        repetitions = set.repetitions
    }
}

private struct LocalActivitySplitDTO: Encodable {
    let index: Int
    let type: String?
    let durationS: Double?
    let ascentM: Double?
    let descentM: Double?
    let calories: Double?
    let avgVertSpeedMs: Double?

    init(_ split: FitActivityExtractor.Split) {
        index = split.index
        type = split.type
        durationS = split.durationS
        ascentM = split.ascentM
        descentM = split.descentM
        calories = split.calories
        avgVertSpeedMs = split.avgVertSpeedMs
    }
}

private struct LocalHrZoneDTO: Encodable {
    let zone: Int
    let seconds: Double
    let fromBpm: Double?
    let toBpm: Double?

    init(_ zone: FitActivityExtractor.HrZoneRow) {
        self.zone = zone.zone
        seconds = zone.seconds
        fromBpm = zone.fromBpm
        toBpm = zone.toBpm
    }
}

/// `GET api/activities/:id` — résumé (`row`) + flux/segments. `track` reste
/// TOUJOURS `[]` (décision actée de l'incrément L3, cf. en-tête de
/// `FitActivityExtractor.swift`) ; `streams` est `nil` uniquement quand le
/// `.fit` brut n'a pas été retrouvé dans le spool (miroir de la branche
/// `!fs.existsSync` côté serveur), jamais dans le cas contraire.
private struct LocalActivityDetailDTO: Encodable {
    let id: Int
    let fileName: String
    let sport: String?
    let subSport: String?
    let startTime: String?
    let durationS: Double?
    let distanceM: Double?
    let calories: Double?
    let avgHr: Double?
    let maxHr: Double?
    let track: [[Double]]
    let streams: LocalActivityStreamsDTO?
    let laps: [LocalActivityLapDTO]
    let sets: [LocalActivitySetDTO]
    let splits: [LocalActivitySplitDTO]
    let hrZones: [LocalHrZoneDTO]

    /// Fichier brut introuvable dans le spool — résumé seul, tout le reste vide/`nil`.
    init(row: LocalDb.ActivityRow, track: [[Double]], streams: LocalActivityStreamsDTO?,
         laps: [LocalActivityLapDTO], sets: [LocalActivitySetDTO], splits: [LocalActivitySplitDTO],
         hrZones: [LocalHrZoneDTO]) {
        id = row.id
        fileName = row.fileName
        sport = row.sport
        subSport = row.subSport
        startTime = row.startTime
        durationS = row.durationS
        distanceM = row.distanceM
        calories = row.calories
        avgHr = row.avgHr
        maxHr = row.maxHr
        self.track = track
        self.streams = streams
        self.laps = laps
        self.sets = sets
        self.splits = splits
        self.hrZones = hrZones
    }

    /// Fichier brut retrouvé et reparsé — `detail` vient de
    /// `FitActivityExtractor.extractDetail`.
    init(row: LocalDb.ActivityRow, detail: FitActivityExtractor.Detail) {
        self.init(
            row: row, track: detail.track,
            streams: LocalActivityStreamsDTO(detail.streams),
            laps: detail.laps.map(LocalActivityLapDTO.init),
            sets: detail.sets.map(LocalActivitySetDTO.init),
            splits: detail.splits.map(LocalActivitySplitDTO.init),
            hrZones: detail.hrZones.map(LocalHrZoneDTO.init))
    }
}

// MARK: - Erreurs Nutrition (incrément L5-Nutrition)

/// Erreur de validation générique des routes `nutrition/*` — miroir du
/// `BadRequestException` côté Nest (`NutritionController`). Message
/// diagnostique seulement, cf. `LocalWeightValidationError` (même esprit).
struct LocalNutritionValidationError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// `GET api/nutrition/barcode/:code` sur un échec réseau/HTTP/décodage Open
/// Food Facts — PAS un `{found:false}` gracieux (réservé au cas « produit
/// vraiment absent d'OFF »), cf. en-tête de section Open Food Facts.
struct LocalNutritionNetworkError: Error, LocalizedError {
    let status: Int?
    var errorDescription: String? {
        "Open Food Facts injoignable" + (status.map { " (HTTP \($0))" } ?? "")
    }
}

// MARK: - DTO d'encodage JSON — Nutrition (incrément L5-Nutrition)
//
// Mêmes clés que `NutritionMacros`/`NutritionMacroRange`/`NutritionProgrammeRef`/
// `NutritionEntry`/`NutritionDay`/`NutritionFrequentFood`/`NutritionFoodLite`/
// `NutritionTargetInfo`/`NutritionAutoTarget`/`NutritionMacroPlan`/
// `NutritionAutoDetail`/`NutritionWeekly`/`NutritionSuggestionsResponse`/
// `NutritionSuggestionItem`/`NutritionBarcodeResult`
// (`Pulse/Screens/Nutrition/NutritionModels.swift`, `NutritionScanView.swift`).

private struct LocalNutritionMacrosDTO: Encodable {
    let kcal: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let fiber: Double?
}

private struct LocalNutritionEntryDTO: Encodable {
    let id: Int
    let name: String
    let grams: Double
    let kcal: Double?
    let protein: Double?
    let carbs: Double?
    let fiber: Double?
    let fat: Double?
    let unitLabel: String?
    let unitQty: Double?
    let ts: Int?
}

private struct LocalNutritionMacroRangeDTO: Encodable {
    let min: Double?
    let max: Double?
}

private struct LocalNutritionProgrammeRefDTO: Encodable {
    let name: String
}

/// `targetSource` gardé pour fidélité de forme JSON (présent côté serveur,
/// ignoré par `NutritionDay`, qui ne le modélise pas) — toujours `"manual"`
/// ici puisque `targets` est toujours neutre (cf. `encodeNutritionDay`).
/// `targetRanges`/`programme` toujours `nil` (même raison).
private struct LocalNutritionDayDTO: Encodable {
    let date: String
    let entries: [LocalNutritionEntryDTO]
    let totals: LocalNutritionMacrosDTO
    let targets: LocalNutritionMacrosDTO
    let targetSource = "manual"
    let targetRanges: [String: LocalNutritionMacroRangeDTO]?
    let programme: LocalNutritionProgrammeRefDTO?
    let remaining: LocalNutritionMacrosDTO
    let proteinPerKg: Double?
}

private struct LocalNutritionFrequentDTO: Encodable {
    let foodId: Int?
    let name: String
    let uses: Int
    let grams: Double
    let units: Double?
    let unitLabel: String?
    let unitGrams: Double?
    let lastTs: Int?
    let kcal: Double?
    let protein: Double?
    let carbs: Double?
    let fiber: Double?
    let fat: Double?
}

/// Fiche « bibliothèque locale » — TOUJOURS un `id` (vient de `foods`),
/// contrairement à `LocalNutritionOffFoodDTO` (résultat de recherche en
/// ligne, jamais encore enregistré).
private struct LocalNutritionFoodDTO: Encodable {
    let id: Int
    let barcode: String?
    let name: String
    let kcal: Double?
    let protein: Double?
    let carbs: Double?
    let fiber: Double?
    let fat: Double?
    let unitLabel: String?
    let unitGrams: Double?

    init(_ row: LocalDb.FoodRow) {
        id = row.id
        barcode = row.barcode
        name = row.name
        kcal = row.kcal
        protein = row.protein
        carbs = row.carbs
        fiber = row.fiber
        fat = row.fat
        unitLabel = row.unitLabel
        unitGrams = row.unitGrams
    }
}

/// Corps de `POST/PUT api/nutrition/foods` — miroir de `Partial<Food>` (TS,
/// `NutritionFoodCreateRequest` côté client). `name` décodé `String?` (pas
/// `String`) pour distinguer explicitement « absent » de « chaîne vide »,
/// les deux étant rejetés par `guard let name, !name.isEmpty` (même logique
/// que `!body.name` en JS, qui rejette aussi les deux).
private struct LocalNutritionFoodBodyDTO: Decodable {
    let name: String?
    let barcode: String?
    let kcal: Double?
    let protein: Double?
    let carbs: Double?
    let fiber: Double?
    let fat: Double?
    let unitLabel: String?
    let unitGrams: Double?
}

/// Corps de `POST/PUT api/nutrition/log` — miroir de `LogBody` (TS,
/// `NutritionLogRequest` côté client). `date` non-optionnel (toujours
/// présent, `PUT` l'ignore simplement) ; `name` optionnel pour la même
/// raison que `LocalNutritionFoodBodyDTO`.
private struct LocalNutritionLogBodyDTO: Decodable {
    let date: String
    let name: String?
    let foodId: Int?
    let grams: Double?
    let units: Double?
    let unitLabel: String?
    let unitGrams: Double?
    let kcal: Double?
    let protein: Double?
    let carbs: Double?
    let fiber: Double?
    let fat: Double?
    let ts: Int?
}

private struct LocalNutritionLogIdDTO: Encodable {
    let id: Int
}

/// Réponse `{ok:true}` de `PUT/DELETE api/nutrition/log/:id` — structure
/// dédiée plutôt que la réutilisation de `LocalWeightDeleteResultDTO` (même
/// forme, mais types distincts par prudence : pas de couplage accidentel
/// entre Poids et Nutrition si l'un évolue).
private struct LocalNutritionOkDTO: Encodable {
    let ok: Bool
}

// MARK: - DTO d'encodage JSON — Nutrition, stubs neutres
// (`targets`/`weekly`/`suggestions` — cf. section d'implémentation)

/// Miroir de `NutritionMacroProgrammePlan{name, unmet}` — jamais instancié
/// non-`nil` ici (`LocalNutritionMacroPlanStubDTO.programme` reste `nil`).
private struct LocalNutritionMacroProgrammeStubDTO: Encodable {
    let name: String
    let unmet: [String]
}

private struct LocalNutritionMacroPlanStubDTO: Encodable {
    let proteinG: Double? = nil
    let fatG: Double? = nil
    let carbsG: Double? = nil
    let fiberG: Double? = nil
    let proteinPerKg: Double? = nil
    let programme: LocalNutritionMacroProgrammeStubDTO? = nil
}

private struct LocalNutritionAutoDetailStubDTO: Encodable {
    let restingKcal: Double? = nil
    let activeKcal: Double? = nil
}

private struct LocalNutritionAutoTargetStubDTO: Encodable {
    let status = "unavailable"
    let source = "formula"
    let missing: [String] = []
    let targetKcal: Double? = nil
    let expenditureKcal: Double? = nil
    let deficitKcal: Double? = nil
    let macros = LocalNutritionMacroPlanStubDTO()
    let guardStatus = "none"
    let detail = LocalNutritionAutoDetailStubDTO()

    enum CodingKeys: String, CodingKey {
        case status, source, missing, targetKcal, expenditureKcal, deficitKcal, macros, detail
        case guardStatus = "guard"
    }
}

private struct LocalNutritionTargetsStubDTO: Encodable {
    let mode = "manual"
    let targets = LocalNutritionMacrosDTO(kcal: nil, protein: nil, carbs: nil, fat: nil, fiber: nil)
    let source = "manual"
    let auto = LocalNutritionAutoTargetStubDTO()
}

private struct LocalNutritionWeeklyStubDTO: Encodable {
    let loggedDays = 0
    let partialDays = 0
    let emptyDays = 0
    let avgDeficitKcal: Double? = nil
    let alert = false
    /// `DEFAULT_TARGET_SETTINGS.weeklyAlertKcal` (`target.ts`) — seuil par
    /// défaut, pas un résultat de calcul (cf. `encodeNutritionWeeklyStub`).
    let thresholdKcal: Double = 600
}

private struct LocalNutritionSuggestionsStubDTO: Encodable {
    let remaining: LocalNutritionMacrosDTO
    let items: [Int] // toujours vide — le type de l'élément n'importe pas.
    let reason: String?
}

// MARK: - DTO d'encodage/décodage JSON — Open Food Facts

/// `serving_quantity` OFF est documenté `number | string` côté serveur
/// (`parseFloat` appliqué si chaîne) — décodage tolérant aux deux formes.
private struct OffFlexibleDouble: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = Double(s)
        } else {
            value = nil
        }
    }
}

/// Sous-ensemble de `nutriments` OFF qu'on consomme réellement — décodage
/// champ par champ (chaque `try?` avale un `typeMismatch` isolé) plutôt que
/// `[String: Double]` global, qui échouerait en bloc si UNE seule clé du
/// dictionnaire (potentiellement volumineux et hétérogène côté OFF) n'est
/// pas numérique. Miroir du `num()` de garde côté TS (`typeof v === 'number'`
/// → sinon `null`), pas une simplification.
private struct OffNutrimentsDTO: Decodable {
    let energyKcal100g: Double?
    let proteins100g: Double?
    let carbohydrates100g: Double?
    let fiber100g: Double?
    let fat100g: Double?

    enum CodingKeys: String, CodingKey {
        case energyKcal100g = "energy-kcal_100g"
        case proteins100g = "proteins_100g"
        case carbohydrates100g = "carbohydrates_100g"
        case fiber100g = "fiber_100g"
        case fat100g = "fat_100g"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        energyKcal100g = (try? c.decodeIfPresent(Double.self, forKey: .energyKcal100g)) ?? nil
        proteins100g = (try? c.decodeIfPresent(Double.self, forKey: .proteins100g)) ?? nil
        carbohydrates100g = (try? c.decodeIfPresent(Double.self, forKey: .carbohydrates100g)) ?? nil
        fiber100g = (try? c.decodeIfPresent(Double.self, forKey: .fiber100g)) ?? nil
        fat100g = (try? c.decodeIfPresent(Double.self, forKey: .fat100g)) ?? nil
    }
}

private struct OffHitDTO: Decodable {
    let code: String?
    let productName: String?
    let nutriments: OffNutrimentsDTO?
    let servingQuantity: OffFlexibleDouble?

    enum CodingKeys: String, CodingKey {
        case code
        case productName = "product_name"
        case nutriments
        case servingQuantity = "serving_quantity"
    }
}

private struct OffSearchResponseDTO: Decodable {
    let hits: [OffHitDTO]?
}

private struct OffProductDTO: Decodable {
    let productName: String?
    let nutriments: OffNutrimentsDTO?
    let servingQuantity: OffFlexibleDouble?

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case nutriments
        case servingQuantity = "serving_quantity"
    }
}

private struct OffProductResponseDTO: Decodable {
    let status: Int?
    let product: OffProductDTO?
}

/// Résultat brut Open Food Facts — miroir de `Omit<Food, 'id'>` (TS) : PAS
/// d'`id` (jamais encore enregistré en bibliothèque). Utilisé à la fois comme
/// élément de réponse `GET nutrition/search` (encodé tel quel) et comme
/// valeur de retour interne de `fetchOpenFoodFacts` (consommée par
/// `encodeNutritionBarcode`, jamais encodée directement).
private struct LocalNutritionOffFoodDTO: Encodable {
    let barcode: String?
    let name: String
    let kcal: Double?
    let protein: Double?
    let carbs: Double?
    let fiber: Double?
    let fat: Double?
    let unitLabel: String?
    let unitGrams: Double?
}

private struct LocalNutritionBarcodeResultDTO: Encodable {
    let found: Bool
    let source: String?
    let food: LocalNutritionFoodDTO?
}
