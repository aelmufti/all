//
//  RecordsStats.swift
//  all (bridge-connect)
//
//  Calcul local de `GET api/stats/records` (page Records de l'onglet Stats) —
//  mêmes clés JSON que la route du serveur Pulse. Requêtes agrégées sur
//  `LocalDb` (un `ORDER BY … LIMIT 1` par record), jamais l'historique chargé
//  en entier, SAUF les `start_time` des activités pour les séries (une chaîne
//  par séance, ramenée au jour local en Swift).
//
//  Règles : valeurs NULL ou ≤ 0 ignorées ; aucun candidat → `nil` ; égalité →
//  le plus ANCIEN (puis plus petit id). Pour les journées on RÉUTILISE les
//  chiffres déjà affichés ailleurs : pas du jour = `statsStepsSumByDate`
//  (somme de `wellness_counters`, comme la page Santé), FC du jour = fenêtre
//  `[minuit local, +24 h[` de `LocalDb.days(limit:)` (`localOffsetSeconds`).
//

import Foundation

struct RecordsActivityDTO: Codable, Equatable {
    let activityId: Int
    let value: Double
    let startTime: String?
    let sport: String?
    let subSport: String?
}

struct RecordsDayDTO: Codable, Equatable {
    let date: String
    let value: Double
}

struct RecordsStreakDTO: Codable, Equatable {
    let start: String
    let end: String
    let days: Int
}

struct RecordsSessionsDTO: Codable, Equatable {
    let sport: String?
    let count: Int
    let longestDistance: RecordsActivityDTO?
    let longestDuration: RecordsActivityDTO?
    let bestPace: RecordsActivityDTO?
    let mostCalories: RecordsActivityDTO?
    let maxHr: RecordsActivityDTO?
    let highestAvgHr: RecordsActivityDTO?

    // `sport: null` doit rester présent dans le JSON (contrat) : encodage
    // explicite plutôt que l'omission par défaut d'un optionnel.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sport, forKey: .sport)
        try c.encode(count, forKey: .count)
        try c.encode(longestDistance, forKey: .longestDistance)
        try c.encode(longestDuration, forKey: .longestDuration)
        try c.encode(bestPace, forKey: .bestPace)
        try c.encode(mostCalories, forKey: .mostCalories)
        try c.encode(maxHr, forKey: .maxHr)
        try c.encode(highestAvgHr, forKey: .highestAvgHr)
    }
}

struct RecordsDaysDTO: Codable, Equatable {
    let mostSteps: RecordsDayDTO?
    let peakHr: RecordsDayDTO?
    let lowestRestingHr: RecordsDayDTO?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mostSteps, forKey: .mostSteps)
        try c.encode(peakHr, forKey: .peakHr)
        try c.encode(lowestRestingHr, forKey: .lowestRestingHr)
    }
}

struct RecordsSleepDTO: Codable, Equatable {
    let longestNight: RecordsDayDTO?
    let bestScore: RecordsDayDTO?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(longestNight, forKey: .longestNight)
        try c.encode(bestScore, forKey: .bestScore)
    }
}

struct RecordsStreaksDTO: Codable, Equatable {
    let longest: RecordsStreakDTO?
    let current: RecordsStreakDTO?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(longest, forKey: .longest)
        try c.encode(current, forKey: .current)
    }
}

struct RecordsDTO: Codable, Equatable {
    let sports: [String]
    let sessions: [RecordsSessionsDTO]
    let days: RecordsDaysDTO
    let sleep: RecordsSleepDTO
    let streaks: RecordsStreaksDTO
}

enum RecordsBackend {
    static func records(db: LocalDb, now: Date = Date(), calendar: Calendar = .current) throws -> Data {
        try JSONEncoder().encode(compute(db: db, now: now, calendar: calendar))
    }

    static func compute(db: LocalDb, now: Date, calendar: Calendar) throws -> RecordsDTO {
        let sports = try sportsByCount(db)
        var sessions = [try sessionRecords(db, sport: nil)]
        for sport in sports { sessions.append(try sessionRecords(db, sport: sport)) }

        let days = RecordsDaysDTO(
            mostSteps: mostSteps(try db.statsStepsSumByDate()),
            peakHr: try peakHr(db),
            lowestRestingHr: try dayRecord(
                db, "SELECT date, resting_hr FROM wellness_days WHERE resting_hr > 0 ORDER BY resting_hr ASC, date ASC LIMIT 1"))
        let sleep = RecordsSleepDTO(
            longestNight: try dayRecord(
                db, "SELECT date, duration_s FROM wellness_sleep WHERE duration_s > 0 ORDER BY duration_s DESC, date ASC LIMIT 1"),
            bestScore: try dayRecord(
                db, "SELECT date, score FROM wellness_sleep WHERE score > 0 ORDER BY score DESC, date ASC LIMIT 1"))

        var starts: [String] = []
        try db.db.run("SELECT start_time FROM activities WHERE start_time IS NOT NULL") { r in
            if let s = r.text(0) { starts.append(s) }
        }
        let streaks = streaks(startTimes: starts, now: now, calendar: calendar)
        return RecordsDTO(sports: sports, sessions: sessions, days: days, sleep: sleep, streaks: streaks)
    }

    // MARK: Séances

    private static func sportsByCount(_ db: LocalDb) throws -> [String] {
        var out: [String] = []
        try db.db.run(
            "SELECT sport FROM activities WHERE sport IS NOT NULL GROUP BY sport ORDER BY COUNT(*) DESC, sport ASC"
        ) { r in if let s = r.text(0) { out.append(s) } }
        return out
    }

