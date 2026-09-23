//
//  HealthModels.swift
//  all (bridge-connect)
//
//  Modèles `Decodable`/`Encodable` de l'écran Santé — miroir des formes JSON
//  exposées par NestJS (`custom-connect/server/src/wellness/*.controller.ts`,
//  `weight/weight.controller.ts`) et consommées par la page Angular `/health`
//  (`custom-connect/web/src/app/pages/health/health.component.ts`).
//
//  Convention socle (cf. `PulseAPIClient.decoder`, pas de stratégie de date) :
//  les epoch restent `Int`, les champs calendaires `YYYY-MM-DD` restent
//  `String`. Les mesures numériques dont le type SQLite sous-jacent peut être
//  entier OU flottant selon la provenance (colonne stockée vs. série simulée,
//  ex. `bodyBatteryHigh`) sont typées `Double` par prudence : décoder un
//  entier JSON dans un `Double` marche toujours, l'inverse (un flottant dans
//  un `Int`) plante — l'affichage arrondit si besoin.
//

import Foundation

// MARK: - Échantillons de série temporelle

/// Un point `{ ts, value }` — FC, stress, SpO2, respiration, pivot d'énergie
/// corporelle. `ts` en secondes epoch Unix (déjà décalé au fuseau
/// d'affichage côté serveur, cf. `tzOffsetSeconds` dans le contrôleur).
struct WellnessSample: Decodable {
    let ts: Int
    let value: Double
}

// MARK: - Sommeil

enum SleepStageKind: String, Decodable {
    case awake, light, deep, rem
}

struct SleepInterval: Decodable {
    let from: Int
    let to: Int
}

struct SleepStageInterval: Decodable {
    let from: Int
    let to: Int
    let stage: SleepStageKind
}

struct SleepMain: Decodable {
    let from: Int
    let to: Int
    let durationS: Double
}

struct WellnessDaySleep: Decodable {
    let segments: [SleepInterval]
    let main: SleepMain?
    let stages: [SleepStageInterval]
    let score: Double?
}

// MARK: - Activités du jour (résumé, pas le détail `/activity/:id`)

struct DayActivity: Decodable {
    let id: Int
    let sport: String?
    let subSport: String?
    let startTs: Int
    let durationS: Double?
    let calories: Double?
}

// MARK: - `GET /api/wellness/day/:date`

/// Sous-ensemble de `WellnessDayRow` renvoyé dans `summary` par le détail du
/// jour (`WellnessController.day`) — `restingHr`/`bmrKcal`/`bodyBatteryHigh`/
/// `bodyBatteryLow` peuvent être des clés totalement absentes du JSON quand
/// `wellness_days` n'a pas de ligne pour la date (spread de `undefined` côté
/// Nest) : des propriétés `Optional` suffisent, `Decodable` synthétisé traite
/// une clé manquante comme `nil` pour un `Optional`, pas comme une erreur.
struct WellnessDaySummary: Decodable {
    let restingHr: Double?
    let bmrKcal: Double?
    let bodyBatteryHigh: Double?
    let bodyBatteryLow: Double?
    let steps: Double?
    let activeCalories: Double?
    let distanceM: Double?
    let sportCalories: Double?
}

struct WellnessDayDetail: Decodable {
    let date: String
    let summary: WellnessDaySummary
    let hr: [WellnessSample]
    let stress: [WellnessSample]
    let spo2: [WellnessSample]
    let respiration: [WellnessSample]
    let bodyBatteryPivot: [WellnessSample]
    let activities: [DayActivity]
    let sleep: WellnessDaySleep
    // `counterSeries` existe côté API mais n'est consommé par aucun écran
    // (ni la page Angular, ni celui-ci) — volontairement absent d'ici.
}

// MARK: - `GET /api/wellness/days` (historique 30 jours) & `GET /api/wellness/dates`

struct WellnessDayRow: Decodable, Identifiable {
    var id: String { date }

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
}

// MARK: - `GET /api/wellness/intensity/day/:date`

struct IntensityBout: Decodable {
    let from: Int
    let to: Int
    let moderateMin: Double
    let vigorousMin: Double
    let minutes: Double
    let straddles: Bool
}

/// `source`/`restingSource` restent `String` (pas d'enum) : ce sont des
/// libellés de provenance affichés tels quels, pas des branches de logique
/// dans cet écran — pas la peine de figer les valeurs possibles côté client.
struct IntensityParamsView: Decodable {
    let maxHeartRate: Double
    let moderateBpm: Double
    let vigorousBpm: Double
    let moderatePct: Double
    let vigorousPct: Double
    let minBoutS: Double
    let maxGapS: Double
    let dipToleranceS: Double
    let minCoverage: Double
    let source: String
    let measuredAt: String?
    let hrCalcType: String?
    let restingHeartRate: Double
    let restingSource: String
}

struct IntensityDayDetail: Decodable {
    let date: String
    let minutes: Double
    let moderateMin: Double
    let vigorousMin: Double
    let coverage: Double
    let elapsed: Double
    let bouts: [IntensityBout]
    let params: IntensityParamsView
}

// MARK: - `GET /api/weight`, `POST /api/weight`, `DELETE /api/weight/:date`

/// Miroir de `WeightPushState` (`weight/weight-push.service.ts`) — statut de
/// transmission du dernier poids saisi vers le profil de la montre.
struct WeightPush: Decodable {
    let status: String // "idle" | "pending" | "sent" | "expired"
    let kg: Double?
    let at: String?
}

struct WeightSeriesPoint: Decodable, Identifiable {
    var id: String { date }

    let date: String
    let kg: Double
    let avg: Double
}

struct WeightData: Decodable {
    let current: Double?
    let currentDate: String?
    let deltaKg: Double?
    let entries: Int
    let series: [WeightSeriesPoint]
    let push: WeightPush
}

/// Corps de `POST /api/weight` (`WeightController.add`).
struct WeightSaveRequest: Encodable {
    let date: String
    let kg: Double
}

/// Réponse de `POST /api/weight` — `{ date, kg }`, non exploitée au-delà de
/// satisfaire le type générique `PulseAPIClient.post`.
struct WeightSaveResult: Decodable {
    let date: String
    let kg: Double
}
