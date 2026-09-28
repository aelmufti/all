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
//  Sous-ensemble : seules les tables du chemin bien-être (`imported_files`,
//  `wellness_days`, `wellness_counters`, `wellness_counter_samples`,
//  `wellness_samples`, `wellness_sleep`). Le reste (`activities`, `foods`…)
//  arrive avec les incréments qui en ont besoin (L3+, hors périmètre ici).
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
}

private func sqliteOptional(_ value: Double?) -> SQLiteValue {
    value.map(SQLiteValue.double) ?? .null
}
