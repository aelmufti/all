//
//  LocalDb.swift
//  all (bridge-connect)
//
//  Base SQLite locale « Pulse embarqué » — schéma calqué EXACTEMENT (mêmes
//  noms de colonnes/types) sur les tables bien-être de
//  `custom-connect/server/src/db.service.ts` (`SCHEMA`), et la logique
//  d'upsert sur `IngestService.storeWellness`/`writeSleep`
//  (`custom-connect/server/src/ingest/ingest.service.ts`) — pour que
//  `RealLocalPulseBackend` puisse rejouer les mêmes requêtes que
//  `WellnessController`. Incrément L1, cf. `docs/stockage-local.md`.
//
//  Sous-ensemble : tables bien-être (`imported_files`, `wellness_days`,
//  `wellness_counters`, `wellness_counter_samples`, `wellness_samples`,
//  `wellness_sleep`) + activités (`activities`, `activity_zones` — incrément
//  L3, cf. `docs/stockage-local.md`). Le reste (`foods`…) arrive avec les
//  incréments qui en ont besoin.
//
//  `activity_zones` : schéma porté pour parité avec `db.service.ts`, mais
//  **jamais peuplé** ici, comme côté serveur — `GET api/activities(/:id)` ne
//  la lit pas (les zones de FC du détail viennent d'un recalcul à la volée
//  du `.fit`, cf. `RealLocalPulseBackend`/`FitActivityExtractor`), elle sert
//  à un job de fond distinct (calcul batch, hors périmètre L3).
//
//  Fichier : `Application Support/local-pulse/pulse-embarque.sqlite`,
//  protection `completeUnlessOpen` — même politique que `SpoolStore`.
//

import Foundation

final class LocalDb {
    private let db: SQLiteDatabase

    convenience init() throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("local-pulse", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        excludeFromBackup(dir)
        try self.init(path: dir.appendingPathComponent("pulse-embarque.sqlite").path)
    }

