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
        try self.init(path: dir.appendingPathComponent("pulse-embarque.sqlite").path)
    }

    /// Init testable : base à un chemin arbitraire (fichier temporaire en test).
    init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try db.execute(Self.schema)
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
    """

    // MARK: - Dédup (`imported_files`) — même principe que Pulse : hash du
    // contenu, indépendant du nom de fichier montre.

    func isImported(hash: String) throws -> Bool {
        var found = false
        try db.run("SELECT 1 FROM imported_files WHERE hash = ?", [.text(hash)]) { _ in found = true }
        return found
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
    /// colonnes, même ordre. Renvoie l'id auto-incrémenté inséré.
    @discardableResult
    func storeActivity(_ summary: FitActivityExtractor.Summary, hash: String, fileName: String) throws -> Int {
        try db.run(
            """
            INSERT INTO activities (file_hash, file_name, sport, sub_sport, start_time, duration_s, distance_m, calories, avg_hr, max_hr)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(hash), .text(fileName), sqliteOptionalText(summary.sport), sqliteOptionalText(summary.subSport),
             sqliteOptionalText(summary.startTime), sqliteOptional(summary.durationS), sqliteOptional(summary.distanceM),
             sqliteOptional(summary.calories), sqliteOptional(summary.avgHr), sqliteOptional(summary.maxHr)])
        var id = 0
        try db.run("SELECT last_insert_rowid()") { r in id = Int(r.double(0) ?? 0) }
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
    /// qu'un fuseau, celui de l'appareil.
    private static func localOffsetSeconds(forDate date: String) -> Double {
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
}

private func sqliteOptional(_ value: Double?) -> SQLiteValue {
    value.map(SQLiteValue.double) ?? .null
}

private func sqliteOptionalText(_ value: String?) -> SQLiteValue {
    value.map(SQLiteValue.text) ?? .null
}
