//
//  LocalPulseBackend.swift
//  all (bridge-connect)
//
//  Portage réel du backend local « Pulse embarqué » (incréments
//  L1+L2+L3+L4+L5+L6+L5-Nutrition-analytics, cf. `docs/stockage-local.md`) —
//  remplace `StubLocalPulseBackend` (L0) pour les routes qu'il sait vraiment
//  servir depuis `LocalDb`. Toute autre route continue de lever
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
//  Portée L6 : `GET`/`PUT api/profile` — miroir de `ProfileController`
//  (`profile.controller.ts`), quatre clés `settings` déjà présentes
//  (`birthYear`/`sex`/`weightKg`/`heightCm`, `weightKg` déjà tenue à jour par
//  L5-Poids). Débloque le profil éditable en mode Téléphone (préalable à
//  Nutrition-cibles/Programme, hors périmètre de cet incrément). Divergence
//  assumée vs serveur : `weightKg` fourni par ce PUT est AUSSI répercuté dans
//  `weight_log` du jour (le serveur ne le fait pas), cf. commentaire de
//  section dédiée plus bas.
//
//  Portée L5-Nutrition-analytics : `GET api/nutrition/targets`, `.../weekly`,
//  `.../timing/:date`, `.../suggestions/:date`, et les champs
//  `targets`/`remaining`/`targetRanges` de `.../day/:date` — remplacent les
//  STUBS neutres de l'incrément L5-Nutrition précédent, calculés désormais
//  par le moteur réel (`Local/NutritionTarget.swift`, portage de
//  `nutrition/target.ts`). Moteur PROGRAMME non porté (pas de table
//  `programme_state` locale) : `targetRanges` retombe toujours sur les
//  cibles manuelles (`manualRanges()`), `programme` reste toujours `nil` —
//  cf. l'en-tête de `NutritionTarget.swift` et la section dédiée plus bas.
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
    /// `.fit` d'activité rapatriés de Pulse (`PulseFilesPullEngine`), nommés par hash :
    /// consultés AVANT le spool (accès direct, sans hacher). `nil` : ignorés.
    private let pulledFiles: PulseFilesStore?
    /// Couture d'injection réseau Open Food Facts — même principe que
    /// `PulseUploadTransport` (`Sync/PulseUploader.swift`) : substituée par un
    /// test double dans `allTests`, jamais `URLSessionOpenFoodFactsTransport`
    /// (la seule conformance qui touche vraiment le réseau) en test.
    private let offTransport: OpenFoodFactsTransport
    /// Cache mémoire des ajustements de `stats/sleep-recommendation` (cf.
    /// `SleepModelCache`) — propre à ce backend, donc à sa base.
    let sleepModelCache = SleepModelCache()

    init() throws {
        db = try LocalDb()
        spool = try? SpoolStore()
        pulledFiles = try? PulseFilesStore.standard()
        offTransport = URLSessionOpenFoodFactsTransport()
    }

    /// Init testable : base (et spool, optionnel, et transport OFF factice
    /// optionnel) déjà construits (fichiers temporaires en test).
    init(
        db: LocalDb, spool: SpoolStore? = nil, pulledFiles: PulseFilesStore? = nil,
        offTransport: OpenFoodFactsTransport = URLSessionOpenFoodFactsTransport()
    ) {
        self.db = db
        self.spool = spool
        self.pulledFiles = pulledFiles
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
        // en-tête de `DashboardStats.swift`). `stats/sleep-recommendation` :
        // porté (`docs/duree-ideale-sommeil.md`), cf. en-tête de
        // `DashboardStats.swift`.

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

        case ("GET", "stats/sleep-recommendation"):
            return try DashboardStatsBackend.sleepRecommendation(db: db, query: query, cache: sleepModelCache)

        // MARK: Profil (incrément L6, miroir `ProfileController` — `profile.controller.ts`)

        case ("GET", "profile"):
            return try encodeProfileGet()

        case ("PUT", "profile"):
            return try encodeProfileUpdate(body: body)

        // MARK: Planning de réveil (miroir `WakeController` — `wake.controller.ts`)

        case ("GET", "wake-schedule"):
            return try encodeWakeScheduleGet()

        case ("PUT", "wake-schedule"):
            return try encodeWakeScheduleUpdate(body: body)

        // MARK: Programme (incrément L7a LECTURE + L7b ÉCRITURE — miroir
        // `ProgrammeController.current`/`domainView`/`activate`/`stop`/
        // `toggleSession`). `candidates`/`export`/`push` restent délibérément
        // hors périmètre (leurs chemins ne matchent aucun `case` ci-dessous,
        // retombent sur le `default` `LocalPulseUnavailableError`) — cf.
        // en-tête de section dédiée plus bas et rapport d'incrément.

        case ("GET", "programme"):
            return try encodeProgrammeCurrent(query: query)

        case ("POST", "programme/activate"):
            return try encodeProgrammeActivate(body: body)

        case ("POST", "programme/stop"):
            return try encodeProgrammeStop(body: body)

        case ("POST", "programme/session"):
            return try encodeProgrammeSession(body: body)

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

        // Cibles calculées (incrément L5-Nutrition-analytics — cf. section
        // dédiée plus bas et `Local/NutritionTarget.swift`).
        case ("GET", "nutrition/targets"):
            return try encodeNutritionTargets(query: query)

        case ("GET", "nutrition/weekly"):
            return try encodeNutritionWeekly(query: query)

        case ("GET", let r) where r.hasPrefix("nutrition/timing/"):
            return try encodeNutritionTiming(date: String(r.dropFirst("nutrition/timing/".count)))

        case ("GET", let r) where r.hasPrefix("nutrition/suggestions/"):
            return try encodeNutritionSuggestions(date: String(r.dropFirst("nutrition/suggestions/".count)))

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

    // MARK: - Profil (incrément L6, miroir `ProfileController` — `profile.controller.ts`)
    //
    // Quatre clés `settings` (déjà utilisées par L5-Poids pour `weightKg`) :
    // `birthYear`/`sex`/`weightKg`/`heightCm`. `GET` lit les quatre et
    // renvoie `null` pour tout champ absent/invalide — miroir EXACT de
    // `ProfileController.read` (`Number.isFinite(NaN) → null`, `sex` hors
    // `{male,female}` → `null`). `PUT` valide champ par champ EXACTEMENT
    // comme `ProfileController.update` (mêmes bornes, mêmes erreurs), écrit
    // uniquement les champs fournis, puis renvoie le profil relu (miroir de
    // `return ProfileController.read(this.dbService)` en fin de route).
    //
    // Divergence assumée vs le serveur (décision de cet incrément) :
    // `ProfileController.update` n'écrit `weightKg` que dans `settings`,
    // JAMAIS dans `weight_log` (contrairement à `WeightController.add`, qui
    // écrit `weight_log` PUIS republie `settings.weightKg` depuis la dernière
    // pesée, cf. `syncProfile`/`LocalDb.syncWeightProfile`). Ici, `PUT
    // api/profile` avec `weightKg` fait les DEUX : upsert dans `weight_log`
    // pour AUJOURD'HUI (même arrondi 0,1 kg que `WeightController.add`), puis
    // `syncWeightProfile()` republie `settings.weightKg` depuis cette même
    // entrée — une seule source de vérité (`weight_log`), jamais deux valeurs
    // divergentes entre `settings.weightKg` et le dernier `weight_log`. Motif :
    // en mode Téléphone il n'existe qu'UN écran de pesée (Santé,
    // `HealthViewModel.saveWeight` → `POST api/weight`) mais ce PUT reste dans
    // le contrat `SettingsProfile`/`ProfileController` pour parité de forme —
    // le faire diverger silencieusement du poids réellement enregistré (deux
    // `settings.weightKg` possibles selon la route empruntée) serait pire que
    // cette petite divergence de comportement vs le serveur, jamais observable
    // depuis les écrans (aucun écran natif n'envoie `weightKg` via ce PUT à ce
    // jour, cf. `SettingsProfileUpdateRequest`).

    private func encodeProfileGet() throws -> Data {
        try JSONEncoder().encode(readProfile())
    }

    private func readProfile() throws -> LocalProfileDTO {
        let birthYear = (try db.settingValue(key: "birthYear")).flatMap(Int.init)
        let sexRaw = try db.settingValue(key: "sex")
        let sex = (sexRaw == "male" || sexRaw == "female") ? sexRaw : nil
        let weightKg = (try db.settingValue(key: "weightKg")).flatMap(Double.init)
        let heightCm = (try db.settingValue(key: "heightCm")).flatMap(Double.init)
        return LocalProfileDTO(birthYear: birthYear, sex: sex, weightKg: weightKg, heightCm: heightCm)
    }

    /// Miroir de `ProfileController.update` — bornes EXACTES
    /// (`currentYear - 110`...`currentYear - 10` pour `birthYear`, `{male,
    /// female}` pour `sex`, `[25, 300]` pour `weightKg`, `[100, 250]` pour
    /// `heightCm`). Chaque champ `nil` dans le corps est laissé tel quel
    /// (miroir de `body.xxx != null` côté TS) ; un champ présent mais hors
    /// bornes lève immédiatement (aucune écriture partielle au-delà de ce qui
    /// a déjà été traité, même ordre que le serveur : `birthYear`, `sex`,
    /// `weightKg`, `heightCm`).
    private func encodeProfileUpdate(body: Data?) throws -> Data {
        guard let body else { throw LocalProfileValidationError(reason: "Corps de requête manquant") }
        let req = try JSONDecoder().decode(LocalProfileUpdateRequestDTO.self, from: body)
        let currentYear = Calendar.current.component(.year, from: Date())

        if let birthYear = req.birthYear {
            guard birthYear >= currentYear - 110, birthYear <= currentYear - 10 else {
                throw LocalProfileValidationError(reason: "Invalid birthYear")
            }
            try db.setSetting(key: "birthYear", value: String(birthYear))
        }
        if let sex = req.sex {
            guard sex == "male" || sex == "female" else {
                throw LocalProfileValidationError(reason: "Invalid sex")
            }
            try db.setSetting(key: "sex", value: sex)
        }
        if let weightKg = req.weightKg {
            guard weightKg.isFinite, weightKg >= Self.weightMinKg, weightKg <= Self.weightMaxKg else {
                throw LocalProfileValidationError(reason: "Invalid weightKg")
            }
            // Cf. commentaire d'en-tête de section : upsert `weight_log` du
            // jour (même arrondi que `WeightController.add`) puis republie
            // `settings.weightKg` depuis cette entrée — jamais un écrit direct
            // et distinct de `settings.weightKg` ici.
            let rounded = (weightKg * 10).rounded() / 10
            try db.upsertWeight(date: Self.todayDateKey(), kg: rounded)
            try db.syncWeightProfile()
        }
        if let heightCm = req.heightCm {
            guard heightCm.isFinite, heightCm >= 100, heightCm <= 250 else {
                throw LocalProfileValidationError(reason: "Invalid heightCm")
            }
            try db.setSetting(key: "heightCm", value: String(heightCm))
        }
        return try JSONEncoder().encode(readProfile())
    }

    // MARK: - Planning de réveil (miroir `WakeController` — `wake.controller.ts`)
    //
    // Une seule clé `settings` (`wakeSchedule`), valeur = `JSON.stringify` de
    // la map interne seule (`{"1":420,...}`), pas l'objet enveloppé — même
    // contrat que le serveur. `GET` filtre/ignore silencieusement toute
    // entrée invalide/corrompue (robustesse à la lecture, miroir de
    // `WakeController.read`). `PUT` valide champ par champ (clé entier 1..7,
    // valeur entier 0..1439) et remplace entièrement le planning.

    private func encodeWakeScheduleGet() throws -> Data {
        try JSONEncoder().encode(readWakeSchedule())
    }

    private func readWakeSchedule() throws -> LocalWakeScheduleDTO {
        guard let raw = try db.settingValue(key: "wakeSchedule"),
              let data = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([String: Int].self, from: data)
        else {
            return LocalWakeScheduleDTO(schedule: [:])
        }
        var schedule: [String: Int] = [:]
        for (key, value) in parsed {
            guard let weekday = Int(key), weekday >= 1, weekday <= 7,
                  value >= 0, value <= 1439
            else { continue }
            schedule[key] = value
        }
        return LocalWakeScheduleDTO(schedule: schedule)
    }

    private func encodeWakeScheduleUpdate(body: Data?) throws -> Data {
        guard let body else { throw LocalWakeScheduleValidationError(reason: "Corps de requête manquant") }
        let req = try JSONDecoder().decode(LocalWakeScheduleDTO.self, from: body)
        var cleaned: [String: Int] = [:]
        for (key, value) in req.schedule {
            guard let weekday = Int(key), weekday >= 1, weekday <= 7 else {
                throw LocalWakeScheduleValidationError(reason: "Invalid wake schedule")
            }
            guard value >= 0, value <= 1439 else {
                throw LocalWakeScheduleValidationError(reason: "Invalid wake schedule")
            }
            cleaned[key] = value
        }
        let data = try JSONEncoder().encode(cleaned)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LocalWakeScheduleValidationError(reason: "Invalid wake schedule")
        }
        try db.setSetting(key: "wakeSchedule", value: json)
        return try JSONEncoder().encode(readWakeSchedule())
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
        // Activité rapatriée de Pulse : nommée par son hash, aucun parcours.
        if let url = pulledFiles?.activityURL(hash: hash) { return url }
        guard let spool else { return nil }
        // Entrée purgée = `.fit` supprimé (jamais une activité en pratique, cf.
        // `SpoolPurger`) : inutile de tenter de le hacher.
        for entry in spool.entries.values where entry.purgedAt == nil {
            let url = spool.fileURL(for: entry)
            guard let entryHash = try? PulseUploader.sha256Hex(ofFileAt: url) else { continue }
            if entryHash == hash { return url }
        }
        return nil
    }

    // MARK: - Nutrition (incrément L5-Nutrition + L5-Nutrition-analytics,
    // miroir `NutritionController` — `nutrition.controller.ts`)
    //
    // Portée FIDÈLE (aucun réseau) : `day/:date` (entrées + totaux + cibles,
    // cf. plus bas), `frequent`, `foods` (recherche/création/édition
    // bibliothèque), `log` (ajout/édition/suppression). Table `foods` semée
    // au premier ouverture depuis `LocalDb.seedFoods` (port de `seed-foods.ts`).
    //
    // `targets`/`remaining` de `day/:date` : calculés depuis le moteur réel
    // (`Local/NutritionTarget.swift`, port de `target.ts`) — cf. `dayTarget`/
    // `effectiveTargets` plus bas. `targetRanges` retombe sur `manualRanges()`
    // (cibles manuelles min/max, `settings`) — JAMAIS un cadre de programme
    // (`programmeFor`/`activeConstraints` côté TS) : le moteur programme n'est
    // pas porté dans cet incrément (pas de table `programme_state` locale),
    // cf. en-tête de `NutritionTarget.swift`. `programme` (nom du programme
    // actif) reste donc toujours `nil`.

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
        // null` (TS) : indépendant du moteur de cible (dépend juste des
        // totaux réels + `settings.weightKg`, synchronisé par L5-Poids sur
        // chaque écriture de pesée).
        let weightKg = (try db.settingValue(key: "weightKg")).flatMap(Double.init)
        let proteinPerKg: Double?
        if let weightKg, weightKg != 0, sumProtein != 0 {
            proteinPerKg = ((sumProtein / weightKg) * 100).rounded() / 100
        } else {
            proteinPerKg = nil
        }

        let auto = try dayTarget(date: date)
        let (targets, source) = try effectiveTargets(date: date, auto: auto)
        let remaining = LocalNutritionMacrosDTO(
            kcal: targets.kcal.map { round1($0 - sumKcal) },
            protein: targets.protein.map { round1($0 - sumProtein) },
            carbs: targets.carbs.map { round1($0 - sumCarbs) },
            fat: targets.fat.map { round1($0 - sumFat) },
            fiber: targets.fiber.map { round1($0 - sumFiber) })
        let targetRanges = try manualRanges()

        let day = LocalNutritionDayDTO(
            date: date, entries: entries, totals: totals, targets: targets, targetSource: source,
            targetRanges: targetRanges, programme: nil, remaining: remaining, proteinPerKg: proteinPerKg)
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
        // `foods.barcode` est UNIQUE : un produit déjà en bibliothèque (résultat de recherche
        // en ligne repris une seconde fois, sans `id`) est mis à jour, pas inséré en double.
        if let barcode = req.barcode, !barcode.isEmpty, let existing = try db.food(barcode: barcode),
           let row = try db.updateFood(
               id: existing.id, barcode: barcode, name: name, kcal: req.kcal, protein: req.protein, carbs: req.carbs,
               fiber: req.fiber, fat: req.fat, unitLabel: unit.unitLabel, unitGrams: unit.unitGrams) {
            return try JSONEncoder().encode(LocalNutritionFoodDTO(row))
        }
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

    // MARK: - Nutrition — cibles calculées (incrément L5-Nutrition-analytics,
    // miroir `target.ts` + les aides privées de `NutritionController` —
    // `dayTarget`/`profileOn`/`watchOn`/`effectiveTargets`/`readMode`/
    // `readTargets`/`readTargetMins`/`readTargetMaxes`/`readSettings`/
    // `manualRanges`/`remainingFor`). Moteur pur dans
    // `Local/NutritionTarget.swift` ; ici seulement la lecture des entrées
    // locales (profil/montre/séances/settings/intake) et l'encodage JSON.
    //
    // Moteur PROGRAMME non porté (cf. en-tête de `NutritionTarget.swift`) :
    // `activeConstraints()`/`programmeFor()` n'existent pas ici — il n'y a pas
    // de table `programme_state` locale, donc rien à lire. Conséquence :
    // `computeMacros`/`computeDayTarget` sont TOUJOURS appelés sans
    // contraintes (équivalent de `constraints: null` côté TS), et
    // `targetRanges` (`day/:date`, `targets`) retombe TOUJOURS sur
    // `manualRanges()` (cibles manuelles min/max), jamais un cadre de
    // programme — cf. aussi le commentaire de section `day/:date` plus haut.
    //
    // Profil incomplet (`birthYear`/`sex`/`heightCm` manquants) : comportement
    // HONNÊTE hérité tel quel du moteur (`NutritionTargetEngine.computeDayTarget`
    // → `status: "unavailable"`, `missing: [...]`, toutes les cibles `nil`) —
    // jamais un `0` ou une valeur fabriquée. `suggestions`/`weekly` héritent
    // de cette honnêteté via `remaining`/`auto.targetKcal` restant `nil`.

    /// Miroir de `dayTarget` (TS, privée).
    private func dayTarget(date: String) throws -> NutritionEngineTargetResult {
        let profile = try profileOn(date: date)
        let watchRow = try db.watchDay(date: date)
        let sessions = try db.activitySessions(date: date).map {
            NutritionEngineSession(sport: $0.sport, subSport: $0.subSport, durationS: $0.durationS, calories: $0.calories)
        }
        let settings = try readSettings()
        return NutritionTargetEngine.computeDayTarget(
            date: date, profile: profile,
            watch: NutritionEngineWatchDay(restingKcal: watchRow.restingKcal, activeKcal: watchRow.activeKcal),
            sessions: sessions, settings: settings)
    }

    /// Miroir de `profileOn` (TS) — profil de base (`readProfile()`, mêmes
    /// clés `settings` que L6) avec `weightKg` remplacé par la dernière pesée
    /// connue AU PLUS TARD `date` (`LocalDb.weightOn`), repli sur
    /// `settings.weightKg` si aucune pesée avant cette date.
    private func profileOn(date: String) throws -> NutritionEngineProfile {
        let base = try readProfile()
        let weightOnDate = try db.weightOn(date: date) ?? base.weightKg
        return NutritionEngineProfile(birthYear: base.birthYear, sex: base.sex, weightKg: weightOnDate, heightCm: base.heightCm)
    }

    /// Miroir de `readMode` (TS) — `settings.nutritionMode`, défaut `"auto"`.
    private func readMode() throws -> String {
        (try db.settingValue(key: "nutritionMode")) == "manual" ? "manual" : "auto"
    }

    private struct NutritionManualTargets {
        let kcal: Double?
        let protein: Double?
        let carbs: Double?
        let fat: Double?
        let fiber: Double?
    }

    /// Miroir de `readTargetKeys` (TS) — `settings.nutritionKcal<suffix>`
    /// etc., `nil` si absent ou non numérique (jamais `NaN`).
    private func readTargetKeys(suffix: String) throws -> NutritionManualTargets {
        func val(_ base: String) throws -> Double? {
            (try db.settingValue(key: "\(base)\(suffix)")).flatMap(Double.init)
        }
        return NutritionManualTargets(
            kcal: try val("nutritionKcal"), protein: try val("nutritionProtein"),
            carbs: try val("nutritionCarbs"), fat: try val("nutritionFat"), fiber: try val("nutritionFiber"))
    }

    private func readTargets() throws -> NutritionManualTargets { try readTargetKeys(suffix: "") }
    private func readTargetMins() throws -> NutritionManualTargets { try readTargetKeys(suffix: "Min") }
    private func readTargetMaxes() throws -> NutritionManualTargets { try readTargetKeys(suffix: "Max") }

    /// Miroir de `readSettings` (TS) — `DEFAULT_TARGET_SETTINGS` avec repli
    /// clé par clé sur `settings.nutritionXxx`, chaque valeur passée par
    /// `clampSetting` (une valeur stockée hors bornes est ignorée, comme le
    /// serveur). Ces clés ne sont écrites par AUCUNE route locale actuelle
    /// (`PUT nutrition/settings` non porté, hors périmètre) : en pratique
    /// toujours les valeurs par défaut, sauf seedées directement en test.
    private func readSettings() throws -> NutritionEngineSettings {
        var settings = NutritionEngineSettings.defaults
        func apply(_ key: NutritionEngineSettingKey, _ dbKey: String) throws {
            guard let raw = (try db.settingValue(key: dbKey)).flatMap(Double.init) else { return }
            guard let clamped = NutritionTargetEngine.clampSetting(key, raw) else { return }
            switch key {
            case .weeklyLossPct: settings.weeklyLossPct = clamped
            case .deficitKcal: settings.deficitKcal = clamped
            case .sportFactor: settings.sportFactor = clamped
            case .proteinPerKg: settings.proteinPerKg = clamped
            case .floorKcal: settings.floorKcal = clamped
            case .weeklyAlertKcal: settings.weeklyAlertKcal = clamped
            }
        }
        try apply(.weeklyLossPct, "nutritionWeeklyLossPct")
        try apply(.deficitKcal, "nutritionDeficitKcal")
        try apply(.sportFactor, "nutritionSportFactor")
        try apply(.proteinPerKg, "nutritionProteinPerKg")
        try apply(.floorKcal, "nutritionFloorKcal")
        try apply(.weeklyAlertKcal, "nutritionWeeklyAlertKcal")
        return settings
    }

    /// Miroir de `effectiveTargets` (TS) — SANS le paramètre `programmeRanges`
    /// (toujours `null` ici, cf. en-tête de section) : la branche
    /// `fromProgramme` du TS est donc omise plutôt que portée morte.
    private func effectiveTargets(date: String, auto: NutritionEngineTargetResult) throws -> (targets: LocalNutritionMacrosDTO, source: String) {
        let manual = try readTargets()
        let mode = try readMode()
        let useAuto = mode == "auto" && auto.status == "ok" && auto.targetKcal != nil
        func pick(_ value: Double?, _ fallback: Double?) -> Double? {
            (useAuto && value != nil) ? value : fallback
        }
        let targets = LocalNutritionMacrosDTO(
            kcal: useAuto ? auto.targetKcal : manual.kcal,
            protein: pick(auto.macros.proteinG, manual.protein),
            carbs: pick(auto.macros.carbsG, manual.carbs),
            fat: pick(auto.macros.fatG, manual.fat),
            fiber: pick(auto.macros.fiberG, manual.fiber))
        return (targets, useAuto ? "auto" : "manual")
    }

    /// Miroir de `manualRanges` (TS) — cadre min/max des cibles MANUELLES
    /// (`settings.nutritionXxxMin`/`Max`), PAS un cadre de programme (jamais
    /// disponible ici, cf. en-tête de section). `min > max` : les deux valeurs
    /// sont échangées, comme le serveur.
    private func manualRanges() throws -> [String: LocalNutritionMacroRangeDTO]? {
        let minT = try readTargetMins()
        let maxT = try readTargetMaxes()
        var ranges: [String: LocalNutritionMacroRangeDTO] = [:]
        let pairs: [(String, Double?, Double?)] = [
            ("kcal", minT.kcal, maxT.kcal), ("protein", minT.protein, maxT.protein),
            ("carbs", minT.carbs, maxT.carbs), ("fat", minT.fat, maxT.fat), ("fiber", minT.fiber, maxT.fiber),
        ]
        for (key, lo, hi) in pairs {
            guard lo != nil || hi != nil else { continue }
            if let lo, let hi, lo > hi {
                ranges[key] = LocalNutritionMacroRangeDTO(min: hi, max: lo)
            } else {
                ranges[key] = LocalNutritionMacroRangeDTO(min: lo, max: hi)
            }
        }
        return ranges.isEmpty ? nil : ranges
    }

    /// Miroir de `remainingFor` (TS) — PAS de champ `fat` dans le résultat
    /// (le serveur non plus : `totals`/`remaining` de cette aide se limitent à
    /// kcal/protein/carbs/fiber) ; encodé ici avec `fat: nil` (`null`),
    /// équivalent pour un décodage dans `NutritionMacros` (tous champs
    /// optionnels).
    private func remainingFor(date: String) throws -> LocalNutritionMacrosDTO {
        let rows = try db.foodLog(date: date)
        var sumKcal = 0.0, sumProtein = 0.0, sumCarbs = 0.0, sumFiber = 0.0
        for row in rows {
            sumKcal += row.kcal ?? 0
            sumProtein += row.protein ?? 0
            sumCarbs += row.carbs ?? 0
            sumFiber += row.fiber ?? 0
        }
        let auto = try dayTarget(date: date)
        let (targets, _) = try effectiveTargets(date: date, auto: auto)
        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        return LocalNutritionMacrosDTO(
            kcal: targets.kcal.map { r1($0 - sumKcal) }, protein: targets.protein.map { r1($0 - sumProtein) },
            carbs: targets.carbs.map { r1($0 - sumCarbs) }, fat: nil, fiber: targets.fiber.map { r1($0 - sumFiber) })
    }

    /// Miroir de `shiftDate` (TS) — coupure UTC, jour calendaire ± n jours.
    private static func shiftDate(_ date: String, byDays days: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let base = formatter.date(from: date) else { return date }
        return formatter.string(from: base.addingTimeInterval(Double(days) * 86400))
    }

    /// `GET api/nutrition/targets` — miroir de `NutritionController.getTargets`,
    /// réduit aux champs consommés par l'écran (`mode`/`targets`/`source`/`auto`)
    /// — mêmes champs déjà explicitement omis du modèle `NutritionTargetInfo`
    /// (`manual`/`manualMin`/`manualMax`/`programme`/`settings`/`date` du
    /// serveur, jamais décodés côté écran, cf. en-tête de
    /// `NutritionModels.swift`).
    private func encodeNutritionTargets(query: [String: String]) throws -> Data {
        let date = query["date"] ?? Self.todayDateKey()
        let range = NSRange(date.startIndex..<date.endIndex, in: date)
        guard Self.datePattern.firstMatch(in: date, range: range) != nil else {
            throw LocalNutritionValidationError(reason: "Date invalide")
        }
        let auto = try dayTarget(date: date)
        let (targets, source) = try effectiveTargets(date: date, auto: auto)
        let dto = LocalNutritionTargetsResponseDTO(
            mode: try readMode(), targets: targets, source: source,
            auto: LocalNutritionAutoTargetComputedDTO(auto))
        return try JSONEncoder().encode(dto)
    }

    /// `GET api/nutrition/weekly` — miroir de `NutritionController.getWeekly`
    /// (`computeWeekly`, moyenne 7 j se terminant à `date`).
    private func encodeNutritionWeekly(query: [String: String]) throws -> Data {
        let end = query["date"] ?? Self.todayDateKey()
        let range = NSRange(end.startIndex..<end.endIndex, in: end)
        guard Self.datePattern.firstMatch(in: end, range: range) != nil else {
            throw LocalNutritionValidationError(reason: "Date invalide")
        }
        let settings = try readSettings()
        let intakeByDate = try db.foodLogKcalByDate()
        var days: [NutritionEngineWeeklyDay] = []
        for i in stride(from: 6, through: 0, by: -1) {
            let date = Self.shiftDate(end, byDays: -i)
            let auto = try dayTarget(date: date)
            let logged = intakeByDate[date].map { $0.rounded() }
            days.append(NutritionEngineWeeklyDay(
                date: date, intakeKcal: logged, expenditureKcal: auto.expenditureKcal, targetKcal: auto.targetKcal,
                balanceKcal: (logged != nil && auto.expenditureKcal != nil) ? logged! - auto.expenditureKcal! : nil))
        }
        let weekly = NutritionTargetEngine.computeWeekly(days, settings: settings)
        return try JSONEncoder().encode(LocalNutritionWeeklyResponseDTO(weekly))
    }

    /// `GET api/nutrition/timing/:date` — miroir de `NutritionController.timing`
    /// (fenêtre de digestion vs stress ambiant, `wellness_samples`).
    private func encodeNutritionTiming(date: String) throws -> Data {
        let range = NSRange(date.startIndex..<date.endIndex, in: date)
        guard Self.datePattern.firstMatch(in: date, range: range) != nil else {
            throw LocalNutritionValidationError(reason: "Date invalide")
        }
        guard let last = try db.lastFoodLogWithTs(date: date) else {
            return try JSONEncoder().encode(LocalNutritionTimingResponseDTO(meal: nil))
        }
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
        let avgStress = try db.averageStressBetween(fromTs: Double(last.ts), toTs: Double(last.ts) + 5400)
        let baseH = clamp(1.5 + (last.kcal ?? 0) / 400 + (last.fat ?? 0) / 30, 1.5, 5)
        let stressFactor = avgStress.map { clamp(1 + ($0 - 30) / 100, 0.75, 1.6) } ?? 1.0
        let windowH = clamp(baseH * stressFactor, 1.5, 6)
        let digEnd = Int((Double(last.ts) + windowH * 3600).rounded())
        let meal = LocalNutritionMealTimingDTO(
            lastMealTs: last.ts, digestionEndTs: digEnd, nextMealTs: digEnd,
            gymStartTs: Int((Double(last.ts) + 2 * 3600).rounded()),
            gymEndTs: Int((Double(last.ts) + 3.5 * 3600).rounded()),
            avgStress: avgStress.map { Int($0.rounded()) }, windowH: (windowH * 10).rounded() / 10)
        return try JSONEncoder().encode(LocalNutritionTimingResponseDTO(meal: meal))
    }

    /// `GET api/nutrition/suggestions/:date` — miroir de
    /// `NutritionController.suggestions` (score protéines/kcal/fibres,
    /// bibliothèque `foods` locale, max 6 items).
    private func encodeNutritionSuggestions(date: String) throws -> Data {
        let range = NSRange(date.startIndex..<date.endIndex, in: date)
        guard Self.datePattern.firstMatch(in: date, range: range) != nil else {
            throw LocalNutritionValidationError(reason: "Date invalide")
        }
        let remaining = try remainingFor(date: date)
        guard remaining.kcal != nil || remaining.protein != nil else {
            return try JSONEncoder().encode(LocalNutritionSuggestionsResponseDTO(remaining: remaining, items: [], reason: "no-targets"))
        }
        let needKcal = max(remaining.kcal ?? 0, 0)
        let needProtein = max(remaining.protein ?? 0, 0)
        let needFiber = max(remaining.fiber ?? 0, 0)
        guard needKcal > 0 || needProtein > 0 || needFiber > 0 else {
            return try JSONEncoder().encode(LocalNutritionSuggestionsResponseDTO(remaining: remaining, items: [], reason: "done"))
        }

        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        func maxPortionsFor(_ portionGrams: Double) -> Double {
            if portionGrams >= 100 { return 2 }
            if portionGrams >= 60 { return 3 }
            if portionGrams >= 25 { return 4 }
            return 6
        }

        var scored: [(item: LocalNutritionSuggestionItemDTO, score: Double)] = []
        for f in try db.foodsWithPositiveKcal() {
            guard let kcal100 = f.kcal, kcal100 > 0 else { continue }
            let byUnit = (f.unitGrams ?? 0) > 0
            let portionG = byUnit ? f.unitGrams! : 100.0
            let portionKcal = kcal100 * portionG / 100
            let portionProtein = (f.protein ?? 0) * portionG / 100
            guard portionKcal > 0 else { continue }
            let byKcal = needKcal > 0 ? (needKcal * 0.6 / portionKcal).rounded(.down) : 1.0
            let byProtein = (needProtein > 0 && portionProtein > 0) ? (needProtein / portionProtein).rounded() : Double.infinity
            let portions = clamp(min(byKcal, byProtein), 1, maxPortionsFor(portionG))
            let grams = r1(portions * portionG)
            let units: Double? = byUnit ? portions : nil
            let factor = grams / 100
            let giveKcal = (kcal100 * factor).rounded()
            let giveProtein = r1((f.protein ?? 0) * factor)
            let giveCarbs = r1((f.carbs ?? 0) * factor)
            let giveFiber = r1((f.fiber ?? 0) * factor)
            let fillP = needProtein > 0 ? min(giveProtein / needProtein, 1) : 0
            let fillK = needKcal > 0 ? min(giveKcal / needKcal, 1) : 0
            let fillF = needFiber > 0 ? min(giveFiber / needFiber, 1) : 0
            let score = fillP * 0.6 + fillK * 0.3 + fillF * 0.1
            guard score > 0 else { continue }
            scored.append((
                LocalNutritionSuggestionItemDTO(
                    foodId: f.id, name: f.name, grams: grams, units: units, unitLabel: f.unitLabel, unitGrams: f.unitGrams,
                    kcal: giveKcal, protein: giveProtein, carbs: giveCarbs, fiber: giveFiber),
                score))
        }
        scored.sort { $0.score > $1.score }
        let items = Array(scored.prefix(6)).map { $0.item }
        return try JSONEncoder().encode(LocalNutritionSuggestionsResponseDTO(remaining: remaining, items: items, reason: nil))
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

    // MARK: - Programme (incrément L7a LECTURE + L7b ÉCRITURE — miroir
    // `ProgrammeController.current`/`domainView`/`activate`/`stop`/
    // `toggleSession`, moteur dans `Local/Programme/` : `ProgrammeCatalogue.swift`
    // (catalogue statique), `ProgrammeProgress.swift` (rapprochement séances/
    // activités, avancement alimentation, `buildPlan`/`sessionsPerWeek`
    // désormais RÉELLEMENT appelés par `encodeProgrammeActivate`),
    // `ProgrammeSleep.swift` (analyse de régularité du sommeil).
    // `ProgrammeConstraints.swift` porté mais NON câblé (cf. son en-tête —
    // sert seulement à `nutrition.controller.ts`, jamais à cette route).
    //
    // Portée : les TROIS domaines (`training`/`nutrition`/`sleep`) sont
    // FIDÈLES en lecture — aucune dégradation nécessaire, `checkDay`/
    // `analyseSleep` (alimentation/sommeil) ne dépendent d'AUCUN moteur non
    // porté (ni `Local/NutritionTarget.swift`, ni un cadre de programme
    // quelconque), juste de `food_log`/`weight_log`/`settings`/
    // `wellness_sleep`/`activities`, déjà tous disponibles localement.
    //
    // Écriture (L7b) : `POST programme/activate`/`stop`/`session` sont
    // désormais servies — miroir FIDÈLE de `ProgrammeController.activate`/
    // `stop`/`toggleSession` (validations, transaction, upsert), cf.
    // `encodeProgrammeActivate`/`encodeProgrammeStop`/`encodeProgrammeSession`
    // plus bas et `LocalDb.programmeActivate`/`programmeStop`/
    // `programmeSessionDelete`/`programmeSessionUpsert`. Restent
    // DÉLIBÉRÉMENT hors périmètre (aucun `case` ne matche, retombent sur le
    // `default` `LocalPulseUnavailableError`) : `GET programme/candidates`
    // (rapprochement manuel avec une activité — l'écran ne l'utilise pas,
    // cf. `ProgrammeViewModel.toggleSession`), `GET`/`POST programme/export(/:fileName)`
    // et `GET`/`POST programme/push` (génération/envoi de fichiers `.FIT` —
    // hors périmètre de cet incrément, `ProgrammeViewModel.sendToWatch`
    // affiche donc une erreur). `ProgrammeViewModel.load()` appelle aussi
    // `GET programme/push` (statut d'envoi) en second, mais l'échec y est
    // avalé (`catch` silencieux, statut secondaire) : l'écran se charge
    // quand même.

    private func encodeProgrammeCurrent(query: [String: String]) throws -> Data {
        var date = Self.todayDateKey()
        if let param = query["date"] {
            let range = NSRange(param.startIndex..<param.endIndex, in: param)
            if Self.datePattern.firstMatch(in: param, range: range) != nil { date = param }
        }
        let domains = try ProgrammeCatalogue.domains.map { try programmeDomainView(kind: $0.kind, date: date) }
        return try JSONEncoder().encode(LocalProgrammeCurrentDTO(date: date, domains: domains))
    }

    /// Miroir de `domainView` (TS, privée).
    private func programmeDomainView(kind: ProgrammeEngineKind, date: String) throws -> LocalProgrammeDomainDTO {
        let domain = ProgrammeCatalogue.domains.first { $0.kind == kind }!
        let choices = ProgrammeCatalogue.programmes.filter { $0.kind == kind }.map { p in
            LocalProgrammeChoiceDTO(
                id: p.id, name: p.name, goal: p.goal, source: p.source, weeks: p.weeks.count,
                rules: ProgrammeCatalogue.ruleCount(p), perWeek: ProgrammeProgressEngine.sessionsPerWeek(p))
        }
        guard let state = try db.programmeActiveState(kind: kind.rawValue),
              let programme = ProgrammeCatalogue.programme(byId: state.programmeId)
        else {
            return LocalProgrammeDomainDTO(
                kind: kind.rawValue, label: domain.label, drives: domain.drives, hint: domain.hint,
                choices: choices, active: nil, detail: nil)
        }
        let days = Self.parseProgrammeDays(state.days)
        let active = LocalProgrammeActiveDTO(
            programmeId: programme.id, startedOn: state.startedOn, name: programme.name, goal: programme.goal,
            source: programme.source, week: ProgrammeProgressEngine.weekOf(startedOn: state.startedOn, date: date),
            weeks: programme.weeks.count, days: days, perWeek: ProgrammeProgressEngine.sessionsPerWeek(programme),
            notes: programme.notes)
        let detail = try programmeDetail(programme: programme, state: state, days: days, date: date)
        return LocalProgrammeDomainDTO(
            kind: kind.rawValue, label: domain.label, drives: domain.drives, hint: domain.hint,
            choices: choices, active: active, detail: detail)
    }

    /// Miroir de `parseDays`/`cleanDays` (TS, privées) réunis : `programme_state.days`
    /// (`"1,3,5"`) → jours valides (0...6), dédupliqués, triés.
    private static func parseProgrammeDays(_ raw: String?) -> [Int] {
        guard let raw, !raw.isEmpty else { return [] }
        let numbers = raw.split(separator: ",").compactMap { Int($0) }
        return Array(Set(numbers.filter { $0 >= 0 && $0 <= 6 })).sorted()
    }

    /// Miroir de `detailFor` (TS, privée) — bascule selon `programme.kind`.
    private func programmeDetail(
        programme: ProgrammeEngineProgramme, state: LocalDb.ProgrammeStateRow, days: [Int], date: String
    ) throws -> LocalProgrammeDetailDTO {
        switch programme.kind {
        case .training:
            return .training(try programmeTrainingDetail(programme: programme, state: state, date: date))
        case .sleep:
            return .sleep(try programmeSleepDetail(programme: programme, days: days, date: date))
        case .nutrition:
            return .nutrition(try programmeNutritionDetail(programme: programme, date: date))
        }
    }

    private func programmeTrainingDetail(
        programme: ProgrammeEngineProgramme, state: LocalDb.ProgrammeStateRow, date: String
    ) throws -> LocalProgrammeTrainingDetailDTO {
        let plan = try db.programmePlanRows(programmeId: programme.id).map {
            ProgrammeEnginePlannedSession(week: $0.week, session: $0.session, date: $0.date)
        }
        let manual = try db.programmeDoneRows(programmeId: programme.id).map {
            ProgrammeEngineDoneSession(week: $0.week, session: $0.session, date: $0.date, activityId: $0.activityId, manual: true)
        }
        let activities = try db.programmeActivitiesSince(state.startedOn).map {
            ProgrammeEngineActivityHit(id: $0.id, date: $0.date, sport: $0.sport, subSport: $0.subSport,
                durationS: $0.durationS, distanceM: $0.distanceM)
        }
        let sessions = ProgrammeProgressEngine.matchSessions(
            programme: programme, startedOn: state.startedOn, activities: activities, manual: manual, plan: plan, today: date)
        let sessionDTOs = sessions.map(Self.programmeSessionProgressDTO)
        return LocalProgrammeTrainingDetailDTO(
            focus: programme.weeks.map { LocalProgrammeWeekFocusDTO(index: $0.index, focus: $0.focus) },
            sessions: sessionDTOs,
            done: sessions.filter { $0.done }.count,
            total: sessions.count,
            missed: sessions.filter { $0.status == .missed }.count,
            today: sessions.filter { $0.plannedOn == date || ($0.done && $0.date == date) }.map(Self.programmeSessionProgressDTO),
            extras: ProgrammeProgressEngine.extraActivities(activities: activities, sessions: sessions).map {
                LocalProgrammeExtraActivityDTO(
                    id: $0.id, date: $0.date, sport: $0.sport, subSport: $0.subSport,
                    durationS: $0.durationS, distanceM: $0.distanceM)
            })
    }

    private static func programmeSessionProgressDTO(_ s: ProgrammeEngineSessionProgress) -> LocalProgrammeSessionProgressDTO {
        LocalProgrammeSessionProgressDTO(
            week: s.week,
            session: LocalProgrammeSessionDTO(
                key: s.session.key, name: s.session.name, sport: s.session.sport, subSport: s.session.subSport,
                minMinutes: s.session.minMinutes,
                items: s.session.items.map {
                    LocalProgrammeTrainingItemDTO(name: $0.name, prescription: $0.prescription, note: $0.note)
                }),
            plannedOn: s.plannedOn, status: s.status.rawValue, done: s.done, date: s.date, activityId: s.activityId, manual: s.manual)
    }

    private func programmeSleepDetail(
        programme: ProgrammeEngineProgramme, days: [Int], date: String
    ) throws -> LocalProgrammeSleepDetailDTO {
        let nights = try db.programmeNightsUpTo(date: date, limit: ProgrammeSleepEngine.windowNights).map {
            ProgrammeEngineSleepNightRow(date: $0.date, startTs: $0.startTs, endTs: $0.endTs, sleepS: $0.sleepS, phases: $0.phases)
        }
        let workDays = days.isEmpty ? [1, 2, 3, 4, 5] : days
        let report = ProgrammeSleepEngine.analyseSleep(
            programme: programme, rows: nights, workDays: workDays, today: date,
            offsetOf: { LocalDb.localOffsetSeconds(forDate: $0) })
        return Self.programmeSleepReportDTO(report)
    }

    private static func programmeSleepReportDTO(_ r: ProgrammeEngineSleepReport) -> LocalProgrammeSleepDetailDTO {
        LocalProgrammeSleepDetailDTO(
            from: r.from, to: r.to, nights: r.nights, spanDays: r.spanDays, staleDays: r.staleDays,
            workNights: r.workNights, freeNights: r.freeNights, pairs: r.pairs,
            axis: r.axis.map {
                LocalProgrammeSleepAxisDTO(onsetMean: $0.onsetMean, onsetSd: $0.onsetSd, wakeMean: $0.wakeMean, wakeSd: $0.wakeSd)
            },
            strip: r.strip.map {
                LocalProgrammeNightPointDTO(date: $0.date, weekday: $0.weekday, workDay: $0.workDay, onset: $0.onset, wake: $0.wake, sleepMin: $0.sleepMin)
            },
            metrics: r.metrics.map { m in
                LocalProgrammeSleepMetricDTO(
                    key: m.key, label: m.label, detail: m.detail, evidence: m.evidence, unit: m.unit.rawValue,
                    informative: m.informative, value: m.value, range: LocalProgrammeRangeDTO(min: m.rangeMin, max: m.rangeMax),
                    scale: LocalProgrammeSleepScaleDTO(min: m.scaleMin, max: m.scaleMax), status: m.status.rawValue,
                    band: m.band.map { LocalProgrammeSleepBandDTO(upTo: $0.upTo, label: $0.label, risk: $0.risk) },
                    note: m.note)
            },
            hits: r.hits, total: r.total)
    }

    private func programmeNutritionDetail(programme: ProgrammeEngineProgramme, date: String) throws -> LocalProgrammeNutritionDetailDTO {
        var days: [LocalProgrammeDayProgressDTO] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            let day = ProgrammeProgressEngine.addDays(date, -offset)
            days.append(try programmeDayProgressDTO(programme: programme, date: day))
        }
        let today = try programmeDayProgressDTO(programme: programme, date: date)
        return LocalProgrammeNutritionDetailDTO(today: today, days: days, weightKg: try programmeWeight(date: date))
    }

    private func programmeDayProgressDTO(programme: ProgrammeEngineProgramme, date: String) throws -> LocalProgrammeDayProgressDTO {
        let intakeRow = try db.programmeIntake(date: date)
        let intake = intakeRow.map {
            ProgrammeEngineDayIntake(date: date, protein: $0.protein, carbs: $0.carbs, fat: $0.fat, fiber: $0.fiber, kcal: $0.kcal)
        }
        let weightKg = try programmeWeight(date: date)
        let progress = ProgrammeProgressEngine.checkDay(programme: programme, intake: intake, weightKg: weightKg, date: date)
        return LocalProgrammeDayProgressDTO(
            date: progress.date, logged: progress.logged,
            rules: progress.rules.map { rp in
                LocalProgrammeRuleProgressDTO(
                    rule: LocalProgrammeRuleRefDTO(
                        key: rp.rule.key, label: rp.rule.label, detail: rp.rule.detail, metric: rp.rule.metric,
                        perKg: rp.rule.perKg ? true : nil),
                    target: LocalProgrammeRangeDTO(min: rp.targetMin, max: rp.targetMax),
                    value: rp.value, status: rp.status.rawValue)
            },
            hits: progress.hits, total: progress.total)
    }

    /// Miroir de `weight` (TS, privée) — dernière pesée connue au plus tard
    /// `date` (`weight_log`), repli sur `settings.weightKg` sinon. MÊME
    /// convention que `profileOn` (moteur nutrition L5-analytics), dupliquée
    /// ici (fonction privée côté TS aussi, pas de mise en commun côté serveur
    /// non plus entre `ProgrammeController.weight` et `NutritionController.profileOn`).
    private func programmeWeight(date: String) throws -> Double? {
        if let logged = try db.weightOn(date: date) { return logged }
        return (try db.settingValue(key: "weightKg")).flatMap(Double.init)
    }

    // MARK: - Programme — écriture (incrément L7b, miroir `activate`/`stop`/
    // `toggleSession` de `ProgrammeController`, cf. en-tête de section plus
    // haut).

    /// `yyyy-MM-dd` valide — même `datePattern` que le reste du fichier,
    /// factorisé ici car réutilisé trois fois par les routes d'écriture
    /// (`startedOn`/`session.date`).
    private static func isValidDateKey(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return datePattern.firstMatch(in: s, range: range) != nil
    }

    /// Miroir de `cleanDays` (TS, privée) — dédoublonné, filtré à 0...6, trié.
    /// Distinct de `parseProgrammeDays` (plus haut) : celui-ci part d'un
    /// tableau JSON déjà décodé (`activate`), `parseProgrammeDays` d'une
    /// chaîne stockée (`"1,3,5"`, relue par `domainView`).
    private static func cleanProgrammeDays(_ raw: [Int]) -> [Int] {
        Array(Set(raw.filter { $0 >= 0 && $0 <= 6 })).sorted()
    }

    /// `POST api/programme/activate` — miroir de `ProgrammeController.activate` :
    /// `programmeId` inconnu → erreur (`Unknown programme`) ; `startedOn` du
    /// corps si valide, sinon aujourd'hui ; pour un programme `training`,
    /// `days` doit couvrir au moins `sessionsPerWeek` jours (même message
    /// d'erreur, pluriel inclus) ; plan reconstruit via `buildPlan` pour
    /// `training` seulement (vide pour `nutrition`/`sleep`, comme le
    /// serveur) ; écriture déléguée à `LocalDb.programmeActivate` (transaction
    /// complète). Réponse = `current()` À AUJOURD'HUI (comme `return
    /// this.current()` côté serveur — PAS `startedOn`).
    private func encodeProgrammeActivate(body: Data?) throws -> Data {
        guard let body else { throw LocalProgrammeValidationError(reason: "Corps de requête manquant") }
        let req = try JSONDecoder().decode(LocalProgrammeActivateRequestDTO.self, from: body)
        guard let programmeId = req.programmeId, let programme = ProgrammeCatalogue.programme(byId: programmeId) else {
            throw LocalProgrammeValidationError(reason: "Unknown programme")
        }
        var startedOn = Self.todayDateKey()
        if let param = req.startedOn, Self.isValidDateKey(param) { startedOn = param }

        let needed = ProgrammeProgressEngine.sessionsPerWeek(programme)
        let days = Self.cleanProgrammeDays(req.days ?? [])
        if programme.kind == .training, days.count < needed {
            throw LocalProgrammeValidationError(
                reason: "Ce programme demande \(needed) jour\(needed > 1 ? "s" : "") par semaine")
        }
        let plan = programme.kind == .training
            ? ProgrammeProgressEngine.buildPlan(programme: programme, startedOn: startedOn, days: days)
            : []

        try db.programmeActivate(
            programmeId: programme.id, kind: programme.kind.rawValue, startedOn: startedOn, days: days,
            plan: plan.map { (week: $0.week, session: $0.session, date: $0.date) })
        return try encodeProgrammeCurrent(query: [:])
    }

    /// `POST api/programme/stop` — miroir de `ProgrammeController.stop` :
    /// `kind` doit correspondre à un des trois domaines catalogués (comme
    /// `DOMAINS.find`), sinon erreur (`Unknown kind`).
    private func encodeProgrammeStop(body: Data?) throws -> Data {
        guard let body else { throw LocalProgrammeValidationError(reason: "Corps de requête manquant") }
        let req = try JSONDecoder().decode(LocalProgrammeStopRequestDTO.self, from: body)
        guard let kindRaw = req.kind, ProgrammeCatalogue.domains.contains(where: { $0.kind.rawValue == kindRaw }) else {
            throw LocalProgrammeValidationError(reason: "Unknown kind")
        }
        try db.programmeStop(kind: kindRaw)
        return try encodeProgrammeCurrent(query: [:])
    }

    /// `POST api/programme/session` — miroir de `ProgrammeController.toggleSession` :
    /// nécessite un programme `training` actif (`No active programme` sinon),
    /// `week`/`session` non vides (`Missing session` sinon). `done === false`
    /// → suppression du pointage. Sinon : `activityId` fourni doit être une
    /// activité connue (`Unknown activity` sinon, date dérivée de
    /// l'activité) ; à défaut, `date` du corps si `yyyy-MM-dd` valide, sinon
    /// la date planifiée (`programme_plan`) ou aujourd'hui — même ordre de
    /// repli que `activityDate ?? (body.date && DATE_RE.test(...) ? body.date
    /// : plannedOn ?? todayKey())`.
    private func encodeProgrammeSession(body: Data?) throws -> Data {
        guard let body else { throw LocalProgrammeValidationError(reason: "Corps de requête manquant") }
        let req = try JSONDecoder().decode(LocalProgrammeSessionRequestDTO.self, from: body)
        guard let state = try db.programmeActiveState(kind: ProgrammeEngineKind.training.rawValue) else {
            throw LocalProgrammeValidationError(reason: "No active programme")
        }
        guard let week = req.week, let session = req.session, !session.isEmpty else {
            throw LocalProgrammeValidationError(reason: "Missing session")
        }

        if req.done == false {
            try db.programmeSessionDelete(programmeId: state.programmeId, week: week, session: session)
            return try encodeProgrammeCurrent(query: [:])
        }

        let activityId = req.activityId
        var activityDate: String?
        if let activityId {
            activityDate = try db.programmeActivityDate(id: activityId)
            guard activityDate != nil else {
                throw LocalProgrammeValidationError(reason: "Unknown activity")
            }
        }
        let date: String
        if let activityDate {
            date = activityDate
        } else if let bodyDate = req.date, Self.isValidDateKey(bodyDate) {
            date = bodyDate
        } else {
            date = try db.programmePlannedOn(programmeId: state.programmeId, week: week, session: session) ?? Self.todayDateKey()
        }

        try db.programmeSessionUpsert(programmeId: state.programmeId, week: week, session: session, date: date, activityId: activityId)
        return try encodeProgrammeCurrent(query: [:])
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

/// `PUT api/profile` sur une entrée invalide — miroir du `BadRequestException`
/// côté Nest (`ProfileController.update`). Message diagnostique seulement :
/// `SettingsViewModel.saveProfile` affiche son propre message générique sur
/// n'importe quelle erreur.
struct LocalProfileValidationError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// `PUT api/wake-schedule` sur une entrée invalide — miroir du
/// `BadRequestException` côté Nest (`WakeController.update`). Message
/// diagnostique seulement.
struct LocalWakeScheduleValidationError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

// MARK: - DTO d'encodage JSON — `GET`/`PUT api/profile` (incrément L6)
//
// Mêmes clés que `SettingsProfile` (`Pulse/Screens/Settings/SettingsModels.swift`)
// — miroir de `Profile` (`profile.controller.ts`).

private struct LocalProfileDTO: Encodable {
    let birthYear: Int?
    let sex: String?
    let weightKg: Double?
    let heightCm: Double?
}

/// Corps de `PUT api/profile` — mêmes quatre champs optionnels que
/// `{ birthYear?: number; sex?: string; weightKg?: number; heightCm?: number }`
/// (TS). Distinct de `SettingsProfileUpdateRequest` (`SettingsModels.swift`,
/// `Encodable` côté client, sans `weightKg` — cet écran ne l'envoie jamais,
/// cf. commentaire de section) : ce type-ci décode le corps JSON brut tel que
/// le contrat serveur l'accepte réellement, même si aucun écran natif actuel
/// n'exerce `weightKg` par cette route.
private struct LocalProfileUpdateRequestDTO: Decodable {
    let birthYear: Int?
    let sex: String?
    let weightKg: Double?
    let heightCm: Double?
}

/// DTO d'encodage JSON — `GET`/`PUT api/wake-schedule`, miroir de
/// `WakeSchedule` (`wake.controller.ts`). Même forme en lecture et en
/// écriture (`{ "schedule": { "<weekday>": <minutes>, ... } }`).
private struct LocalWakeScheduleDTO: Codable {
    let schedule: [String: Int]
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

// MARK: - DTO d'encodage JSON — `GET api/programme` (incrément L7a — lecture seule)
//
// Mêmes clés que `ProgrammeCurrent`/`ProgrammeChoice`/`ProgrammeActive`/
// `ProgrammeDomainView`/`ProgrammeTrainingDetail`/`ProgrammeNutritionDetail`/
// `ProgrammeSleepDetail`/... (`Pulse/Screens/Programme/ProgrammeModels.swift`).
// `LocalProgrammeDomainDTO` encode `detail` à la main (`encode(to:)`) pour le
// même motif polymorphe que `ProgrammeDomainView.init(from:)` décode à la
// main côté écran — `kind` détermine la forme, `Codable` synthétisé ne sait
// pas faire ça seul.

private struct LocalProgrammeCurrentDTO: Encodable {
    let date: String
    let domains: [LocalProgrammeDomainDTO]
}

private struct LocalProgrammeChoiceDTO: Encodable {
    let id: String
    let name: String
    let goal: String
    let source: String
    let weeks: Int
    let rules: Int
    let perWeek: Int
}

private struct LocalProgrammeActiveDTO: Encodable {
    let programmeId: String
    let startedOn: String
    let name: String
    let goal: String
    let source: String
    let week: Int
    let weeks: Int
    let days: [Int]
    let perWeek: Int
    let notes: [String]
}

private struct LocalProgrammeTrainingItemDTO: Encodable {
    let name: String
    let prescription: String
    let note: String?
}

private struct LocalProgrammeSessionDTO: Encodable {
    let key: String
    let name: String
    let sport: String
    let subSport: String?
    let minMinutes: Int?
    let items: [LocalProgrammeTrainingItemDTO]
}

private struct LocalProgrammeSessionProgressDTO: Encodable {
    let week: Int
    let session: LocalProgrammeSessionDTO
    let plannedOn: String?
    let status: String
    let done: Bool
    let date: String?
    let activityId: Int?
    let manual: Bool
}

private struct LocalProgrammeWeekFocusDTO: Encodable {
    let index: Int
    let focus: String?
}

private struct LocalProgrammeTrainingDetailDTO: Encodable {
    let focus: [LocalProgrammeWeekFocusDTO]
    let sessions: [LocalProgrammeSessionProgressDTO]
    let done: Int
    let total: Int
    let missed: Int
    let today: [LocalProgrammeSessionProgressDTO]
    let extras: [LocalProgrammeExtraActivityDTO]
}

private struct LocalProgrammeExtraActivityDTO: Encodable {
    let id: Int
    let date: String
    let sport: String?
    let subSport: String?
    let durationS: Double?
    let distanceM: Double?
}

private struct LocalProgrammeRangeDTO: Encodable {
    let min: Double?
    let max: Double?
}

private struct LocalProgrammeRuleRefDTO: Encodable {
    let key: String
    let label: String
    let detail: String
    let metric: String
    let perKg: Bool?
}

private struct LocalProgrammeRuleProgressDTO: Encodable {
    let rule: LocalProgrammeRuleRefDTO
    let target: LocalProgrammeRangeDTO
    let value: Double?
    let status: String
}

private struct LocalProgrammeDayProgressDTO: Encodable {
    let date: String
    let logged: Bool
    let rules: [LocalProgrammeRuleProgressDTO]
    let hits: Int
    let total: Int
}

private struct LocalProgrammeNutritionDetailDTO: Encodable {
    let today: LocalProgrammeDayProgressDTO
    let days: [LocalProgrammeDayProgressDTO]
    let weightKg: Double?
}

private struct LocalProgrammeSleepAxisDTO: Encodable {
    let onsetMean: Double
    let onsetSd: Double
    let wakeMean: Double
    let wakeSd: Double
}

private struct LocalProgrammeNightPointDTO: Encodable {
    let date: String
    let weekday: Int
    let workDay: Bool
    let onset: Double
    let wake: Double
    let sleepMin: Double
}

private struct LocalProgrammeSleepScaleDTO: Encodable {
    let min: Double
    let max: Double
}

private struct LocalProgrammeSleepBandDTO: Encodable {
    let upTo: Double?
    let label: String
    let risk: String
}

private struct LocalProgrammeSleepMetricDTO: Encodable {
    let key: String
    let label: String
    let detail: String
    let evidence: String
    let unit: String
    let informative: Bool
    let value: Double?
    let range: LocalProgrammeRangeDTO
    let scale: LocalProgrammeSleepScaleDTO
    let status: String
    let band: LocalProgrammeSleepBandDTO?
    let note: String?
}

private struct LocalProgrammeSleepDetailDTO: Encodable {
    let from: String?
    let to: String?
    let nights: Int
    let spanDays: Int
    let staleDays: Int
    let workNights: Int
    let freeNights: Int
    let pairs: Int
    let axis: LocalProgrammeSleepAxisDTO?
    let strip: [LocalProgrammeNightPointDTO]
    let metrics: [LocalProgrammeSleepMetricDTO]
    let hits: Int
    let total: Int
}

/// Détail polymorphe — miroir de l'union TypeScript renvoyée par `detailFor`
/// (`training`/`nutrition`/`sleep`), encodé à la main par
/// `LocalProgrammeDomainDTO.encode(to:)`.
private enum LocalProgrammeDetailDTO {
    case training(LocalProgrammeTrainingDetailDTO)
    case nutrition(LocalProgrammeNutritionDetailDTO)
    case sleep(LocalProgrammeSleepDetailDTO)
}

private struct LocalProgrammeDomainDTO: Encodable {
    let kind: String
    let label: String
    let drives: String
    let hint: String
    let choices: [LocalProgrammeChoiceDTO]
    let active: LocalProgrammeActiveDTO?
    let detail: LocalProgrammeDetailDTO?

    private enum CodingKeys: String, CodingKey {
        case kind, label, drives, hint, choices, active, detail
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(label, forKey: .label)
        try container.encode(drives, forKey: .drives)
        try container.encode(hint, forKey: .hint)
        try container.encode(choices, forKey: .choices)
        // `active: null` explicite (pas une clé omise) — miroir de l'objet
        // JS `{ ...domain, choices, active: null, detail: null }` (TS,
        // `domainView`), qui sérialise `null` là où `undefined` serait omis.
        // Sans effet observable côté décodage (`decodeIfPresent` traite les
        // deux cas identiquement), gardé pour fidélité au JSON serveur.
        if let active {
            try container.encode(active, forKey: .active)
        } else {
            try container.encodeNil(forKey: .active)
        }
        switch detail {
        case .none:
            try container.encodeNil(forKey: .detail)
        case .training(let d):
            try container.encode(d, forKey: .detail)
        case .nutrition(let d):
            try container.encode(d, forKey: .detail)
        case .sleep(let d):
            try container.encode(d, forKey: .detail)
        }
    }
}

/// `POST api/programme/activate`/`stop`/`session` sur une entrée invalide, ou
/// `session` sans programme `training` actif — miroir du `BadRequestException`
/// côté Nest (`ProgrammeController`). Message diagnostique, affiché tel quel
/// par `ProgrammeViewModel.mutate` (`Self.message(for:)`).
struct LocalProgrammeValidationError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

// MARK: - DTO de décodage JSON — corps `POST api/programme/activate`/`stop`/
// `session` (incrément L7b) — mêmes clés que `ProgrammeActivateRequest`/
// `ProgrammeStopRequest`/`ProgrammeSessionRequest`
// (`Pulse/Screens/Programme/ProgrammeModels.swift`), tous les champs restent
// optionnels ici (même si l'écran natif les envoie toujours) pour décoder
// fidèlement le contrat serveur, qui les traite comme tels
// (`body.programmeId?`, `body.days?`…).

private struct LocalProgrammeActivateRequestDTO: Decodable {
    let programmeId: String?
    let startedOn: String?
    let days: [Int]?
}

private struct LocalProgrammeStopRequestDTO: Decodable {
    let kind: String?
}

private struct LocalProgrammeSessionRequestDTO: Decodable {
    let week: Int?
    let session: String?
    let date: String?
    let done: Bool?
    let activityId: Int?
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
/// ignoré par `NutritionDay`, qui ne le modélise pas) — `"auto"`/`"manual"`
/// réel, cf. `RealLocalPulseBackend.effectiveTargets`. `programme` toujours
/// `nil` : moteur programme non porté (cf. en-tête de section `day/:date`).
private struct LocalNutritionDayDTO: Encodable {
    let date: String
    let entries: [LocalNutritionEntryDTO]
    let totals: LocalNutritionMacrosDTO
    let targets: LocalNutritionMacrosDTO
    let targetSource: String
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

// MARK: - DTO d'encodage JSON — Nutrition, cibles calculées
// (`targets`/`weekly`/`timing`/`suggestions` — cf. section d'implémentation,
// incrément L5-Nutrition-analytics). Champs réduits à ceux consommés par
// l'écran (`Pulse/Screens/Nutrition/NutritionModels.swift`) — mêmes
// simplifications déjà actées explicitement côté modèle client (« détail de
// calcul de l'objectif… non consommés »), cf. son en-tête. `programme` reste
// TOUJOURS `nil` (moteur programme non porté, cf. `NutritionTarget.swift`).

/// Miroir de `NutritionMacroProgrammePlan{name, unmet}` — jamais instancié
/// non-`nil` ici (`LocalNutritionMacroPlanDTO.programme` reste `nil`).
private struct LocalNutritionMacroProgrammeStubDTO: Encodable {
    let name: String
    let unmet: [String]
}

private struct LocalNutritionMacroPlanDTO: Encodable {
    let proteinG: Double?
    let fatG: Double?
    let carbsG: Double?
    let fiberG: Double?
    let proteinPerKg: Double?
    let programme: LocalNutritionMacroProgrammeStubDTO?

    init(_ macros: NutritionEngineMacroPlan) {
        proteinG = macros.proteinG
        fatG = macros.fatG
        carbsG = macros.carbsG
        fiberG = macros.fiberG
        proteinPerKg = macros.proteinPerKg
        programme = nil
    }
}

private struct LocalNutritionAutoDetailComputedDTO: Encodable {
    let restingKcal: Double?
    let activeKcal: Double?
}

/// Miroir du sous-arbre `auto` de `getTargets`/`day` (TS) — champs réduits à
/// ceux du modèle `NutritionAutoTarget` côté écran.
private struct LocalNutritionAutoTargetComputedDTO: Encodable {
    let status: String
    let source: String
    let missing: [String]
    let targetKcal: Double?
    let expenditureKcal: Double?
    let deficitKcal: Double?
    let macros: LocalNutritionMacroPlanDTO
    let guardStatus: String
    let detail: LocalNutritionAutoDetailComputedDTO

    enum CodingKeys: String, CodingKey {
        case status, source, missing, targetKcal, expenditureKcal, deficitKcal, macros, detail
        case guardStatus = "guard"
    }

    init(_ r: NutritionEngineTargetResult) {
        status = r.status
        source = r.source
        missing = r.missing
        targetKcal = r.targetKcal
        expenditureKcal = r.expenditureKcal
        deficitKcal = r.deficitKcal
        macros = LocalNutritionMacroPlanDTO(r.macros)
        guardStatus = r.guardStatus
        detail = LocalNutritionAutoDetailComputedDTO(restingKcal: r.detail.restingKcal, activeKcal: r.detail.activeKcal)
    }
}

/// `GET api/nutrition/targets` — miroir réduit de `getTargets` (TS), cf.
/// commentaire de `encodeNutritionTargets`.
private struct LocalNutritionTargetsResponseDTO: Encodable {
    let mode: String
    let targets: LocalNutritionMacrosDTO
    let source: String
    let auto: LocalNutritionAutoTargetComputedDTO
}

private struct LocalNutritionWeeklyResponseDTO: Encodable {
    let loggedDays: Int
    let partialDays: Int
    let emptyDays: Int
    let avgDeficitKcal: Double?
    let alert: Bool
    let thresholdKcal: Double

    init(_ r: NutritionEngineWeeklyResult) {
        loggedDays = r.loggedDays
        partialDays = r.partialDays
        emptyDays = r.emptyDays
        avgDeficitKcal = r.avgDeficitKcal
        alert = r.alert
        thresholdKcal = r.thresholdKcal
    }
}

private struct LocalNutritionMealTimingDTO: Encodable {
    let lastMealTs: Int
    let digestionEndTs: Int
    let nextMealTs: Int
    let gymStartTs: Int
    let gymEndTs: Int
    let avgStress: Int?
    let windowH: Double
}

private struct LocalNutritionTimingResponseDTO: Encodable {
    let meal: LocalNutritionMealTimingDTO?
}

/// Miroir de l'objet `give` (`...give`) de `NutritionController.suggestions`
/// — quantités ABSOLUES pour la portion suggérée (pas pour-100 g), SANS `fat`
/// (le serveur non plus).
private struct LocalNutritionSuggestionItemDTO: Encodable {
    let foodId: Int
    let name: String
    let grams: Double
    let units: Double?
    let unitLabel: String?
    let unitGrams: Double?
    let kcal: Double
    let protein: Double
    let carbs: Double
    let fiber: Double
}

private struct LocalNutritionSuggestionsResponseDTO: Encodable {
    let remaining: LocalNutritionMacrosDTO
    let items: [LocalNutritionSuggestionItemDTO]
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