    /// Init testable : base à un chemin arbitraire (fichier temporaire en test).
    init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try db.execute(Self.schema)
        try Self.migrate(db, migrations: Self.migrations)
        try seedFoodsIfNeeded()
    }

    // MARK: - Migrations de schéma
    //
    // `schema` (ci-dessous) est la base, version 0 : `CREATE TABLE IF NOT EXISTS`
    // ne sait pas faire évoluer une table déjà créée. Tout changement ultérieur
    // (colonne, table, index) s'AJOUTE à la fin de `migrations` — jamais de
    // modification ni de suppression d'une entrée existante. La version de la base
    // (`PRAGMA user_version`) est le nombre de migrations déjà appliquées.

    static let migrations: [String] = []

    /// Applique les migrations manquantes, dans l'ordre, chacune dans sa
    /// transaction avec l'avancement de version. La version est relue DANS la
    /// transaction : deux connexions qui ouvrent la base en même temps
    /// n'appliquent pas deux fois la même migration. Internal pour les tests.
    static func migrate(_ db: SQLiteDatabase, migrations: [String]) throws {
        while true {
            var applied = false
            try db.transaction {
                let version = try schemaVersion(db)
                guard version < migrations.count else { return }
                try db.execute(migrations[version])
                try db.execute("PRAGMA user_version = \(version + 1)")
                applied = true
            }
            if !applied { return }
        }
    }

    static func schemaVersion(_ db: SQLiteDatabase) throws -> Int {
        var version = 0
        try db.run("PRAGMA user_version") { r in version = Int(r.double(0) ?? 0) }
        return version
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS imported_files (
      hash TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      file_name TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS wellness_days (
      date TEXT PRIMARY KEY,
      resting_hr INTEGER,
      bmr_kcal INTEGER,
      body_battery_high INTEGER,
      body_battery_low INTEGER
    );
    CREATE TABLE IF NOT EXISTS wellness_counters (
      date TEXT NOT NULL,
      activity_type TEXT NOT NULL,
      steps INTEGER,
      active_calories INTEGER,
      distance_m REAL,
      active_time_s REAL,
      PRIMARY KEY (date, activity_type)
    );
    CREATE TABLE IF NOT EXISTS wellness_counter_samples (
      ts INTEGER NOT NULL,
      activity_type TEXT NOT NULL,
      steps INTEGER,
      active_calories INTEGER,
      PRIMARY KEY (ts, activity_type)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS wellness_samples (
      metric TEXT NOT NULL,
      ts INTEGER NOT NULL,
      value REAL NOT NULL,
      PRIMARY KEY (metric, ts)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS wellness_sleep (
      date TEXT PRIMARY KEY,
      start_ts INTEGER NOT NULL,
      end_ts INTEGER NOT NULL,
      duration_s INTEGER,
      score INTEGER,
      deep_s INTEGER,
      light_s INTEGER,
      rem_s INTEGER,
      awake_s INTEGER,
      awakenings INTEGER,
      phases TEXT,
      file_hash TEXT
    );
    CREATE TABLE IF NOT EXISTS body_battery_state (
      date TEXT PRIMARY KEY,
      start_value REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS activities (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      file_hash TEXT NOT NULL UNIQUE,
      file_name TEXT NOT NULL,
      sport TEXT,
      sub_sport TEXT,
      start_time TEXT,
      duration_s REAL,
      distance_m REAL,
      calories INTEGER,
      avg_hr INTEGER,
      max_hr INTEGER,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_activities_start_time ON activities(start_time DESC);
    CREATE TABLE IF NOT EXISTS activity_zones (
      activity_id INTEGER NOT NULL,
      zone INTEGER NOT NULL,
      seconds REAL NOT NULL,
      PRIMARY KEY (activity_id, zone)
    );
    CREATE TABLE IF NOT EXISTS weight_log (
      date TEXT PRIMARY KEY,
      kg REAL NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS foods (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      barcode TEXT UNIQUE,
      name TEXT NOT NULL,
      kcal REAL,
      protein REAL,
      carbs REAL,
      fiber REAL,
      fat REAL,
      unit_label TEXT,
      unit_grams REAL,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS food_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      date TEXT NOT NULL,
      food_id INTEGER,
      name TEXT NOT NULL,
      grams REAL NOT NULL,
      kcal REAL,
      protein REAL,
      carbs REAL,
      fiber REAL,
      fat REAL,
      unit_label TEXT,
      unit_qty REAL,
      ts INTEGER,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_food_log_date ON food_log(date);
    CREATE TABLE IF NOT EXISTS programme_state (
      programme_id TEXT PRIMARY KEY,
      kind TEXT NOT NULL DEFAULT 'nutrition',
      started_on TEXT NOT NULL,
      active INTEGER NOT NULL DEFAULT 1,
      days TEXT
    );
    CREATE TABLE IF NOT EXISTS programme_plan (
      programme_id TEXT NOT NULL,
      week INTEGER NOT NULL,
      session TEXT NOT NULL,
      date TEXT NOT NULL,
      PRIMARY KEY (programme_id, week, session)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS programme_plan_date ON programme_plan (programme_id, date);
    CREATE TABLE IF NOT EXISTS programme_done (
      programme_id TEXT NOT NULL,
      week INTEGER NOT NULL,
      session TEXT NOT NULL,
      date TEXT NOT NULL,
      activity_id INTEGER,
      PRIMARY KEY (programme_id, week, session)
    ) WITHOUT ROWID;
    """

    // MARK: - Dédup (`imported_files`) — même principe que Pulse : hash du
    // contenu, indépendant du nom de fichier montre.

    func isImported(hash: String) throws -> Bool {
        var found = false
        try db.run("SELECT 1 FROM imported_files WHERE hash = ?", [.text(hash)]) { _ in found = true }
        return found
    }

    /// Ce que la base contient, pour Paramètres › Stockage — même lecture que
    /// l'inventaire de Pulse (`api/sync/inventory` : activités, nuits, jours).
    struct ContentCounts: Equatable {
        var activities = 0
        var nights = 0
        var days = 0
    }

    func contentCounts() throws -> ContentCounts {
        func count(_ table: String) throws -> Int {
            var n = 0
            try db.run("SELECT COUNT(*) FROM \(table)") { r in n = Int(r.double(0) ?? 0) }
            return n
        }
        return ContentCounts(
            activities: try count("activities"), nights: try count("wellness_sleep"), days: try count("wellness_days"))
    }

    /// Vrai si la base porte ce fichier : hash dans `imported_files`
    /// (wellness/sommeil, inséré dans la MÊME transaction que les données) ou dans
    /// `activities.file_hash`. C'est la preuve qu'un fichier journalisé
    /// `ingested` (`SpoolEntry.ingest`) est réellement en base avant d'archiver
    /// sur la montre (`GarminSession`) ou de supprimer le `.fit` (`SpoolPurger`).
    func holdsIngestedFile(hash: String) throws -> Bool {
        try isImported(hash: hash) || isActivityImported(hash: hash)
    }

    struct ImportedFileRow { let hash: String; let fileName: String }

    /// Fichiers déjà importés d'un `kind` donné (`wellness`/`sleep`) — miroir
    /// de la requête `files` de `reparseCounters`/`reparseSleep` (TS,
    /// `ingest.service.ts`) : sert aux relectures versionnées ponctuelles
    /// (rétro-remplissage, cf. `LocalIngestor.backfillBodyBatteryIfNeeded`).
    func importedFiles(kind: String) throws -> [ImportedFileRow] {
        var out: [ImportedFileRow] = []
        try db.run("SELECT hash, file_name FROM imported_files WHERE kind = ?", [.text(kind)]) { r in
            guard let hash = r.text(0), let fileName = r.text(1) else { return }
            out.append(ImportedFileRow(hash: hash, fileName: fileName))
        }
        return out
    }

    // MARK: - Ingestion bien-être (miroir `IngestService.storeWellness`)

    func storeWellness(_ data: FitWellnessData, hash: String, fileName: String) throws {
        try db.transaction {
            try db.run(
                "INSERT OR IGNORE INTO imported_files (hash, kind, file_name) VALUES (?, 'wellness', ?)",
                [.text(hash), .text(fileName)])

            for sample in data.counterSamples {
                try db.run(
                    """
                    INSERT INTO wellness_counter_samples (ts, activity_type, steps, active_calories)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(ts, activity_type) DO UPDATE SET
                      steps = MAX(COALESCE(wellness_counter_samples.steps, 0), COALESCE(excluded.steps, 0)),
                      active_calories = MAX(COALESCE(wellness_counter_samples.active_calories, 0), COALESCE(excluded.active_calories, 0))
                    """,
                    [.double(sample.ts), .text(sample.activityType), sqliteOptional(sample.steps), sqliteOptional(sample.activeCalories)])
            }

            for day in data.days {
                try db.run(
                    """
                    INSERT INTO wellness_days (date, resting_hr, bmr_kcal) VALUES (?, ?, ?)
                    ON CONFLICT(date) DO UPDATE SET
                      resting_hr = COALESCE(excluded.resting_hr, wellness_days.resting_hr),
                      bmr_kcal = COALESCE(excluded.bmr_kcal, wellness_days.bmr_kcal)
                    """,
                    [.text(day.date), sqliteOptional(day.restingHr), sqliteOptional(day.bmrKcal)])
            }

            for counter in data.counters {
                try db.run(
                    """
                    INSERT INTO wellness_counters (date, activity_type, steps, active_calories, distance_m, active_time_s)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(date, activity_type) DO UPDATE SET
                      steps = MAX(COALESCE(wellness_counters.steps, 0), COALESCE(excluded.steps, 0)),
                      active_calories = MAX(COALESCE(wellness_counters.active_calories, 0), COALESCE(excluded.active_calories, 0)),
                      distance_m = MAX(COALESCE(wellness_counters.distance_m, 0), COALESCE(excluded.distance_m, 0)),
                      active_time_s = MAX(COALESCE(wellness_counters.active_time_s, 0), COALESCE(excluded.active_time_s, 0))
                    """,
                    [.text(counter.date), .text(counter.activityType), sqliteOptional(counter.steps),
                     sqliteOptional(counter.activeCalories), sqliteOptional(counter.distanceM), sqliteOptional(counter.activeTimeS)])
            }

            for sample in data.samples {
                try db.run(
                    "INSERT OR IGNORE INTO wellness_samples (metric, ts, value) VALUES (?, ?, ?)",
                    [.text(sample.metric), .double(sample.ts), .double(sample.value)])
            }
        }
    }

    /// Insertion brute d'échantillons `bb` SEULS — utilisée par le
    /// rétro-remplissage unique (`LocalIngestor.backfillBodyBatteryIfNeeded`,
    /// `docs/duree-ideale-sommeil.md` §1). Ne touche à aucune autre table
    /// (`imported_files` déjà peuplée pour ces fichiers, pas de re-upsert des
    /// jours/compteurs). `INSERT OR IGNORE`, comme `storeWellness` — idempotent
    /// si rejoué.
    func insertBodyBatterySamples(_ samples: [FitWellnessSample]) throws {
        guard !samples.isEmpty else { return }
        try db.transaction {
            for sample in samples where sample.metric == "bb" {
                try db.run(
                    "INSERT OR IGNORE INTO wellness_samples (metric, ts, value) VALUES (?, ?, ?)",
                    [.text(sample.metric), .double(sample.ts), .double(sample.value)])
            }
        }
    }

    // MARK: - Ingestion sommeil (miroir `IngestService.writeSleep`)

    func storeSleep(_ sleep: FitSleepSummary, hash: String, fileName: String) throws {
        try db.transaction {
            try db.run(
                "INSERT OR IGNORE INTO imported_files (hash, kind, file_name) VALUES (?, 'sleep', ?)",
                [.text(hash), .text(fileName)])
            try db.run(
                """
                INSERT INTO wellness_sleep
                  (date, start_ts, end_ts, duration_s, score, deep_s, light_s, rem_s, awake_s, awakenings, phases, file_hash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(date) DO UPDATE SET
                  start_ts = excluded.start_ts, end_ts = excluded.end_ts, duration_s = excluded.duration_s,
                  score = excluded.score, deep_s = excluded.deep_s, light_s = excluded.light_s, rem_s = excluded.rem_s,
                  awake_s = excluded.awake_s, awakenings = excluded.awakenings, phases = excluded.phases,
                  file_hash = excluded.file_hash
                """,
                [.text(sleep.date), .double(sleep.startTs), .double(sleep.endTs), .double(sleep.durationS),
                 sqliteOptional(sleep.score), .double(sleep.deepS), .double(sleep.lightS), .double(sleep.remS),
                 .double(sleep.awakeS), sqliteOptional(sleep.awakenings), .text(Self.encodePhases(sleep.phases)), .text(hash)])
        }
    }

    private static func encodePhases(_ phases: [FitSleepPhase]) -> String {
        let array: [[String: Any]] = phases.map { ["from": $0.from, "to": $0.to, "stage": $0.stage] }
        guard let data = try? JSONSerialization.data(withJSONObject: array) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: - Ingestion/lecture activités (incrément L3, miroir `IngestService.ingestBuffer`
    // branche `activity` + `ActivitiesController.list`/`detail`)

    /// Dédup spécifique aux activités — miroir de `existingActivity` (TS,
    /// `ingestBuffer`) : contrairement à wellness/sommeil, une activité
    /// n'écrit JAMAIS dans `imported_files` côté serveur, sa dédup passe
    /// uniquement par `activities.file_hash` (contrainte UNIQUE). Vérifié
    /// AVANT `storeActivity` par `LocalIngestor.ingest` — sans ce contrôle,
    /// réingérer deux fois le même fichier ferait échouer l'`INSERT` sur la
    /// contrainte UNIQUE (remonterait en `.error`, pas `.duplicate`).
    func isActivityImported(hash: String) throws -> Bool {
        var found = false
        try db.run("SELECT 1 FROM activities WHERE file_hash = ?", [.text(hash)]) { _ in found = true }
        return found
    }

    /// Miroir de la branche `activity` d'`IngestService.ingestBuffer` — même
    /// colonnes, même ordre. Renvoie l'id auto-incrémenté inséré (ou celui de
    /// la ligne déjà portée par ce hash). Test d'existence ET insertion dans une
    /// même transaction `IMMEDIATE` : deux écritures concurrentes du même
    /// fichier (autre connexion/processus) ne peuvent plus ni doubler la ligne ni
    /// échouer sur la contrainte UNIQUE.
    @discardableResult
    func storeActivity(_ summary: FitActivityExtractor.Summary, hash: String, fileName: String) throws -> Int {
        var id = 0
        try db.transaction {
            var existing: Int?
            try db.run("SELECT id FROM activities WHERE file_hash = ?", [.text(hash)]) { r in existing = Int(r.double(0) ?? 0) }
            if let existing {
                id = existing
                return
            }
            try db.run(
                """
                INSERT INTO activities (file_hash, file_name, sport, sub_sport, start_time, duration_s, distance_m, calories, avg_hr, max_hr)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(hash), .text(fileName), sqliteOptionalText(summary.sport), sqliteOptionalText(summary.subSport),
                 sqliteOptionalText(summary.startTime), sqliteOptional(summary.durationS), sqliteOptional(summary.distanceM),
                 sqliteOptional(summary.calories), sqliteOptional(summary.avgHr), sqliteOptional(summary.maxHr)])
            try db.run("SELECT last_insert_rowid()") { r in id = Int(r.double(0) ?? 0) }
        }
        return id
    }

    /// Une ligne `activities` — mêmes colonnes que `ACTIVITY_COLUMNS` côté
    /// Nest (`activities.controller.ts`), sans `fileHash` (celui-ci n'est
    /// exposé que par `activity(id:)`, jamais par la liste/le résumé JSON).
    struct ActivityRow {
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
    }

    func activitiesCount() throws -> Int {
        var count = 0
        try db.run("SELECT COUNT(*) FROM activities") { r in count = Int(r.double(0) ?? 0) }
        return count
    }

    /// Miroir de `ActivitiesController.list` — plus récent en premier.
    func activities(limit: Int, offset: Int) throws -> [ActivityRow] {
        var out: [ActivityRow] = []
        try db.run(
            """
            SELECT id, file_name, sport, sub_sport, start_time, duration_s, distance_m, calories, avg_hr, max_hr
            FROM activities ORDER BY start_time DESC LIMIT ? OFFSET ?
            """,
            [.int(limit), .int(offset)]) { r in
            out.append(Self.activityRow(from: r))
        }
        return out
    }

    /// Résumé + `file_hash` — le second sert à `RealLocalPulseBackend` pour
    /// retrouver les octets bruts du `.fit` dans le spool (cf. `detail()`
    /// côté serveur, qui fait le même `SELECT ... file_hash ...` avant de
    /// relire `config.filesDir/<hash>.fit`).
    func activity(id: Int) throws -> (row: ActivityRow, fileHash: String)? {
        var result: (row: ActivityRow, fileHash: String)?
        try db.run(
            """
            SELECT id, file_name, sport, sub_sport, start_time, duration_s, distance_m, calories, avg_hr, max_hr, file_hash
            FROM activities WHERE id = ?
            """,
            [.int(id)]) { r in
            result = (Self.activityRow(from: r), r.text(10) ?? "")
        }
        return result
    }

    private static func activityRow(from r: SQLiteRow) -> ActivityRow {
        ActivityRow(
            id: Int(r.double(0) ?? 0), fileName: r.text(1) ?? "",
            sport: r.text(2), subSport: r.text(3), startTime: r.text(4),
            durationS: r.double(5), distanceM: r.double(6), calories: r.double(7),
            avgHr: r.double(8), maxHr: r.double(9))
    }

    // MARK: - Lecture (`wellness/days`, `wellness/dates` — cf. `RealLocalPulseBackend`)

    /// Nombre d'échantillons stockés pour une métrique (`hr`/`stress`/`spo2`/
    /// `respiration`) — utilisé par les tests d'ingestion (`allTests/FitDecoderTests.swift`)
    /// pour vérifier le compte de lignes écrites sans dupliquer la requête
    /// dans le test lui-même ; utile aussi comme diagnostic simple.
    func sampleCount(metric: String) throws -> Int {
        var count = 0
        try db.run("SELECT COUNT(*) FROM wellness_samples WHERE metric = ?", [.text(metric)]) { row in
            count = Int(row.double(0) ?? 0)
        }
        return count
    }

    func dates() throws -> [String] {
        var out: [String] = []
        try db.run("SELECT date FROM wellness_days ORDER BY date ASC") { row in
            if let d = row.text(0) { out.append(d) }
        }
        return out
    }

    struct DayRow {
        let date: String
        var restingHr: Double?
        var bmrKcal: Double?
        var steps: Double?
        var activeCalories: Double?
        var distanceM: Double?
        var minHr: Double?
        var maxHr: Double?
        var avgStress: Double?
        var sleepDurationS: Double?
        var sleepScore: Double?
    }

    /// Miroir simplifié de `WellnessController.days` — cf. `RealLocalPulseBackend`
    /// pour ce qui manque volontairement (`bodyBattery*`/`sportCalories`,
    /// nécessitent le simulateur "pivot" et les activités, hors périmètre L1).
    func days(limit: Int) throws -> [DayRow] {
        var dates: [String] = []
        try db.run(
            """
            SELECT date FROM (
              SELECT date FROM wellness_days
              UNION
              SELECT date FROM wellness_sleep WHERE duration_s > 0
            ) ORDER BY date DESC LIMIT ?
            """, [.int(limit)]) { row in
            if let d = row.text(0) { dates.append(d) }
        }
        dates.reverse()

        var out: [DayRow] = []
        for date in dates {
            var row = DayRow(date: date)
            try db.run("SELECT resting_hr, bmr_kcal FROM wellness_days WHERE date = ?", [.text(date)]) { r in
                row.restingHr = r.double(0)
                row.bmrKcal = r.double(1)
            }
            try db.run(
                "SELECT SUM(steps), SUM(active_calories), SUM(distance_m) FROM wellness_counters WHERE date = ?",
                [.text(date)]) { r in
                row.steps = r.double(0)
                row.activeCalories = r.double(1)
                row.distanceM = r.double(2)
            }

            let offset = Self.localOffsetSeconds(forDate: date)
            let t0 = Self.dayStartUnixUTC(date) - offset
            let t1 = t0 + 86400
            try db.run(
                "SELECT MIN(value), MAX(value) FROM wellness_samples WHERE metric = 'hr' AND ts >= ? AND ts < ?",
                [.double(t0), .double(t1)]) { r in
                row.minHr = r.double(0)
                row.maxHr = r.double(1)
            }
            try db.run(
                "SELECT AVG(value) FROM wellness_samples WHERE metric = 'stress' AND ts >= ? AND ts < ?",
                [.double(t0), .double(t1)]) { r in
                // Arrondi — miroir de `Math.round(e.sum / e.n)` côté
                // `WellnessController.days` (TS) : certains écrans décodent
                // `avgStress` en `Int?` (`DashboardWellnessDayRow`), une
                // moyenne fractionnaire ferait échouer leur décodage JSON.
                row.avgStress = r.double(0).map { $0.rounded() }
            }
            try db.run("SELECT duration_s, score FROM wellness_sleep WHERE date = ?", [.text(date)]) { r in
                row.sleepDurationS = r.double(0)
                row.sleepScore = r.double(1)
            }
            out.append(row)
        }
        return out
    }

    /// Minuit du jour calendaire `date`, en secondes epoch Unix, calculé en
    /// **UTC** — même convention que `WellnessController` (`Date.parse(
    /// \`${date}T00:00:00Z\`)`) : la borne du jour est "l'horloge locale
    /// déguisée en UTC", pas minuit au fuseau réel.
    private static func dayStartUnixUTC(_ date: String) -> Double {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)?.timeIntervalSince1970 ?? 0
    }

    /// Décalage fuseau au téléphone à midi local du jour donné — substitut de
    /// `tzOffsetSeconds` (var d'env `DISPLAY_TZ` côté serveur) : ici il n'y a
    /// qu'un fuseau, celui de l'appareil. Accès relâché à `internal`
    /// (incrément L7a) : `ProgrammeSleepEngine.analyseSleep` (miroir
    /// `sleep.ts`) a besoin du même `offsetOf(date)` que `dayDetail`, câblé
    /// depuis `RealLocalPulseBackend` sans dupliquer la formule.
    static func localOffsetSeconds(forDate date: String) -> Double {
        let noon = dayStartUnixUTC(date) + 12 * 3600
        return Double(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: noon)))
    }

    // MARK: - `GET wellness/day/:date` (incrément L2, cf. `RealLocalPulseBackend`)
    //
    // Miroir de `WellnessController.day` + ses aides privées
    // (`samplesBetween`, `counterSeries`, `watchSleep`, `pivotSeries`,
    // `bodyBatteryStart`) — même requêtage, même bornage temporel. Divergence
    // assumée : le décalage horaire vient de `localOffsetSeconds` (fuseau du
    // téléphone), pas de `DISPLAY_TZ` (un seul fuseau pertinent ici, cf.
    // `days(limit:)` ci-dessus, déjà sur ce principe).

    struct DayDetail {
        let date: String
        let restingHr: Double?
        let bmrKcal: Double?
        let steps: Double?
        let activeCalories: Double?
        let distanceM: Double?
        let hr: [LocalSample]
        let stress: [LocalSample]
        let spo2: [LocalSample]
        let respiration: [LocalSample]
        let bodyBatteryPivot: [LocalSample]
        let counterSeries: [CounterPoint]
        let sleepSegments: [SleepInterval]
        let sleepMain: SleepMain?
        let sleepStages: [SleepStage]
        let sleepScore: Double?
    }

    struct CounterPoint {
        let minute: Int
        let steps: Double
        let activeCalories: Double
    }

    struct SleepInterval {
        let from: Double
        let to: Double
    }

    struct SleepStage {
        let from: Double
        let to: Double
        /// "deep" | "light" | "rem" | "awake"
        let stage: String
    }

    struct SleepMain {
        let from: Double
        let to: Double
        let durationS: Double
    }

    private struct SleepNight {
        let segments: [SleepInterval]
        let main: SleepMain?
        let stages: [SleepStage]
        let score: Double?
    }

    private struct WatchSleepResult {
        /// Union des segments "endormi" de TOUTES les nuits couvertes par la
        /// plage interrogée (peut être 0, 1 ou 2 nuits pour la fenêtre ±12h
        /// utilisée par `dayDetail`/`pivotSeries`) — sert à `asleepAt` du
        /// simulateur pivot, indépendamment de la nuit "du jour" affichée.
        let segments: [SleepInterval]
        let byDate: [String: SleepNight]
    }

    /// Assemble la réponse complète de `GET wellness/day/:date` —
    /// `RealLocalPulseBackend` n'a plus qu'à la sérialiser en JSON.
    func dayDetail(date: String) throws -> DayDetail {
        let t0 = Self.dayStartUnixUTC(date)
        let t1 = t0 + 86400
        let offset = Self.localOffsetSeconds(forDate: date)

        var restingHr: Double?
        var bmrKcal: Double?
        try db.run("SELECT resting_hr, bmr_kcal FROM wellness_days WHERE date = ?", [.text(date)]) { r in
            restingHr = r.double(0)
            bmrKcal = r.double(1)
        }

        var steps: Double?
        var activeCalories: Double?
        var distanceM: Double?
        try db.run(
            "SELECT SUM(steps), SUM(active_calories), SUM(distance_m) FROM wellness_counters WHERE date = ?",
            [.text(date)]) { r in
            steps = r.double(0)
            activeCalories = r.double(1)
            distanceM = r.double(2)
        }

        let hr = try samplesBetween(metric: "hr", t0Local: t0, t1Local: t1, offsetSeconds: offset)
        let stress = try samplesBetween(metric: "stress", t0Local: t0, t1Local: t1, offsetSeconds: offset)
        let spo2 = try samplesBetween(metric: "spo2", t0Local: t0, t1Local: t1, offsetSeconds: offset)
        let respiration = try samplesBetween(metric: "respiration", t0Local: t0, t1Local: t1, offsetSeconds: offset)
        let counterSeriesRows = try counterSeries(t0Local: t0, t1Local: t1, offsetSeconds: offset)

        // Fenêtre ±12h — mêmes bornes que `WellnessController.day` : une nuit
        // peut chevaucher minuit dans les deux sens.
        let sleep = try watchSleep(rangeStart: t0 - 12 * 3600, rangeEnd: t1 + 12 * 3600, offsetSeconds: offset)
        let nightSleep = sleep.byDate[date]
        let daySegments = sleep.segments.filter { $0.to > t0 && $0.from < t1 }

        let bbStart = try bodyBatteryStart(date: date)
        let bodyBatteryPivot = try pivotSeries(date: date, start: bbStart)

        return DayDetail(
            date: date, restingHr: restingHr, bmrKcal: bmrKcal,
            steps: steps, activeCalories: activeCalories, distanceM: distanceM,
            hr: hr, stress: stress, spo2: spo2, respiration: respiration,
            bodyBatteryPivot: bodyBatteryPivot, counterSeries: counterSeriesRows,
            sleepSegments: daySegments, sleepMain: nightSleep?.main, sleepStages: nightSleep?.stages ?? [],
            sleepScore: nightSleep?.score)
    }

    /// Miroir de `samplesBetween` (TS) — bornes en repère UTC (soustrait
    /// l'offset), résultat republié en repère "affichage" (ré-ajoute
    /// l'offset), comme le serveur.
    func samplesBetween(metric: String, t0Local: Double, t1Local: Double, offsetSeconds: Double) throws -> [LocalSample] {
        var out: [LocalSample] = []
        try db.run(
            "SELECT ts, value FROM wellness_samples WHERE metric = ? AND ts >= ? AND ts < ? ORDER BY ts ASC",
            [.text(metric), .double(t0Local - offsetSeconds), .double(t1Local - offsetSeconds)]) { r in
            guard let ts = r.double(0), let value = r.double(1) else { return }
            out.append(LocalSample(ts: ts + offsetSeconds, value: value))
        }
        return out
    }

    private static let counterResetLagS: Double = 90

    /// Miroir de `counterSeries` (TS) — reconstruit une série minute par
    /// minute de pas/calories cumulés, en fusionnant les compteurs par type
    /// d'activité (max courant, jamais de décroissance — cf. commentaire de
    /// `storeWellness` sur `wellness_counter_samples`).
    func counterSeries(t0Local: Double, t1Local: Double, offsetSeconds: Double) throws -> [CounterPoint] {
        struct Row {
            let ts: Double
            let activityType: String
            let steps: Double?
            let activeCalories: Double?
        }
        var rows: [Row] = []
        try db.run(
            """
            SELECT ts, activity_type, steps, active_calories
            FROM wellness_counter_samples WHERE ts >= ? AND ts < ? ORDER BY ts ASC
            """,
            [.double(t0Local - offsetSeconds + Self.counterResetLagS), .double(t1Local - offsetSeconds + Self.counterResetLagS)]) { r in
            guard let ts = r.double(0), let type = r.text(1) else { return }
            rows.append(Row(ts: ts, activityType: type, steps: r.double(2), activeCalories: r.double(3)))
        }

        var steps: [String: Double] = [:]
        var calories: [String: Double] = [:]
        func total(_ map: [String: Double]) -> Double { map.values.reduce(0, +) }

        var points: [CounterPoint] = []
        for row in rows {
            if let s = row.steps { steps[row.activityType] = s }
            if let c = row.activeCalories { calories[row.activityType] = c }
            let minute = min(Int(((row.ts + offsetSeconds - t0Local) / 60).rounded()), 1440)
            let point = CounterPoint(minute: minute, steps: total(steps), activeCalories: total(calories))
            if let last = points.last, last.minute == minute {
                points[points.count - 1] = point
            } else {
                points.append(point)
            }
        }
        return points
    }

    /// Miroir de `watchSleep` (TS) — nuits stockées dont la fin tombe dans la
    /// plage, phases décodées depuis `wellness_sleep.phases` (JSON écrit par
    /// `storeSleep`), décalées au fuseau d'affichage.
    private func watchSleep(rangeStart: Double, rangeEnd: Double, offsetSeconds: Double) throws -> WatchSleepResult {
        struct Row {
            let date: String
            let startTs: Double
            let endTs: Double
            let sleepS: Double
            let score: Double?
            let phases: String
        }
        var rows: [Row] = []
        try db.run(
            """
            SELECT date, start_ts, end_ts, deep_s + light_s + rem_s, score, phases
            FROM wellness_sleep WHERE end_ts >= ? AND end_ts < ? ORDER BY start_ts ASC
            """,
            [.double(rangeStart - offsetSeconds), .double(rangeEnd - offsetSeconds)]) { r in
            guard let date = r.text(0), let startTs = r.double(1), let endTs = r.double(2),
                  let sleepS = r.double(3), let phases = r.text(5) else { return }
            rows.append(Row(date: date, startTs: startTs, endTs: endTs, sleepS: sleepS, score: r.double(4), phases: phases))
        }

        var byDate: [String: SleepNight] = [:]
        var allSegments: [SleepInterval] = []
        for row in rows {
            let stages = Self.decodePhases(row.phases).map {
                SleepStage(from: $0.from + offsetSeconds, to: $0.to + offsetSeconds, stage: $0.stage)
            }
            let asleep = stages.filter { $0.stage != "awake" }.map { SleepInterval(from: $0.from, to: $0.to) }
            byDate[row.date] = SleepNight(
                segments: asleep,
                main: SleepMain(from: row.startTs + offsetSeconds, to: row.endTs + offsetSeconds, durationS: row.sleepS),
                stages: stages,
                score: row.score)
            allSegments.append(contentsOf: asleep)
        }
        return WatchSleepResult(segments: allSegments, byDate: byDate)
    }

    /// Décode le JSON écrit par `LocalDb.encodePhases` (`storeSleep`) —
    /// réutilise `FitSleepPhase` plutôt qu'un type dédié.
    private static func decodePhases(_ json: String) -> [FitSleepPhase] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { dict in
            guard let from = dict["from"] as? Double, let to = dict["to"] as? Double,
                  let stage = dict["stage"] as? String else { return nil }
            return FitSleepPhase(from: from, to: to, stage: stage)
        }
    }

    /// Miroir de `pivotSeries` (TS) — `activities`/`meals` toujours vides ici
    /// (pas de table `activities`/`food_log` locale en L2, cf. en-tête de
    /// `BodyBattery.swift`).
    func pivotSeries(date: String, start: Double) throws -> [LocalSample] {
        let t0 = Self.dayStartUnixUTC(date)
        let t1 = t0 + 86400
        let offset = Self.localOffsetSeconds(forDate: date)
        let stress = try samplesBetween(metric: "stress", t0Local: t0, t1Local: t1, offsetSeconds: offset)
        guard !stress.isEmpty else { return [] }
        let sleep = try watchSleep(rangeStart: t0 - 12 * 3600, rangeEnd: t1 + 12 * 3600, offsetSeconds: offset)
        var params = BodyBattery.defaultParams
        params.start = start
        let sleepIntervals = sleep.segments.map { BBSleepInterval(from: $0.from, to: $0.to) }
        return BodyBattery.simulatePivot(stress: stress, sleep: sleepIntervals, activities: [], params: params, meals: [])
    }

    private static let maxBodyBatteryChainDays = 400

    /// Miroir de `bodyBatteryStart` (TS) — chaîne le pivot jour après jour
    /// depuis le dernier `body_battery_state` connu (ou depuis le premier
    /// échantillon de stress) jusqu'à `date`, en cache chaque étape. Coûteux
    /// la première fois qu'une date lointaine est demandée (jusqu'à
    /// `maxBodyBatteryChainDays` simulations), gratuit ensuite.
    func bodyBatteryStart(date: String) throws -> Double {
        if let cached = try bodyBatteryStateValue(date: date) { return cached }

        var cursor: String
        var value: Double
        if let previous = try bodyBatteryStatePrevious(before: date) {
            cursor = previous.date
            value = previous.value
        } else {
            guard let firstTs = try minStressTimestamp() else { return BodyBattery.defaultParams.start }
            let offset = Self.localOffsetSeconds(forDate: date)
            cursor = FitWellnessExtractor.isoDate(firstTs + offset)
            if cursor >= date { return BodyBattery.defaultParams.start }
            value = BodyBattery.defaultParams.start
        }

        try setBodyBatteryState(date: cursor, value: value)
        var iterations = 0
        while cursor < date && iterations < Self.maxBodyBatteryChainDays {
            let series = try pivotSeries(date: cursor, start: value)
            if let last = series.last { value = last.value }
            cursor = Self.shiftDate(cursor, byDays: 1)
            try setBodyBatteryState(date: cursor, value: value)
            iterations += 1
        }
        return value
    }

    private func bodyBatteryStateValue(date: String) throws -> Double? {
        var value: Double?
        try db.run("SELECT start_value FROM body_battery_state WHERE date = ?", [.text(date)]) { r in
            value = r.double(0)
        }
        return value
    }

    private func bodyBatteryStatePrevious(before date: String) throws -> (date: String, value: Double)? {
        var result: (date: String, value: Double)?
        try db.run(
            "SELECT date, start_value FROM body_battery_state WHERE date < ? ORDER BY date DESC LIMIT 1",
            [.text(date)]) { r in
            if let d = r.text(0), let v = r.double(1) { result = (d, v) }
        }
        return result
    }

    private func minStressTimestamp() throws -> Double? {
        var ts: Double?
        try db.run("SELECT MIN(ts) FROM wellness_samples WHERE metric = 'stress'") { r in
            ts = r.double(0)
        }
        return ts
    }

    private func setBodyBatteryState(date: String, value: Double) throws {
        try db.run(
            """
            INSERT INTO body_battery_state (date, start_value) VALUES (?, ?)
            ON CONFLICT(date) DO UPDATE SET start_value = excluded.start_value
            """,
            [.text(date), .double(value)])
    }

    private static func shiftDate(_ date: String, byDays days: Int) -> String {
        FitWellnessExtractor.isoDate(dayStartUnixUTC(date) + Double(days) * 86400)
    }

    // MARK: - Poids (incrément L5, miroir `weight.controller.ts` `WeightController`)
    //
    // `weight_log`/`settings` — schéma EXACT de `db.service.ts` (`SCHEMA`,
    // lignes ~63-66 et ~82-86). `RealLocalPulseBackend` rejoue `list()`/`add()`/
    // `remove()` en s'appuyant sur `weightList(days:)` (assemble toute la
    // réponse `GET api/weight`, même esprit que `dayDetail`) et les méthodes
    // d'écriture ci-dessous.

    struct WeightRow {
        let date: String
        let kg: Double
    }

    struct WeightSeriesRow {
        let date: String
        let kg: Double
        let avg: Double
    }

    struct WeightList {
        let current: Double?
        let currentDate: String?
        let deltaKg: Double?
        let minKg: Double?
        let maxKg: Double?
        let entries: Int
        let rangeDays: Int
        let series: [WeightSeriesRow]
    }

    /// Fenêtre de moyenne glissante de `series[].avg` — miroir de
    /// `AVG_WINDOW_DAYS` (TS).
    private static let weightAvgWindowDays: Double = 7

    /// Miroir de `WeightController.list` (TS) — `days` déjà bordé (7...3660)
    /// par l'appelant (`RealLocalPulseBackend`, même bornage que le serveur).
    /// `since` reproduit `new Date(Date.now() - days * 86400000)
    /// .toISOString().slice(0, 10)` : coupure UTC, PAS le calendrier local
    /// (divergent volontairement de `todayDateKey` côté `RealLocalPulseBackend`,
    /// qui lui mime `todayKey()`/`dateKey()`, calendaires locaux — même
    /// divergence de convention que le serveur TS entre les deux fonctions).
    func weightList(days: Int) throws -> WeightList {
        let since = FitWellnessExtractor.isoDate(Date().timeIntervalSince1970 - Double(days) * 86400)

        var rows: [WeightRow] = []
        try db.run(
            "SELECT date, kg FROM weight_log WHERE date >= ? ORDER BY date ASC",
            [.text(since)]) { r in
            guard let date = r.text(0), let kg = r.double(1) else { return }
            rows.append(WeightRow(date: date, kg: kg))
        }

        var latest: WeightRow?
        try db.run("SELECT date, kg FROM weight_log ORDER BY date DESC LIMIT 1") { r in
            guard let date = r.text(0), let kg = r.double(1) else { return }
            latest = WeightRow(date: date, kg: kg)
        }

        // Miroir de la boucle `series.map((row, i) => ...)` (TS) : moyenne
        // glissante sur `AVG_WINDOW_DAYS` jours, en repartant vers le passé
        // depuis chaque ligne (les lignes sont triées ASC, donc `j` décroît).
        var series: [WeightSeriesRow] = []
        for i in rows.indices {
            let from = Self.dayStartUnixUTC(rows[i].date) - Self.weightAvgWindowDays * 86400
            var sum = 0.0
            var n = 0
            var j = i
            while j >= 0 {
                if Self.dayStartUnixUTC(rows[j].date) < from { break }
                sum += rows[j].kg
                n += 1
                j -= 1
            }
            let avg = n > 0 ? (sum / Double(n) * 10).rounded() / 10 : rows[i].kg
            series.append(WeightSeriesRow(date: rows[i].date, kg: rows[i].kg, avg: avg))
        }

        let kgs = rows.map { $0.kg }
        let deltaKg: Double? = rows.count > 1
            ? ((rows[rows.count - 1].kg - rows[0].kg) * 10).rounded() / 10
            : nil

        return WeightList(
            current: latest?.kg, currentDate: latest?.date, deltaKg: deltaKg,
            minKg: kgs.min(), maxKg: kgs.max(), entries: rows.count, rangeDays: days, series: series)
    }

    /// Miroir de l'`INSERT ... ON CONFLICT(date) DO UPDATE SET kg = excluded.kg`
    /// de `WeightController.add`.
    func upsertWeight(date: String, kg: Double) throws {
        try db.run(
            """
            INSERT INTO weight_log (date, kg) VALUES (?, ?)
            ON CONFLICT(date) DO UPDATE SET kg = excluded.kg
            """,
            [.text(date), .double(kg)])
    }

    /// Miroir de `WeightController.remove`.
    func deleteWeight(date: String) throws {
        try db.run("DELETE FROM weight_log WHERE date = ?", [.text(date)])
    }

    private func latestWeightRow() throws -> WeightRow? {
        var latest: WeightRow?
        try db.run("SELECT date, kg FROM weight_log ORDER BY date DESC LIMIT 1") { r in
            guard let date = r.text(0), let kg = r.double(1) else { return }
            latest = WeightRow(date: date, kg: kg)
        }
        return latest
    }

    /// Miroir de `WeightController.syncProfile` (privée côté TS, appelée par
    /// `add`/`remove`) : republie `settings.weightKg` sur la dernière pesée
    /// connue — ne touche à rien s'il n'y a plus aucune pesée (`if (!latest)
    /// return;`, la clé reste alors périmée, comme côté serveur). Ne pousse
    /// PAS vers la montre (`weightPush.queue`) : cette part est hors backend
    /// local, l'app pousse déjà directement via `BLEManager.requestWatchWeightWrite`
    /// (cf. `HealthViewModel.saveWeight`).
    func syncWeightProfile() throws {
        guard let latest = try latestWeightRow() else { return }
        try setSetting(key: "weightKg", value: Self.jsNumberString(latest.kg))
    }

    /// `String(latest.kg)` (TS) — un nombre entier s'affiche sans `.0`
    /// (`String(70)` → `"70"`), un nombre décimal garde sa décimale
    /// (`String(70.5)` → `"70.5"`) ; suffisant pour la plage de poids en jeu
    /// ici (arrondis à 0,1 kg par `add`/`remove`, jamais de notation
    /// scientifique).
    private static func jsNumberString(_ value: Double) -> String {
        if value == value.rounded() { return String(Int64(value)) }
        return String(value)
    }

    func settingValue(key: String) throws -> String? {
        var value: String?
        try db.run("SELECT value FROM settings WHERE key = ?", [.text(key)]) { r in
            value = r.text(0)
        }
        return value
    }

    /// Miroir de `INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)`
    /// (TS, `WeightController.syncProfile`/`WeightPushService.save`).
    func setSetting(key: String, value: String) throws {
        try db.run(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
            [.text(key), .text(value)])
    }

    // MARK: - Nutrition (incrément L5-Nutrition, miroir `nutrition.controller.ts`)
    //
    // `foods`/`food_log` — schéma EXACT de `db.service.ts` (`SCHEMA`, lignes
    // ~88-118, y compris `idx_food_log_date`). Semée au premier ouverture
    // (table `foods` vide) depuis `Self.seedFoods`, port intégral de
    // `nutrition/seed-foods.ts` (~95 aliments). Divergence assumée vs serveur :
    // le serveur reseed en fonction d'une version (`SEED_VERSION`/
    // `foodsSeedVersion`, pour ajouter de nouveaux aliments à un catalogue déjà
    // peuplé sans dupliquer) — non reproduit ici, la sédition locale se fait
    // une seule fois (base vide) ; suffisant pour cet incrément, à revisiter
    // si `seed-foods.ts` gagne des entrées après la première synchro d'un
    // utilisateur donné.

    private struct SeedFood {
        let name: String
        let kcal: Double
        let protein: Double
        let carbs: Double
        let fiber: Double
        let fat: Double
        let unitLabel: String?
        let unitGrams: Double?
    }

    private func seedFoodsIfNeeded() throws {
        var count = 0
        try db.run("SELECT COUNT(*) FROM foods") { r in count = Int(r.double(0) ?? 0) }
        guard count == 0 else { return }
        try db.transaction {
            for f in Self.seedFoods {
                try db.run(
                    """
                    INSERT INTO foods (name, kcal, protein, carbs, fiber, fat, unit_label, unit_grams)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(f.name), .double(f.kcal), .double(f.protein), .double(f.carbs), .double(f.fiber), .double(f.fat),
                     sqliteOptionalText(f.unitLabel), sqliteOptional(f.unitGrams)])
            }
        }
    }

    // Port intégral de `SEED_FOODS` (`nutrition/seed-foods.ts`).
    private static let seedFoods: [SeedFood] = [
        SeedFood(name: "Skyr nature", kcal: 63, protein: 11, carbs: 4, fiber: 0, fat: 0.2, unitLabel: "pot", unitGrams: 150),
        SeedFood(name: "Fromage blanc 0%", kcal: 47, protein: 8, carbs: 4, fiber: 0, fat: 0.2, unitLabel: "pot", unitGrams: 100),
        SeedFood(name: "Yaourt grec nature", kcal: 97, protein: 9, carbs: 4, fiber: 0, fat: 5, unitLabel: "pot", unitGrams: 150),
        SeedFood(name: "Yaourt nature", kcal: 61, protein: 3.5, carbs: 5, fiber: 0, fat: 3.3, unitLabel: "pot", unitGrams: 125),
        SeedFood(name: "Cottage cheese", kcal: 98, protein: 11, carbs: 3.4, fiber: 0, fat: 4.3, unitLabel: "pot", unitGrams: 100),
        SeedFood(name: "Blanc d'œuf", kcal: 52, protein: 11, carbs: 0.7, fiber: 0, fat: 0.2, unitLabel: "blanc", unitGrams: 33),
        SeedFood(name: "Œuf entier", kcal: 143, protein: 13, carbs: 1.1, fiber: 0, fat: 10, unitLabel: "œuf", unitGrams: 55),
        SeedFood(name: "Lait demi-écrémé", kcal: 47, protein: 3.3, carbs: 4.8, fiber: 0, fat: 1.6, unitLabel: "verre", unitGrams: 200),
        SeedFood(name: "Mozzarella", kcal: 280, protein: 22, carbs: 2.2, fiber: 0, fat: 21, unitLabel: "boule", unitGrams: 125),
        SeedFood(name: "Parmesan", kcal: 392, protein: 36, carbs: 3.2, fiber: 0, fat: 25, unitLabel: "c. à soupe", unitGrams: 10),
        SeedFood(name: "Emmental", kcal: 380, protein: 28, carbs: 0.5, fiber: 0, fat: 29, unitLabel: "tranche", unitGrams: 20),
        SeedFood(name: "Whey (poudre)", kcal: 400, protein: 80, carbs: 8, fiber: 0, fat: 6, unitLabel: "dose", unitGrams: 30),
        SeedFood(name: "Blanc de poulet", kcal: 165, protein: 31, carbs: 0, fiber: 0, fat: 3.6, unitLabel: "filet", unitGrams: 150),
        SeedFood(name: "Escalope de dinde", kcal: 135, protein: 29, carbs: 0, fiber: 0, fat: 1.5, unitLabel: "escalope", unitGrams: 120),
        SeedFood(name: "Steak haché 5%", kcal: 137, protein: 21, carbs: 0, fiber: 0, fat: 5, unitLabel: "steak", unitGrams: 125),
        SeedFood(name: "Jambon blanc", kcal: 107, protein: 18, carbs: 1, fiber: 0, fat: 3, unitLabel: "tranche", unitGrams: 40),
        SeedFood(name: "Thon au naturel", kcal: 116, protein: 26, carbs: 0, fiber: 0, fat: 1, unitLabel: "boîte", unitGrams: 112),
        SeedFood(name: "Saumon", kcal: 208, protein: 20, carbs: 0, fiber: 0, fat: 13, unitLabel: "pavé", unitGrams: 130),
        SeedFood(name: "Cabillaud", kcal: 82, protein: 18, carbs: 0, fiber: 0, fat: 0.7, unitLabel: "filet", unitGrams: 130),
        SeedFood(name: "Crevettes", kcal: 99, protein: 24, carbs: 0.2, fiber: 0, fat: 0.3, unitLabel: "crevette", unitGrams: 8),
        SeedFood(name: "Sardines", kcal: 208, protein: 25, carbs: 0, fiber: 0, fat: 11, unitLabel: "boîte", unitGrams: 100),
        SeedFood(name: "Tofu", kcal: 144, protein: 16, carbs: 3, fiber: 2, fat: 8, unitLabel: "portion", unitGrams: 100),
        SeedFood(name: "Lentilles cuites", kcal: 116, protein: 9, carbs: 20, fiber: 8, fat: 0.4, unitLabel: "portion", unitGrams: 150),
        SeedFood(name: "Pois chiches cuits", kcal: 164, protein: 9, carbs: 27, fiber: 8, fat: 2.6, unitLabel: "portion", unitGrams: 150),
        SeedFood(name: "Haricots rouges cuits", kcal: 127, protein: 9, carbs: 22, fiber: 6, fat: 0.5, unitLabel: "portion", unitGrams: 150),
        SeedFood(name: "Riz blanc cuit", kcal: 130, protein: 2.7, carbs: 28, fiber: 0.4, fat: 0.3, unitLabel: "portion", unitGrams: 150),
        SeedFood(name: "Riz complet cuit", kcal: 111, protein: 2.6, carbs: 23, fiber: 1.8, fat: 0.9, unitLabel: "portion", unitGrams: 150),
        SeedFood(name: "Pâtes cuites", kcal: 158, protein: 6, carbs: 31, fiber: 1.8, fat: 0.9, unitLabel: "portion", unitGrams: 180),
        SeedFood(name: "Quinoa cuit", kcal: 120, protein: 4.4, carbs: 21, fiber: 2.8, fat: 1.9, unitLabel: "portion", unitGrams: 150),
        SeedFood(name: "Flocons d'avoine", kcal: 389, protein: 17, carbs: 66, fiber: 10, fat: 7, unitLabel: "portion", unitGrams: 40),
        SeedFood(name: "Pain complet", kcal: 247, protein: 13, carbs: 41, fiber: 7, fat: 3.4, unitLabel: "tranche", unitGrams: 35),
        SeedFood(name: "Pain blanc", kcal: 265, protein: 9, carbs: 49, fiber: 2.7, fat: 3.2, unitLabel: "tranche", unitGrams: 30),
        SeedFood(name: "Patate douce cuite", kcal: 90, protein: 2, carbs: 21, fiber: 3.3, fat: 0.1, unitLabel: "pièce", unitGrams: 150),
        SeedFood(name: "Pomme de terre cuite", kcal: 87, protein: 2, carbs: 20, fiber: 1.8, fat: 0.1, unitLabel: "pièce", unitGrams: 150),
        SeedFood(name: "Banane", kcal: 89, protein: 1.1, carbs: 23, fiber: 2.6, fat: 0.3, unitLabel: "pièce", unitGrams: 120),
        SeedFood(name: "Pomme", kcal: 52, protein: 0.3, carbs: 14, fiber: 2.4, fat: 0.2, unitLabel: "pièce", unitGrams: 180),
        SeedFood(name: "Orange", kcal: 47, protein: 0.9, carbs: 12, fiber: 2.4, fat: 0.1, unitLabel: "pièce", unitGrams: 150),
        SeedFood(name: "Fraises", kcal: 32, protein: 0.7, carbs: 8, fiber: 2, fat: 0.3, unitLabel: "fraise", unitGrams: 12),
        SeedFood(name: "Myrtilles", kcal: 57, protein: 0.7, carbs: 14, fiber: 2.4, fat: 0.3, unitLabel: "poignée", unitGrams: 25),
        SeedFood(name: "Avocat", kcal: 160, protein: 2, carbs: 9, fiber: 7, fat: 15, unitLabel: "pièce", unitGrams: 150),
        SeedFood(name: "Brocoli cuit", kcal: 35, protein: 2.4, carbs: 7, fiber: 3.3, fat: 0.4, unitLabel: "portion", unitGrams: 150),
        SeedFood(name: "Épinards", kcal: 23, protein: 2.9, carbs: 3.6, fiber: 2.2, fat: 0.4, unitLabel: "poignée", unitGrams: 30),
        SeedFood(name: "Carotte", kcal: 41, protein: 0.9, carbs: 10, fiber: 2.8, fat: 0.2, unitLabel: "pièce", unitGrams: 80),
        SeedFood(name: "Tomate", kcal: 18, protein: 0.9, carbs: 3.9, fiber: 1.2, fat: 0.2, unitLabel: "pièce", unitGrams: 120),
        SeedFood(name: "Amandes", kcal: 579, protein: 21, carbs: 22, fiber: 12, fat: 50, unitLabel: "poignée", unitGrams: 25),
        SeedFood(name: "Noix", kcal: 654, protein: 15, carbs: 14, fiber: 7, fat: 65, unitLabel: "poignée", unitGrams: 25),
        SeedFood(name: "Cacahuètes", kcal: 567, protein: 26, carbs: 16, fiber: 8, fat: 49, unitLabel: "poignée", unitGrams: 30),
        SeedFood(name: "Beurre de cacahuète", kcal: 588, protein: 25, carbs: 20, fiber: 6, fat: 50, unitLabel: "c. à soupe", unitGrams: 16),
        SeedFood(name: "Huile d'olive", kcal: 884, protein: 0, carbs: 0, fiber: 0, fat: 100, unitLabel: "c. à soupe", unitGrams: 10),
        SeedFood(name: "Chocolat noir 70%", kcal: 546, protein: 8, carbs: 46, fiber: 11, fat: 31, unitLabel: "carré", unitGrams: 10),
        SeedFood(name: "Miel", kcal: 304, protein: 0.3, carbs: 82, fiber: 0.2, fat: 0, unitLabel: "c. à café", unitGrams: 7),
        SeedFood(name: "Barre protéinée", kcal: 350, protein: 33, carbs: 35, fiber: 5, fat: 10, unitLabel: "barre", unitGrams: 60),
        SeedFood(name: "Compote de pomme sans sucre", kcal: 42, protein: 0.2, carbs: 10, fiber: 1, fat: 0.1, unitLabel: "gourde", unitGrams: 90),
        SeedFood(name: "Galette de riz", kcal: 387, protein: 8, carbs: 82, fiber: 4, fat: 3, unitLabel: "galette", unitGrams: 9),
        SeedFood(name: "Houmous", kcal: 177, protein: 8, carbs: 20, fiber: 6, fat: 8, unitLabel: "c. à soupe", unitGrams: 30),
        SeedFood(name: "Edamame", kcal: 121, protein: 12, carbs: 9, fiber: 5, fat: 5, unitLabel: "portion", unitGrams: 80),
        SeedFood(name: "Kiwi", kcal: 61, protein: 1.1, carbs: 15, fiber: 3, fat: 0.5, unitLabel: "pièce", unitGrams: 75),
        SeedFood(name: "Poire", kcal: 57, protein: 0.4, carbs: 15, fiber: 3.1, fat: 0.1, unitLabel: "pièce", unitGrams: 170),
        SeedFood(name: "Clémentine", kcal: 47, protein: 0.9, carbs: 12, fiber: 1.7, fat: 0.2, unitLabel: "pièce", unitGrams: 75),
        SeedFood(name: "Pêche", kcal: 39, protein: 0.9, carbs: 10, fiber: 1.5, fat: 0.3, unitLabel: "pièce", unitGrams: 150),
        SeedFood(name: "Abricot", kcal: 48, protein: 1.4, carbs: 11, fiber: 2, fat: 0.4, unitLabel: "pièce", unitGrams: 35),
        SeedFood(name: "Prune", kcal: 46, protein: 0.7, carbs: 11, fiber: 1.4, fat: 0.3, unitLabel: "pièce", unitGrams: 65),
        SeedFood(name: "Mangue", kcal: 60, protein: 0.8, carbs: 15, fiber: 1.6, fat: 0.4, unitLabel: "pièce", unitGrams: 200),
        SeedFood(name: "Ananas", kcal: 50, protein: 0.5, carbs: 13, fiber: 1.4, fat: 0.1, unitLabel: "tranche", unitGrams: 80),
        SeedFood(name: "Pastèque", kcal: 30, protein: 0.6, carbs: 8, fiber: 0.4, fat: 0.2, unitLabel: "tranche", unitGrams: 200),
        SeedFood(name: "Melon", kcal: 34, protein: 0.8, carbs: 8, fiber: 0.9, fat: 0.2, unitLabel: "tranche", unitGrams: 150),
        SeedFood(name: "Raisin", kcal: 69, protein: 0.7, carbs: 18, fiber: 0.9, fat: 0.2, unitLabel: "poignée", unitGrams: 80),
        SeedFood(name: "Framboises", kcal: 52, protein: 1.2, carbs: 12, fiber: 6.5, fat: 0.7, unitLabel: "poignée", unitGrams: 30),
        SeedFood(name: "Datte", kcal: 282, protein: 2.5, carbs: 75, fiber: 8, fat: 0.4, unitLabel: "pièce", unitGrams: 8),
        SeedFood(name: "Concombre", kcal: 15, protein: 0.7, carbs: 3.6, fiber: 0.5, fat: 0.1, unitLabel: "pièce", unitGrams: 300),
        SeedFood(name: "Courgette", kcal: 17, protein: 1.2, carbs: 3.1, fiber: 1, fat: 0.3, unitLabel: "pièce", unitGrams: 200),
        SeedFood(name: "Poivron", kcal: 26, protein: 1, carbs: 6, fiber: 2.1, fat: 0.3, unitLabel: "pièce", unitGrams: 150),
        SeedFood(name: "Aubergine", kcal: 25, protein: 1, carbs: 6, fiber: 3, fat: 0.2, unitLabel: "pièce", unitGrams: 250),
        SeedFood(name: "Oignon", kcal: 40, protein: 1.1, carbs: 9, fiber: 1.7, fat: 0.1, unitLabel: "pièce", unitGrams: 110),
        SeedFood(name: "Champignon de Paris", kcal: 22, protein: 3.1, carbs: 3.3, fiber: 1, fat: 0.3, unitLabel: "pièce", unitGrams: 18),
        SeedFood(name: "Salade verte", kcal: 15, protein: 1.4, carbs: 2.9, fiber: 1.3, fat: 0.2, unitLabel: "poignée", unitGrams: 30),
        SeedFood(name: "Haricots verts cuits", kcal: 35, protein: 1.9, carbs: 7, fiber: 3.4, fat: 0.3, unitLabel: "portion", unitGrams: 150),
        SeedFood(name: "Chou-fleur cuit", kcal: 25, protein: 1.9, carbs: 5, fiber: 2.3, fat: 0.3, unitLabel: "portion", unitGrams: 150),
        SeedFood(name: "Petits pois cuits", kcal: 84, protein: 5.4, carbs: 16, fiber: 5.5, fat: 0.2, unitLabel: "portion", unitGrams: 100),
        SeedFood(name: "Betterave cuite", kcal: 44, protein: 1.6, carbs: 10, fiber: 2, fat: 0.2, unitLabel: "pièce", unitGrams: 80),
        SeedFood(name: "Noisettes", kcal: 628, protein: 15, carbs: 17, fiber: 10, fat: 61, unitLabel: "poignée", unitGrams: 25),
        SeedFood(name: "Pistaches", kcal: 560, protein: 20, carbs: 28, fiber: 10, fat: 45, unitLabel: "poignée", unitGrams: 25),
    ]

    // MARK: - Nutrition — bibliothèque `foods`

    struct FoodRow {
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
    }

    private static let foodColumns = "id, barcode, name, kcal, protein, carbs, fiber, fat, unit_label, unit_grams"

    private static func foodRow(from r: SQLiteRow) -> FoodRow {
        FoodRow(
            id: Int(r.double(0) ?? 0), barcode: r.text(1), name: r.text(2) ?? "",
            kcal: r.double(3), protein: r.double(4), carbs: r.double(5), fiber: r.double(6), fat: r.double(7),
            unitLabel: r.text(8), unitGrams: r.double(9))
    }

    /// Miroir de `NutritionController.foods` — `LIKE %terme%`, 20 résultats
    /// max, triés par nom.
    func searchFoods(query: String) throws -> [FoodRow] {
        var out: [FoodRow] = []
        try db.run(
            "SELECT \(Self.foodColumns) FROM foods WHERE name LIKE ? ORDER BY name ASC LIMIT 20",
            [.text("%\(query)%")]) { r in out.append(Self.foodRow(from: r)) }
        return out
    }

    func food(id: Int) throws -> FoodRow? {
        var result: FoodRow?
        try db.run("SELECT \(Self.foodColumns) FROM foods WHERE id = ?", [.int(id)]) { r in result = Self.foodRow(from: r) }
        return result
    }

    func food(barcode: String) throws -> FoodRow? {
        var result: FoodRow?
        try db.run("SELECT \(Self.foodColumns) FROM foods WHERE barcode = ?", [.text(barcode)]) { r in result = Self.foodRow(from: r) }
        return result
    }

    /// Miroir de `NutritionController.createFood`.
    @discardableResult
    func insertFood(
        barcode: String?, name: String, kcal: Double?, protein: Double?, carbs: Double?, fiber: Double?, fat: Double?,
        unitLabel: String?, unitGrams: Double?
    ) throws -> FoodRow {
        try db.run(
            """
            INSERT INTO foods (barcode, name, kcal, protein, carbs, fiber, fat, unit_label, unit_grams)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [sqliteOptionalText(barcode), .text(name), sqliteOptional(kcal), sqliteOptional(protein), sqliteOptional(carbs),
             sqliteOptional(fiber), sqliteOptional(fat), sqliteOptionalText(unitLabel), sqliteOptional(unitGrams)])
        var id = 0
        try db.run("SELECT last_insert_rowid()") { r in id = Int(r.double(0) ?? 0) }
        guard let row = try food(id: id) else {
            // Ne devrait jamais arriver (on vient d'insérer la ligne) — filet
            // de sécurité plutôt qu'un force-unwrap.
            throw LocalNutritionValidationError(reason: "Échec d'insertion d'aliment")
        }
        return row
    }

    /// Miroir de `NutritionController.updateFood`.
    func updateFood(
        id: Int, barcode: String?, name: String, kcal: Double?, protein: Double?, carbs: Double?, fiber: Double?, fat: Double?,
        unitLabel: String?, unitGrams: Double?
    ) throws -> FoodRow? {
        try db.run(
            """
            UPDATE foods SET name = ?, barcode = ?, kcal = ?, protein = ?, carbs = ?, fiber = ?,
                             fat = ?, unit_label = ?, unit_grams = ?
            WHERE id = ?
            """,
            [.text(name), sqliteOptionalText(barcode), sqliteOptional(kcal), sqliteOptional(protein), sqliteOptional(carbs),
             sqliteOptional(fiber), sqliteOptional(fat), sqliteOptionalText(unitLabel), sqliteOptional(unitGrams), .int(id)])
        return try food(id: id)
    }

    // MARK: - Nutrition — journal `food_log`

    struct FoodLogRow {
        let id: Int
        let date: String
        let foodId: Int?
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

    private static func foodLogRow(from r: SQLiteRow) -> FoodLogRow {
        FoodLogRow(
            id: Int(r.double(0) ?? 0), date: r.text(1) ?? "", foodId: r.double(2).map(Int.init),
            name: r.text(3) ?? "", grams: r.double(4) ?? 0,
            kcal: r.double(5), protein: r.double(6), carbs: r.double(7), fiber: r.double(8), fat: r.double(9),
            unitLabel: r.text(10), unitQty: r.double(11), ts: r.double(12).map(Int.init))
    }

    /// Miroir de la requête `food_log` de `NutritionController.day`
    /// (`ORDER BY COALESCE(ts, 0) ASC, id ASC`).
    func foodLog(date: String) throws -> [FoodLogRow] {
        var out: [FoodLogRow] = []
        try db.run(
            """
            SELECT id, date, food_id, name, grams, kcal, protein, carbs, fiber, fat, unit_label, unit_qty, ts
            FROM food_log WHERE date = ? ORDER BY COALESCE(ts, 0) ASC, id ASC
            """,
            [.text(date)]) { r in out.append(Self.foodLogRow(from: r)) }
        return out
    }

    /// Miroir de l'`INSERT` d'`addLog` (TS). Renvoie l'id auto-incrémenté.
    @discardableResult
    func insertLog(
        date: String, foodId: Int?, name: String, grams: Double, kcal: Double?, protein: Double?, carbs: Double?,
        fiber: Double?, fat: Double?, unitLabel: String?, unitQty: Double?, ts: Int
    ) throws -> Int {
        try db.run(
            """
            INSERT INTO food_log (date, food_id, name, grams, kcal, protein, carbs, fiber, fat, unit_label, unit_qty, ts)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(date), sqliteOptional(foodId.map(Double.init)), .text(name), .double(grams),
             sqliteOptional(kcal), sqliteOptional(protein), sqliteOptional(carbs), sqliteOptional(fiber), sqliteOptional(fat),
             sqliteOptionalText(unitLabel), sqliteOptional(unitQty), .int(ts)])
        var id = 0
        try db.run("SELECT last_insert_rowid()") { r in id = Int(r.double(0) ?? 0) }
        return id
    }

    /// Miroir de l'`UPDATE` d'`updateLog` (TS) — ne touche pas `date`/`food_id`
    /// (le serveur non plus, cf. `NutritionController.updateLog`).
    func updateLog(
        id: Int, name: String, grams: Double, kcal: Double?, protein: Double?, carbs: Double?, fiber: Double?, fat: Double?,
        unitLabel: String?, unitQty: Double?, ts: Int
    ) throws {
        try db.run(
            """
            UPDATE food_log SET name = ?, grams = ?, kcal = ?, protein = ?, carbs = ?, fiber = ?,
                                 fat = ?, unit_label = ?, unit_qty = ?, ts = ?
            WHERE id = ?
            """,
            [.text(name), .double(grams), sqliteOptional(kcal), sqliteOptional(protein), sqliteOptional(carbs),
             sqliteOptional(fiber), sqliteOptional(fat), sqliteOptionalText(unitLabel), sqliteOptional(unitQty), .int(ts), .int(id)])
    }

    func deleteLog(id: Int) throws {
        try db.run("DELETE FROM food_log WHERE id = ?", [.int(id)])
    }

    // MARK: - Nutrition — aliments fréquents

    struct FrequentFoodRow {
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

    /// Miroir de `NutritionController.frequent` — regroupe `food_log` (grams
    /// > 0) par `foodId` (ou nom en minuscules si pas de `foodId`), calcule
    /// médiane de grammes/unités et repli pour-100 g (dernière valeur connue
    /// dans le groupe), trie par nombre d'usages puis dernière utilisation.
    func frequentFoods(limit: Int) throws -> [FrequentFoodRow] {
        struct Row {
            let name: String
            let foodId: Int?
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
        var rows: [Row] = []
        try db.run(
            """
            SELECT name, food_id, grams, kcal, protein, carbs, fiber, fat, unit_label, unit_qty, ts
            FROM food_log WHERE grams > 0 ORDER BY ts DESC
            """) { r in
            rows.append(Row(
                name: r.text(0) ?? "", foodId: r.double(1).map(Int.init), grams: r.double(2) ?? 0,
                kcal: r.double(3), protein: r.double(4), carbs: r.double(5), fiber: r.double(6), fat: r.double(7),
                unitLabel: r.text(8), unitQty: r.double(9), ts: r.double(10).map(Int.init)))
        }

        // Regroupement en préservant l'ordre de PREMIÈRE apparition (miroir de
        // l'itération d'un `Map` JS, insertion-order) — nécessaire pour un tri
        // stable identique en cas d'égalité stricte (uses, lastTs).
        var order: [String] = []
        var groups: [String: [Row]] = [:]
        for row in rows {
            let key = row.foodId != nil ? "id:\(row.foodId!)" : "name:\(row.name.lowercased())"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row)
        }

        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let mid = sorted.count / 2
            if sorted.count % 2 == 1 { return sorted[mid] }
            return ((sorted[mid - 1] + sorted[mid]) / 2).rounded()
        }

        func per100(_ entries: [Row], _ pick: (Row) -> Double?) -> Double? {
            for e in entries {
                if let v = pick(e), e.grams > 0 { return (v / e.grams * 100 * 10).rounded() / 10 }
            }
            return nil
        }

        var out: [FrequentFoodRow] = []
        for key in order {
            let entries = groups[key] ?? []
            guard let latest = entries.first else { continue }
            let food: FoodRow?
            if let fid = latest.foodId { food = try self.food(id: fid) } else { food = nil }
            let logged = entries.filter { ($0.unitQty ?? 0) > 0 }
            let fromLog = logged.first
            let unitLabel = food?.unitLabel ?? fromLog?.unitLabel
            let unitGrams: Double?
            if let g = food?.unitGrams {
                unitGrams = g
            } else if let fromLog, let qty = fromLog.unitQty, qty > 0 {
                unitGrams = (fromLog.grams / qty * 10).rounded() / 10
            } else {
                unitGrams = nil
            }
            out.append(FrequentFoodRow(
                foodId: latest.foodId, name: latest.name, uses: entries.count,
                grams: median(entries.map { $0.grams }),
                units: logged.isEmpty ? nil : median(logged.map { $0.unitQty! }),
                unitLabel: unitLabel, unitGrams: unitGrams, lastTs: latest.ts,
                kcal: food?.kcal ?? per100(entries) { $0.kcal },
                protein: food?.protein ?? per100(entries) { $0.protein },
                carbs: food?.carbs ?? per100(entries) { $0.carbs },
                fiber: food?.fiber ?? per100(entries) { $0.fiber },
                fat: food?.fat ?? per100(entries) { $0.fat }))
        }
        out.sort { a, b in
            if a.uses != b.uses { return a.uses > b.uses }
            return (a.lastTs ?? 0) > (b.lastTs ?? 0)
        }
        return Array(out.prefix(limit))
    }

    // MARK: - Nutrition — cibles (incrément L5-Nutrition-analytics, miroir des
    // aides privées de `NutritionController` — `sessionsOn`/`watchOn`/
    // `weightOn`/`intake`/`suggestions`/`timing`). Lecture seule ; le calcul
    // vit dans `Local/NutritionTarget.swift`/`RealLocalPulseBackend`.

    struct ActivitySessionRow {
        let sport: String?
        let subSport: String?
        let durationS: Double?
        let calories: Double?
    }

    /// Miroir de `sessionsOn` (TS) — activités dont `start_time` tombe dans le
    /// jour calendaire `date` (fuseau de l'appareil, même convention que
    /// `localOffsetSeconds`/`dayStartUnixUTC` déjà utilisés par `dayDetail`/`days`).
    func activitySessions(date: String) throws -> [ActivitySessionRow] {
        let offset = Self.localOffsetSeconds(forDate: date)
        let from = Self.dayStartUnixUTC(date) - offset
        let to = from + 86400
        var out: [ActivitySessionRow] = []
        try db.run(
            """
            SELECT sport, sub_sport, duration_s, calories FROM activities
            WHERE start_time IS NOT NULL
              AND strftime('%s', start_time) >= ?
              AND strftime('%s', start_time) < ?
            ORDER BY start_time ASC
            """,
            [.text(String(Int(from))), .text(String(Int(to)))]) { r in
            out.append(ActivitySessionRow(sport: r.text(0), subSport: r.text(1), durationS: r.double(2), calories: r.double(3)))
        }
        return out
    }

    struct WatchDayRow {
        let restingKcal: Double?
        let activeKcal: Double?
    }

    /// Miroir de `watchOn` (TS) — `bmr_kcal` du jour + somme des
    /// `active_calories` de `wellness_counters` pour ce même jour.
    func watchDay(date: String) throws -> WatchDayRow {
        var restingKcal: Double?
        try db.run("SELECT bmr_kcal FROM wellness_days WHERE date = ?", [.text(date)]) { r in restingKcal = r.double(0) }
        var activeKcal: Double?
        try db.run("SELECT SUM(active_calories) FROM wellness_counters WHERE date = ?", [.text(date)]) { r in activeKcal = r.double(0) }
        return WatchDayRow(restingKcal: restingKcal, activeKcal: activeKcal)
    }

    /// Miroir de la partie SQL de `weightOn` (TS) — le repli sur
    /// `settings.weightKg` reste à la charge de l'appelant
    /// (`RealLocalPulseBackend.profileOn`, comme `weightOn` TS retombe sur
    /// `this.readWeight()`).
    func weightOn(date: String) throws -> Double? {
        var kg: Double?
        try db.run("SELECT kg FROM weight_log WHERE date <= ? ORDER BY date DESC LIMIT 1", [.text(date)]) { r in kg = r.double(0) }
        return kg
    }

    /// Miroir de la requête `intake` de `NutritionController.getWeekly` (TS).
    func foodLogKcalByDate() throws -> [String: Double] {
        var out: [String: Double] = [:]
        try db.run("SELECT date, SUM(kcal) FROM food_log GROUP BY date") { r in
            guard let date = r.text(0) else { return }
            out[date] = r.double(1) ?? 0
        }
        return out
    }

    /// Miroir du `SELECT ... FROM foods WHERE kcal IS NOT NULL AND kcal > 0`
    /// de `NutritionController.suggestions`.
    func foodsWithPositiveKcal() throws -> [FoodRow] {
        var out: [FoodRow] = []
        try db.run("SELECT \(Self.foodColumns) FROM foods WHERE kcal IS NOT NULL AND kcal > 0") { r in
            out.append(Self.foodRow(from: r))
        }
        return out
    }

    struct LastFoodLogRow {
        let ts: Int
        let kcal: Double?
        let fat: Double?
    }

    /// Miroir de la requête `last` de `NutritionController.timing`.
    func lastFoodLogWithTs(date: String) throws -> LastFoodLogRow? {
        var result: LastFoodLogRow?
        try db.run(
            "SELECT ts, kcal, fat FROM food_log WHERE date = ? AND ts IS NOT NULL ORDER BY ts DESC LIMIT 1",
            [.text(date)]) { r in
            guard let ts = r.double(0) else { return }
            result = LastFoodLogRow(ts: Int(ts), kcal: r.double(1), fat: r.double(2))
        }
        return result
    }

    /// Miroir de la sous-requête `stressRow` de `NutritionController.timing`
    /// (fenêtre `[ts, ts+5400)`) — distincte de `statsAvgStressSince`/
    /// `statsNightAvg` (bornes différentes, sections Dashboard).
    func averageStressBetween(fromTs: Double, toTs: Double) throws -> Double? {
        var value: Double?
        try db.run(
            "SELECT AVG(value) FROM wellness_samples WHERE metric = 'stress' AND ts >= ? AND ts < ?",
            [.double(fromTs), .double(toTs)]) { r in value = r.double(0) }
        return value
    }

    // MARK: - Dashboard / Stats (incrément L4, miroir `stats.controller.ts`)
    //
    // Lecture seule — mêmes requêtes SQL que le contrôleur Nest, sur le MÊME
    // moteur SQLite réel (`libsqlite3`, pas une réimplémentation) : les
    // comparaisons `strftime`/affinité INTEGER-vs-TEXT du serveur se
    // comportent donc IDENTIQUEMENT ici, portées quasi mot pour mot plutôt
    // que réinterprétées. Le calcul (agrégats/corrélations/formatage) vit
    // dans `Local/DashboardStats.swift`, qui appelle ces méthodes puis
    // assemble le JSON — même séparation que `BodyBattery.swift` (logique
    // pure) / `LocalDb` (accès données).

    struct StatsRestingRow { let date: String; let value: Double }

    /// Miroir de `dayRows` (`tabHealth`, TS).
    func statsRestingHrSince(_ sinceDate: String) throws -> [StatsRestingRow] {
        var out: [StatsRestingRow] = []
        try db.run(
            "SELECT date, resting_hr FROM wellness_days WHERE date >= ? AND resting_hr IS NOT NULL ORDER BY date ASC",
            [.text(sinceDate)]) { r in
            guard let date = r.text(0), let value = r.double(1) else { return }
            out.append(StatsRestingRow(date: date, value: value))
        }
        return out
    }

    /// Miroir de `latestNight()` (TS).
    func latestSleepNightDate() throws -> String? {
        var date: String?
        try db.run(
            "SELECT MAX(date) AS date FROM wellness_sleep WHERE duration_s IS NOT NULL AND duration_s > 0") { r in
            date = r.text(0)
        }
        return date
    }

    struct StatsSleepDebtRow {
        let date: String
        let deepS: Double
        let lightS: Double
        let remS: Double
        let awakeS: Double
        let score: Double?
        let startTs: Double?
    }

    /// Miroir de la requête `rows` de `sleepDebt` (TS) — l'appelant fait le
    /// `reverse()` (ordre DESC ici, comme côté serveur).
    func statsSleepDebtRows(since: String, limit: Int) throws -> [StatsSleepDebtRow] {
        var out: [StatsSleepDebtRow] = []
        try db.run(
            """
            SELECT date, deep_s, light_s, rem_s, awake_s, score, start_ts
            FROM wellness_sleep
            WHERE duration_s IS NOT NULL AND duration_s > 0 AND date >= ?
            ORDER BY date DESC LIMIT ?
            """,
            [.text(since), .int(limit)]) { r in
            guard let date = r.text(0), let deepS = r.double(1), let lightS = r.double(2),
                  let remS = r.double(3), let awakeS = r.double(4) else { return }
            out.append(StatsSleepDebtRow(
                date: date, deepS: deepS, lightS: lightS, remS: remS, awakeS: awakeS,
                score: r.double(5), startTs: r.double(6)))
        }
        return out
    }

    struct StatsSleepInsightRow {
        let date: String
        let sleepS: Double
        let deepS: Double
        let lightS: Double
        let remS: Double
        let awakeS: Double
        let startTs: Double
        let endTs: Double
        let phases: String
        let avgStress: Double?
    }

    /// Miroir de la requête `rows` de `sleepInsights` (TS), sous-requête
    /// `avgStress` incluse telle quelle (même moteur SQLite).
    func statsSleepInsightRows(since: String, limit: Int) throws -> [StatsSleepInsightRow] {
        var out: [StatsSleepInsightRow] = []
        try db.run(
            """
            SELECT s.date, s.deep_s + s.light_s + s.rem_s AS sleepS,
                   s.deep_s, s.light_s, s.rem_s, s.awake_s, s.start_ts, s.end_ts, s.phases,
                   (SELECT AVG(value) FROM wellness_samples w
                    WHERE w.metric = 'stress'
                      AND w.ts >= strftime('%s', s.date || ' 00:00:00')
                      AND w.ts < strftime('%s', s.date || ' 00:00:00') + 86400) AS avgStress
            FROM wellness_sleep s
            WHERE s.duration_s > 0 AND s.date >= ?
            ORDER BY s.date DESC LIMIT ?
            """,
            [.text(since), .int(limit)]) { r in
            guard let date = r.text(0), let sleepS = r.double(1), let deepS = r.double(2),
                  let lightS = r.double(3), let remS = r.double(4), let awakeS = r.double(5),
                  let startTs = r.double(6), let endTs = r.double(7), let phases = r.text(8) else { return }
            out.append(StatsSleepInsightRow(
                date: date, sleepS: sleepS, deepS: deepS, lightS: lightS, remS: remS, awakeS: awakeS,
                startTs: startTs, endTs: endTs, phases: phases, avgStress: r.double(9)))
        }
        return out
    }

    /// Échantillons bruts (sans conversion d'offset) entre deux `ts` epoch —
    /// utilisé par `spo2Arousal` (`DashboardStats.swift`), qui travaille en
    /// `startTs`/`endTs` bruts de `wellness_sleep`, pas en repère "jour
    /// affiché" comme `samplesBetween`.
    func statsRawSamplesBetween(metric: String, from: Double, to: Double) throws -> [(ts: Double, value: Double)] {
        var out: [(ts: Double, value: Double)] = []
        try db.run(
            "SELECT ts, value FROM wellness_samples WHERE metric = ? AND ts >= ? AND ts < ? ORDER BY ts ASC",
            [.text(metric), .double(from), .double(to)]) { r in
            guard let ts = r.double(0), let value = r.double(1) else { return }
            out.append((ts, value))
        }
        return out
    }

    struct SleepOptimumNightRow {
        let date: String
        let startTs: Double
        let endTs: Double
        let deepS: Double
        let lightS: Double
        let remS: Double
    }

    /// Fenêtre du MODÈLE de durée idéale (`docs/duree-ideale-sommeil.md` §2) —
    /// 180 dernières nuits, INDÉPENDANTE du `days` de l'endpoint
    /// `sleep-recommendation` (cf. `sleepRecommendationWindowNights`, qui lui
    /// respecte `days`). Le filtre `S ∈ [3, 12] h` (spec §2) se fait côté Swift
    /// (`DashboardStatsBackend.sleepRecommendation`), pas en SQL.
    func sleepOptimumModelNights(limit: Int = 180) throws -> [SleepOptimumNightRow] {
        var out: [SleepOptimumNightRow] = []
        try db.run(
            """
            SELECT date, start_ts, end_ts, deep_s, light_s, rem_s
            FROM wellness_sleep
            WHERE duration_s IS NOT NULL AND duration_s > 0 AND start_ts IS NOT NULL AND end_ts IS NOT NULL
            ORDER BY date DESC LIMIT ?
            """,
            [.int(limit)]) { r in
            guard let date = r.text(0), let s = r.double(1), let e = r.double(2),
                  let deepS = r.double(3), let lightS = r.double(4), let remS = r.double(5) else { return }
            out.append(SleepOptimumNightRow(date: date, startTs: s, endTs: e, deepS: deepS, lightS: lightS, remS: remS))
        }
        return out
    }

    struct SleepRecommendationWindowRow {
        let date: String
        let deepS: Double
        let lightS: Double
        let remS: Double
        let awakeS: Double
        let startTs: Double
        let endTs: Double
    }

    /// Fenêtre de l'ENDPOINT `sleep-recommendation` (`days` query) — miroir
    /// exact de la requête `rows` de `stats.controller.ts`
    /// (`sleepRecommendation`), distincte de la fenêtre du modèle (180 nuits
    /// fixes, `sleepOptimumModelNights`).
    func sleepRecommendationWindowNights(since: String, limit: Int) throws -> [SleepRecommendationWindowRow] {
        var out: [SleepRecommendationWindowRow] = []
        try db.run(
            """
            SELECT date, deep_s, light_s, rem_s, awake_s, start_ts, end_ts
            FROM wellness_sleep
            WHERE duration_s > 0 AND start_ts IS NOT NULL AND end_ts IS NOT NULL AND date >= ?
            ORDER BY date DESC LIMIT ?
            """,
            [.text(since), .int(limit)]) { r in
            guard let date = r.text(0), let deepS = r.double(1), let lightS = r.double(2),
                  let remS = r.double(3), let awakeS = r.double(4), let startTs = r.double(5), let endTs = r.double(6)
            else { return }
            out.append(SleepRecommendationWindowRow(
                date: date, deepS: deepS, lightS: lightS, remS: remS, awakeS: awakeS, startTs: startTs, endTs: endTs))
        }
        return out
    }

    /// Miroir de la requête `rows` de `sleepRegularity` (TS).
    func statsSleepStartEndRows(since: String, limit: Int) throws -> [(startTs: Double, endTs: Double)] {
        var out: [(startTs: Double, endTs: Double)] = []
        try db.run(
            """
            SELECT start_ts, end_ts FROM wellness_sleep
            WHERE start_ts IS NOT NULL AND end_ts IS NOT NULL AND date >= ?
            ORDER BY date DESC LIMIT ?
            """,
            [.text(since), .int(limit)]) { r in
            guard let s = r.double(0), let e = r.double(1) else { return }
            out.append((s, e))
        }
        return out
    }

    /// Miroir de la requête `nights` de `tabHealth` (TS).
    func statsNightsSince(_ sinceDate: String) throws -> [(date: String, startTs: Double, endTs: Double, sleepS: Double)] {
        var out: [(date: String, startTs: Double, endTs: Double, sleepS: Double)] = []
        try db.run(
            """
            SELECT date, start_ts, end_ts, deep_s + light_s + rem_s AS sleepS
            FROM wellness_sleep WHERE date >= ? ORDER BY date ASC
            """,
            [.text(sinceDate)]) { r in
            guard let date = r.text(0), let s = r.double(1), let e = r.double(2), let sleepS = r.double(3) else { return }
            out.append((date, s, e, sleepS))
        }
        return out
    }

    /// Miroir de `nightAvg` (TS) — bornes INCLUSIVES (`<=`), contrairement à
    /// `samplesBetween` (`<`).
    func statsNightAvg(metric: String, from: Double, to: Double) throws -> Double? {
        var value: Double?
        try db.run(
            "SELECT AVG(value) FROM wellness_samples WHERE metric = ? AND ts >= ? AND ts <= ?",
            [.text(metric), .double(from), .double(to)]) { r in value = r.double(0) }
        return value
    }

    /// Miroir de `stressRow` (`tabHealth`, TS).
    func statsAvgStressSince(tsFrom: Double) throws -> Double? {
        var value: Double?
        try db.run(
            "SELECT AVG(value) FROM wellness_samples WHERE metric = 'stress' AND ts >= ?",
            [.double(tsFrom)]) { r in value = r.double(0) }
        return value
    }

    /// Miroir de `weights` (`tabHealth`, TS).
    func statsWeightsSince(_ sinceDate: String) throws -> [(date: String, kg: Double)] {
        var out: [(date: String, kg: Double)] = []
        try db.run(
            "SELECT date, kg FROM weight_log WHERE date >= ? ORDER BY date ASC",
            [.text(sinceDate)]) { r in
            guard let date = r.text(0), let kg = r.double(1) else { return }
            out.append((date, kg))
        }
        return out
    }

    /// Miroir de `stressByDate` (`tabHealth`, TS).
    func statsStressAvgByDate() throws -> [String: Double] {
        var out: [String: Double] = [:]
        try db.run(
            "SELECT date(ts, 'unixepoch') AS date, AVG(value) AS avg FROM wellness_samples WHERE metric = 'stress' GROUP BY date"
        ) { r in
            guard let date = r.text(0), let avg = r.double(1) else { return }
            out[date] = avg
        }
        return out
    }

    /// Miroir de `stepsByDate` (`tabHealth`, TS).
    func statsStepsSumByDate() throws -> [String: Double] {
        var out: [String: Double] = [:]
        try db.run("SELECT date, SUM(steps) AS steps FROM wellness_counters GROUP BY date") { r in
            guard let date = r.text(0), let steps = r.double(1) else { return }
            out[date] = steps
        }
        return out
    }

    /// Miroir de `loadByDate` (`tabHealth`, TS).
    func statsLoadByDate() throws -> [String: Double] {
        var out: [String: Double] = [:]
        try db.run(
            """
            SELECT date(start_time) AS date, SUM(duration_s * COALESCE(avg_hr, 100) / 100.0) AS load
            FROM activities WHERE start_time IS NOT NULL GROUP BY date
            """) { r in
            guard let date = r.text(0), let load = r.double(1) else { return }
            out[date] = load
        }
        return out
    }

    // MARK: - Dashboard / Stats — Entraînement (`tab-training`) — miroir
    // PARTIEL, cf. en-tête de `DashboardStats.swift` : `zones` n'est jamais
    // peuplé ici (pas de reparse `.fit` par activité), tout le reste (séances/
    // charge/répartition/streak/records) vient de `activities`/
    // `wellness_counters`, sans dépendre d'un moteur "programme" quelconque.

    struct StatsActivityRow {
        let sport: String?
        let startTime: String
        let durationS: Double?
        let distanceM: Double?
        let avgHr: Double?
        let maxHr: Double?
    }

    /// Miroir de la requête `rows` de `tabTraining` (TS) — exclusion des
    /// marches courtes déjà appliquée en SQL (même fragment que
    /// `EXCLUDE_SHORT_WALKS_SQL`, constante donc sans risque d'injection).
    func statsActivitiesSince(_ since: String) throws -> [StatsActivityRow] {
        var out: [StatsActivityRow] = []
        try db.run(
            """
            SELECT sport, start_time, duration_s, distance_m, avg_hr, max_hr
            FROM activities
            WHERE start_time IS NOT NULL AND start_time >= ?
              AND NOT (sport = 'walking' AND (duration_s IS NULL OR duration_s < 1800))
            ORDER BY start_time ASC
            """,
            [.text(since)]) { r in
            guard let startTime = r.text(1) else { return }
            out.append(StatsActivityRow(
                sport: r.text(0), startTime: startTime, durationS: r.double(2),
                distanceM: r.double(3), avgHr: r.double(4), maxHr: r.double(5)))
        }
        return out
    }

    /// Miroir de `previousTotal` (`tabTraining`, TS).
    func statsActivityDurationSum(from: String, until: String) throws -> Double {
        var total = 0.0
        try db.run(
            """
            SELECT COALESCE(SUM(duration_s), 0) FROM activities
            WHERE start_time IS NOT NULL AND start_time >= ? AND start_time < ?
              AND NOT (sport = 'walking' AND (duration_s IS NULL OR duration_s < 1800))
            """,
            [.text(from), .text(until)]) { r in total = r.double(0) ?? 0 }
        return total
    }

    /// Miroir de `wornDays` (`tabTraining`, TS).
    func statsWornDaysSince(_ sinceDate: String) throws -> Int {
        var count = 0
        try db.run(
            "SELECT COUNT(DISTINCT date) FROM wellness_counters WHERE date >= ?",
            [.text(sinceDate)]) { r in count = Int(r.double(0) ?? 0) }
        return count
    }

    /// Miroir de `activeKcal` (`tabTraining`, TS).
    func statsActiveCaloriesSince(_ sinceDate: String) throws -> Double {
        var total = 0.0
        try db.run(
            "SELECT COALESCE(SUM(active_calories), 0) FROM wellness_counters WHERE date >= ?",
            [.text(sinceDate)]) { r in total = r.double(0) ?? 0 }
        return total
    }

    /// Miroir de `allWeeks` (`tabTraining`, TS — calcul du streak) : même
    /// fonction SQLite `strftime('%Y-%W', ...)`, même moteur, même résultat.
    func statsAllWeeksActivityCounts() throws -> [(week: String, n: Int)] {
        var out: [(week: String, n: Int)] = []
        try db.run(
            """
            SELECT strftime('%Y-%W', start_time) AS week, COUNT(*) AS n FROM activities
            WHERE start_time IS NOT NULL
              AND NOT (sport = 'walking' AND (duration_s IS NULL OR duration_s < 1800))
            GROUP BY week ORDER BY week ASC
            """) { r in
            guard let week = r.text(0) else { return }
            out.append((week, Int(r.double(1) ?? 0)))
        }
        return out
    }

    // MARK: - Dashboard / Stats — Nutrition (`tab-nutrition`) — miroir
    // INTÉGRAL : contrairement à `nutrition/day` (`targets`/`remaining`,
    // dépendent de `target.ts`, non porté), `tab-nutrition` ne lit qu'un
    // réglage brut (`settings.nutritionKcal`, jamais écrit localement ici →
    // `nil`, même repli que le serveur sans cible configurée) — aucun moteur
    // "cible"/"programme" à porter pour CET endpoint précis.

    struct StatsFoodLogDailyRow {
        let date: String
        let kcal: Double?
        let protein: Double?
        let carbs: Double?
        let fat: Double?
        let entries: Int
    }

    /// Miroir de `logged` (`tabNutrition`, TS).
    func statsFoodLogDailyTotals(since: String) throws -> [StatsFoodLogDailyRow] {
        var out: [StatsFoodLogDailyRow] = []
        try db.run(
            """
            SELECT date, SUM(kcal), SUM(protein), SUM(carbs), SUM(fat), COUNT(*)
            FROM food_log WHERE date >= ? GROUP BY date ORDER BY date ASC
            """,
            [.text(since)]) { r in
            guard let date = r.text(0) else { return }
            out.append(StatsFoodLogDailyRow(
                date: date, kcal: r.double(1), protein: r.double(2), carbs: r.double(3), fat: r.double(4),
                entries: Int(r.double(5) ?? 0)))
        }
        return out
    }

    /// Miroir de `expenditure` (`tabNutrition`, TS) — valeurs déjà arrondies
    /// (`Math.round`), comme côté serveur.
    func statsExpenditureByDate(since: String) throws -> [String: Double] {
        var out: [String: Double] = [:]
        try db.run(
            """
            SELECT d.date, d.bmr_kcal,
                   (SELECT SUM(active_calories) FROM wellness_counters c WHERE c.date = d.date)
            FROM wellness_days d WHERE d.date >= ?
            """,
            [.text(since)]) { r in
            guard let date = r.text(0) else { return }
            let bmr = r.double(1) ?? 0
            let active = r.double(2) ?? 0
            out[date] = (bmr + active).rounded()
        }
        return out
    }

    struct StatsTopFoodRow { let name: String; let uses: Int; let kcal: Double?; let protein: Double? }

    /// Miroir de `topFoods` (`tabNutrition`, TS).
    func statsTopFoods(since: String, limit: Int) throws -> [StatsTopFoodRow] {
        var out: [StatsTopFoodRow] = []
        try db.run(
            """
            SELECT name, COUNT(*) AS uses, SUM(kcal) AS kcal, SUM(protein) AS protein
            FROM food_log WHERE date >= ? GROUP BY name ORDER BY uses DESC, kcal DESC LIMIT ?
            """,
            [.text(since), .int(limit)]) { r in
            guard let name = r.text(0) else { return }
            out.append(StatsTopFoodRow(name: name, uses: Int(r.double(1) ?? 0), kcal: r.double(2), protein: r.double(3)))
        }
        return out
    }

    // MARK: - Programme (incrément L7a, miroir `programme.controller.ts` — LECTURE
    // SEULE : `programme_state`/`programme_plan`/`programme_done` sont schéma-EXACT
    // de `db.service.ts` (y compris les colonnes `kind`/`days` de `programme_state`,
    // ajoutées côté serveur par une migration mais présentes ici directement dans
    // la création de table). AUCUNE route d'écriture locale (`activate`/`stop`/
    // `session`) n'existe encore (cf. `RealLocalPulseBackend`) : ces trois tables
    // restent donc TOUJOURS vides tant que l'utilisateur n'a pas activé un
    // programme depuis Pulse (mode Les deux) — `GET api/programme` retombe alors
    // honnêtement sur "aucun programme actif" pour les trois domaines, sans rien
    // fabriquer (même miroir que le serveur avec une base vide).

    struct ProgrammeStateRow {
        let programmeId: String
        let kind: String
        let startedOn: String
        let days: String?
    }

    /// Miroir de `activeState` (TS, privée, `ProgrammeController`).
    func programmeActiveState(kind: String) throws -> ProgrammeStateRow? {
        var result: ProgrammeStateRow?
        try db.run(
            "SELECT programme_id, kind, started_on, days FROM programme_state WHERE active = 1 AND kind = ? LIMIT 1",
            [.text(kind)]) { r in
            guard let id = r.text(0), let k = r.text(1), let started = r.text(2) else { return }
            result = ProgrammeStateRow(programmeId: id, kind: k, startedOn: started, days: r.text(3))
        }
        return result
    }

    struct ProgrammePlanRow {
        let week: Int
        let session: String
        let date: String
    }

    /// Miroir de `planRows` (TS, privée).
    func programmePlanRows(programmeId: String) throws -> [ProgrammePlanRow] {
        var out: [ProgrammePlanRow] = []
        try db.run(
            "SELECT week, session, date FROM programme_plan WHERE programme_id = ?",
            [.text(programmeId)]) { r in
            guard let session = r.text(1), let date = r.text(2) else { return }
            out.append(ProgrammePlanRow(week: Int(r.double(0) ?? 0), session: session, date: date))
        }
        return out
    }

    struct ProgrammeDoneRow {
        let week: Int
        let session: String
        let date: String
        let activityId: Int?
    }

    /// Miroir de `doneRows` (TS, privée) — `manual: true` reste à la charge
    /// de l'appelant (`RealLocalPulseBackend`), pas stocké en base (comme
    /// côté serveur, qui l'ajoute au vol dans le `.map`).
    func programmeDoneRows(programmeId: String) throws -> [ProgrammeDoneRow] {
        var out: [ProgrammeDoneRow] = []
        try db.run(
            "SELECT week, session, date, activity_id FROM programme_done WHERE programme_id = ?",
            [.text(programmeId)]) { r in
            guard let session = r.text(1), let date = r.text(2) else { return }
            out.append(ProgrammeDoneRow(
                week: Int(r.double(0) ?? 0), session: session, date: date,
                activityId: r.double(3).map { Int($0) }))
        }
        return out
    }

    struct ProgrammeActivityHitRow {
        let id: Int
        let date: String
        let sport: String?
        let subSport: String?
        let durationS: Double?
    }

    /// Miroir de `activitiesSince` (TS, privée).
    func programmeActivitiesSince(_ startedOn: String) throws -> [ProgrammeActivityHitRow] {
        var out: [ProgrammeActivityHitRow] = []
        try db.run(
            """
            SELECT id, substr(start_time, 1, 10) AS d, sport, sub_sport, duration_s
            FROM activities WHERE substr(start_time, 1, 10) >= ? ORDER BY start_time ASC
            """,
            [.text(startedOn)]) { r in
            guard let date = r.text(1) else { return }
            out.append(ProgrammeActivityHitRow(
                id: Int(r.double(0) ?? 0), date: date, sport: r.text(2), subSport: r.text(3), durationS: r.double(4)))
        }
        return out
    }

    struct ProgrammeSleepNightRow {
        let date: String
        let startTs: Double
        let endTs: Double
        let sleepS: Double
        let phases: String?
    }

    /// Miroir de `nightsUpTo` (TS, privée) — `limit` = `SLEEP_WINDOW_NIGHTS`
    /// (14, cf. `ProgrammeSleepEngine.windowNights`), passé par l'appelant.
    func programmeNightsUpTo(date: String, limit: Int) throws -> [ProgrammeSleepNightRow] {
        var out: [ProgrammeSleepNightRow] = []
        try db.run(
            """
            SELECT date, start_ts, end_ts, deep_s + light_s + rem_s, phases
            FROM wellness_sleep WHERE date <= ? AND start_ts IS NOT NULL AND end_ts IS NOT NULL
            ORDER BY date DESC LIMIT ?
            """,
            [.text(date), .int(limit)]) { r in
            guard let d = r.text(0), let startTs = r.double(1), let endTs = r.double(2), let sleepS = r.double(3)
            else { return }
            out.append(ProgrammeSleepNightRow(date: d, startTs: startTs, endTs: endTs, sleepS: sleepS, phases: r.text(4)))
        }
        return out
    }

    struct ProgrammeIntakeRow {
        let kcal: Double
        let protein: Double
        let carbs: Double
        let fat: Double
        let fiber: Double
    }

    /// Miroir de `intake` (TS, privée) — `nil` si aucune ligne (`!row.lines`),
    /// jamais un jour "loggé" à zéro.
    func programmeIntake(date: String) throws -> ProgrammeIntakeRow? {
        var result: ProgrammeIntakeRow?
        try db.run(
            "SELECT SUM(kcal), SUM(protein), SUM(carbs), SUM(fat), SUM(fiber), COUNT(*) FROM food_log WHERE date = ?",
            [.text(date)]) { r in
            guard let lines = r.double(5), lines > 0 else { return }
            result = ProgrammeIntakeRow(
                kcal: r.double(0) ?? 0, protein: r.double(1) ?? 0, carbs: r.double(2) ?? 0,
                fat: r.double(3) ?? 0, fiber: r.double(4) ?? 0)
        }
        return result
    }

    // MARK: - Programme — écriture (incrément L7b, miroir `activate`/`stop`/
    // `toggleSession` de `programme.controller.ts`, appelées depuis
    // `RealLocalPulseBackend`).

    /// Miroir de `activate()` (TS) — transaction complète : purge
    /// `programme_done` si le programme "bouge" (date de départ ou jours
    /// différents de l'état précédent, même comparaison que le serveur —
    /// `previous.days ?? ''` vs `days.join(',')`), désactive tout autre
    /// programme du même `kind`, upsert l'état actif (`ON CONFLICT` sur
    /// `programme_id`, comme le serveur), remplace entièrement le plan
    /// (`programme_plan`, purge puis réinsertion — `plan` vide pour un
    /// programme non `training`, cf. appelant).
    func programmeActivate(
        programmeId: String, kind: String, startedOn: String, days: [Int],
        plan: [(week: Int, session: String, date: String)]
    ) throws {
        try db.transaction {
            var previous: (startedOn: String, days: String?)?
            try db.run(
                "SELECT started_on, days FROM programme_state WHERE programme_id = ?",
                [.text(programmeId)]) { r in
                guard let started = r.text(0) else { return }
                previous = (started, r.text(1))
            }
            let daysJoined = days.map(String.init).joined(separator: ",")
            let moved = previous.map { $0.startedOn != startedOn || ($0.days ?? "") != daysJoined } ?? false
            if moved {
                try db.run("DELETE FROM programme_done WHERE programme_id = ?", [.text(programmeId)])
            }
            try db.run("UPDATE programme_state SET active = 0 WHERE kind = ?", [.text(kind)])
            try db.run(
                """
                INSERT INTO programme_state (programme_id, kind, started_on, active, days)
                VALUES (?, ?, ?, 1, ?)
                ON CONFLICT(programme_id) DO UPDATE SET kind = excluded.kind, started_on = excluded.started_on,
                                                         active = 1, days = excluded.days
                """,
                [.text(programmeId), .text(kind), .text(startedOn), .text(daysJoined)])
            try db.run("DELETE FROM programme_plan WHERE programme_id = ?", [.text(programmeId)])
            for row in plan {
                try db.run(
                    "INSERT INTO programme_plan (programme_id, week, session, date) VALUES (?, ?, ?, ?)",
                    [.text(programmeId), .int(row.week), .text(row.session), .text(row.date)])
            }
        }
    }

    /// Miroir de `stop()` (TS).
    func programmeStop(kind: String) throws {
        try db.run("UPDATE programme_state SET active = 0 WHERE kind = ?", [.text(kind)])
    }

    /// Miroir de la branche `body.done === false` de `toggleSession()` (TS).
    func programmeSessionDelete(programmeId: String, week: Int, session: String) throws {
        try db.run(
            "DELETE FROM programme_done WHERE programme_id = ? AND week = ? AND session = ?",
            [.text(programmeId), .int(week), .text(session)])
    }

    /// Miroir de l'`INSERT ... ON CONFLICT` final de `toggleSession()` (TS).
    func programmeSessionUpsert(programmeId: String, week: Int, session: String, date: String, activityId: Int?) throws {
        try db.run(
            """
            INSERT INTO programme_done (programme_id, week, session, date, activity_id)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(programme_id, week, session) DO UPDATE SET date = excluded.date, activity_id = excluded.activity_id
            """,
            [.text(programmeId), .int(week), .text(session), .text(date), sqliteOptional(activityId.map(Double.init))])
    }

    /// Miroir de `activityDate` (TS, privée) — jour calendaire
    /// (`substr(start_time, 1, 10)`) de l'activité `id`, `nil` si inconnue.
    func programmeActivityDate(id: Int) throws -> String? {
        var result: String?
        try db.run(
            "SELECT substr(start_time, 1, 10) FROM activities WHERE id = ?",
            [.int(id)]) { r in result = r.text(0) }
        return result
    }

    /// Miroir de `plannedOn` (TS, privée).
    func programmePlannedOn(programmeId: String, week: Int, session: String) throws -> String? {
        var result: String?
        try db.run(
            "SELECT date FROM programme_plan WHERE programme_id = ? AND week = ? AND session = ?",
            [.text(programmeId), .int(week), .text(session)]) { r in result = r.text(0) }
        return result
    }

    // MARK: - Programme — écriture de TEST seulement (incrément L7a)
    //
    // `ProgrammeReadLocalTests` (lecture) continue de seeder un programme actif
    // via ces trois méthodes plutôt que par `programmeActivate` (elle veut
    // poser un état ARBITRAIRE — plan/pointages disjoints d'un vrai calcul de
    // `buildPlan` — pour isoler la lecture du moteur d'activation) — même
    // esprit que `storeActivity` (écrite par l'ingestion, jamais par une route
    // HTTP). Préfixe `debug` pour signaler l'intention : ne PAS appeler depuis
    // `RealLocalPulseBackend` (qui utilise les méthodes ci-dessus).

    func debugActivateProgramme(programmeId: String, kind: String, startedOn: String, days: String?) throws {
        try db.run(
            """
            INSERT INTO programme_state (programme_id, kind, started_on, active, days)
            VALUES (?, ?, ?, 1, ?)
            ON CONFLICT(programme_id) DO UPDATE SET kind = excluded.kind, started_on = excluded.started_on,
                                                     active = 1, days = excluded.days
            """,
            [.text(programmeId), .text(kind), .text(startedOn), sqliteOptionalText(days)])
    }

    func debugInsertProgrammePlan(programmeId: String, week: Int, session: String, date: String) throws {
        try db.run(
            "INSERT OR REPLACE INTO programme_plan (programme_id, week, session, date) VALUES (?, ?, ?, ?)",
            [.text(programmeId), .int(week), .text(session), .text(date)])
    }

    func debugInsertProgrammeDone(programmeId: String, week: Int, session: String, date: String, activityId: Int?) throws {
        try db.run(
            """
            INSERT INTO programme_done (programme_id, week, session, date, activity_id) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(programme_id, week, session) DO UPDATE SET date = excluded.date, activity_id = excluded.activity_id
            """,
            [.text(programmeId), .int(week), .text(session), .text(date), sqliteOptional(activityId.map(Double.init))])
    }
}

private func sqliteOptional(_ value: Double?) -> SQLiteValue {
    value.map(SQLiteValue.double) ?? .null
}

private func sqliteOptionalText(_ value: String?) -> SQLiteValue {
    value.map(SQLiteValue.text) ?? .null
}