    private static func sessionRecords(_ db: LocalDb, sport: String?) throws -> RecordsSessionsDTO {
        let params: [SQLiteValue] = sport.map { [.text($0)] } ?? []
        var count = 0
        try db.db.run("SELECT COUNT(*) FROM activities" + (sport == nil ? "" : " WHERE sport = ?"), params) { r in
            count = Int(r.double(0) ?? 0)
        }
        // `expr` : valeur comparée ; `ascending` : le plus petit gagne (allure).
        func best(_ expr: String, where extra: String? = nil, ascending: Bool = false) throws -> RecordsActivityDTO? {
            var out: RecordsActivityDTO?
            try db.db.run(
                """
                SELECT id, \(expr), start_time, sport, sub_sport FROM activities
                WHERE \(extra ?? "\(expr) > 0")\(sport == nil ? "" : " AND sport = ?")
                ORDER BY \(expr) \(ascending ? "ASC" : "DESC"), start_time IS NULL, start_time ASC, id ASC LIMIT 1
                """, params) { r in
                out = RecordsActivityDTO(
                    activityId: Int(r.double(0) ?? 0), value: r.double(1) ?? 0, startTime: r.text(2),
                    sport: r.text(3), subSport: r.text(4))
            }
            return out
        }
        return RecordsSessionsDTO(
            sport: sport, count: count,
            longestDistance: try best("distance_m"), longestDuration: try best("duration_s"),
            bestPace: try best("duration_s / (distance_m / 1000.0)", where: "distance_m >= 1000 AND duration_s > 0", ascending: true),
            mostCalories: try best("calories"), maxHr: try best("max_hr"), highestAvgHr: try best("avg_hr"))
    }

    // MARK: Journées

    private static func dayRecord(_ db: LocalDb, _ sql: String) throws -> RecordsDayDTO? {
        var out: RecordsDayDTO?
        try db.db.run(sql) { r in
            if let d = r.text(0), let v = r.double(1) { out = RecordsDayDTO(date: d, value: v) }
        }
        return out
    }

    /// Plus de pas : max des totaux du jour, égalité → date la plus ancienne.
    static func mostSteps(_ byDate: [String: Double]) -> RecordsDayDTO? {
        byDate.filter { $0.value > 0 }
            .min { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { RecordsDayDTO(date: $0.key, value: $0.value) }
    }

    /// FC max des échantillons continus par jour LOCAL — même fenêtre que
    /// `LocalDb.days(limit:)` : `[minuit UTC − offset du jour, +24 h[`. Le
    /// décalage varie avec l'heure d'été : une requête groupée par jour par
    /// décalage distinct rencontré, ne gardant que les jours dont le décalage
    /// (à midi) est bien celui-là.
    private static func peakHr(_ db: LocalDb) throws -> RecordsDayDTO? {
        var range: (Double, Double)?
        try db.db.run("SELECT MIN(ts), MAX(ts) FROM wellness_samples WHERE metric = 'hr'") { r in
            if let lo = r.double(0), let hi = r.double(1) { range = (lo, hi) }
        }
        guard let range else { return nil }
        // Décalages possibles sur la plage (± 1 jour de marge).
        var offsets = Set<Int>()
        var t = range.0 - 86400
        while t <= range.1 + 86400 {
            offsets.insert(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: t)))
            t += 86400
        }
        var best: RecordsDayDTO?
        for offset in offsets {
            try db.db.run(
                """
                SELECT date(ts + ?, 'unixepoch') AS d, MAX(value) FROM wellness_samples
                WHERE metric = 'hr' GROUP BY d HAVING MAX(value) > 0
                """, [.int(offset)]) { r in
                guard let d = r.text(0), let v = r.double(1),
                      Int(LocalDb.localOffsetSeconds(forDate: d)) == offset else { return }
                if best == nil || v > best!.value || (v == best!.value && d < best!.date) {
                    best = RecordsDayDTO(date: d, value: v)
                }
            }
        }
        return best
    }

    // MARK: Séries

    private static let isoMs: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    private static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Séries de jours locaux consécutifs avec ≥ 1 activité. `current` : la
    /// série qui se termine aujourd'hui ou hier, sinon `nil`.
    static func streaks(startTimes: [String], now: Date, calendar: Calendar) -> RecordsStreaksDTO {
        let plain = ISO8601DateFormatter()
        var days = Set<Date>()   // minuits locaux
        for s in startTimes {
            guard let d = isoMs.date(from: s) ?? plain.date(from: s) else { continue }
            days.insert(calendar.startOfDay(for: d))
        }
        let sorted = days.sorted()
        var runs: [(start: Date, end: Date, n: Int)] = []
        for d in sorted {
            if let last = runs.last, calendar.date(byAdding: .day, value: 1, to: last.end) == d {
                runs[runs.count - 1] = (last.start, d, last.n + 1)
            } else {
                runs.append((d, d, 1))
            }
        }
        func dto(_ r: (start: Date, end: Date, n: Int)) -> RecordsStreakDTO {
            RecordsStreakDTO(start: dayKey(r.start, calendar), end: dayKey(r.end, calendar), days: r.n)
        }
        // Plus longue : égalité → la plus ancienne (`runs` est chronologique).
        var longest: (start: Date, end: Date, n: Int)?
        for r in runs where r.n > (longest?.n ?? 0) { longest = r }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        var current: RecordsStreakDTO?
        if let last = runs.last, last.end == today || last.end == yesterday { current = dto(last) }
        return RecordsStreaksDTO(longest: longest.map(dto), current: current)
    }
}
