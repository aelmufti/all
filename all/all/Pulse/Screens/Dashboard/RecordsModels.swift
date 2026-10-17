//
//  RecordsModels.swift
//  all (bridge-connect)
//
//  Modèles décodables de `GET api/stats/records` (page Records de l'onglet
//  Stats) — mêmes clés que le serveur Pulse et que le backend local
//  (`Local/RecordsStats.swift`). Tout record peut être `null`.
//

import Foundation

struct RecordsActivity: Decodable, Equatable {
    let activityId: Int
    let value: Double
    let startTime: String?
    let sport: String?
    let subSport: String?
}

struct RecordsDay: Decodable, Equatable {
    let date: String
    let value: Double
}

struct RecordsStreak: Decodable, Equatable {
    let start: String
    let end: String
    let days: Int
}

struct RecordsSessions: Decodable, Equatable {
    let sport: String?
    let count: Int
    let longestDistance: RecordsActivity?
    let longestDuration: RecordsActivity?
    let bestPace: RecordsActivity?
    let mostCalories: RecordsActivity?
    let maxHr: RecordsActivity?
    let highestAvgHr: RecordsActivity?
}

struct RecordsDays: Decodable, Equatable {
    let mostSteps: RecordsDay?
    let peakHr: RecordsDay?
    let lowestRestingHr: RecordsDay?
}

struct RecordsSleep: Decodable, Equatable {
    let longestNight: RecordsDay?
    let bestScore: RecordsDay?
}

struct RecordsStreaks: Decodable, Equatable {
    let longest: RecordsStreak?
    let current: RecordsStreak?
}

struct RecordsPayload: Decodable, Equatable {
    let sports: [String]
    let sessions: [RecordsSessions]
    let days: RecordsDays
    let sleep: RecordsSleep
    let streaks: RecordsStreaks

    /// Records « séances » du filtre : `nil` = tous sports (1re entrée).
    func sessions(for sport: String?) -> RecordsSessions? {
        sessions.first { $0.sport == sport }
    }
}

/// Destination poussée depuis la ligne « Records » de l'aperçu Stats.
enum RecordsRoute: Hashable {
    case page
}
