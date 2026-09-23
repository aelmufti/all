//
//  DashboardModels.swift
//  all (bridge-connect)
//
//  Modèles natifs de l'écran Dashboard (page Angular `/dashboard` — en réalité
//  intitulée « Statistiques » côté front, `custom-connect/web/src/app/pages/
//  dashboard/dashboard.component.ts`). Cinq onglets : Sommeil, Entraînement,
//  Santé, Nutrition, Carte.
//
//  Ne modélise QUE ce que le template Angular affiche réellement (beaucoup de
//  signaux/endpoints du composant — `volume`, `records`, `fitnessAge`,
//  `stressExtremes`, `weight`, `nutritionHistory`, `energyBalance`,
//  `trainingLoad`, `aerobic`, `profile`… — sont chargés par `refreshAll()`
//  mais n'ont plus aucune liaison dans le template : code mort laissé par une
//  refonte antérieure vers les endpoints `tab-*`. Vérifié par grep sur le
//  template avant de modéliser.).
//
//  Endpoints réellement rendus, formes lues dans
//  `custom-connect/server/src/stats/stats.controller.ts` et
//  `custom-connect/server/src/wellness/wellness.controller.ts` :
//    - GET api/stats/tab-training?days=N   → DashboardTrainingTab
//    - GET api/stats/tab-health?days=N     → DashboardHealthTab
//    - GET api/stats/tab-nutrition?days=N  → DashboardNutritionTab
//    - GET api/stats/sleep-debt?days=N     → DashboardSleepDebt
//    - GET api/stats/sleep-insights?days=N → DashboardSleepInsights
//    - GET api/stats/sleep-regularity?days=N → DashboardSleepRegularity
//    - GET api/wellness/days?limit=N&days=N&bodyBattery=0 → [DashboardWellnessDayRow]
//
//  Toutes les dates exposées par ces endpoints sont des chaînes calendaires
//  `YYYY-MM-DD` (jamais d'epoch ici) — typées `String`, jamais `Date`, converties
//  à l'affichage via `dashboardDate(from:)` (`DashboardFormatting.swift`), cf.
//  la doc de `PulseAPIClient.decoder`.
//

import Foundation

// MARK: - Période / onglets / sous-vues

/// Fenêtre temporelle commune à tous les onglets — `PERIODS` côté Angular.
enum DashboardPeriod: String, CaseIterable, Identifiable, Hashable {
    case oneMonth = "1m"
    case threeMonths = "3m"
    case oneYear = "1y"
    case all = "all"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneMonth: return "1 mois"
        case .threeMonths: return "3 mois"
        case .oneYear: return "1 an"
        case .all: return "Depuis le début"
        }
    }

    var shortLabel: String {
        switch self {
        case .oneMonth: return "1 M"
        case .threeMonths: return "3 M"
        case .oneYear: return "1 an"
        case .all: return "Tout"
        }
    }

    /// Fenêtre en jours envoyée en requête (`days`) — `all` reprend la même
    /// borne haute que le front (3660 j, ~10 ans) plutôt qu'un cas spécial.
    var days: Int {
        switch self {
        case .oneMonth: return 30
        case .threeMonths: return 90
        case .oneYear: return 365
        case .all: return 3660
        }
    }
}

/// `StatsTab` côté Angular.
enum DashboardTab: String, CaseIterable, Identifiable, Hashable {
    case sleep = "sommeil"
    case training = "entrainement"
    case health = "sante"
    case nutrition = "nutrition"
    case map = "carte"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sleep: return "Sommeil"
        case .training: return "Entraînement"
        case .health: return "Santé"
        case .nutrition: return "Nutrition"
        case .map: return "Carte"
        }
    }
}

/// Sous-vue sélectionnée à l'intérieur d'un onglet (équivalent `VIEWS` +
/// `app-seg` côté Angular). L'app étant toujours "étroite" (téléphone), une
/// seule sous-vue s'affiche à la fois — pas d'équivalent du mode large qui les
/// montre toutes côte à côte.
enum DashboardSubView: String, CaseIterable, Identifiable, Hashable {
    // Sommeil
    case trend, debt, regularity
    // Entraînement
    case load, sport, zones, records
    // Santé
    case restingHr, respiration, spo2, weight, correlations
    // Nutrition
    case intake, macros, logging, foods

    var id: String { rawValue }

    var label: String {
        switch self {
        case .trend: return "Tendance"
        case .debt: return "Dette"
        case .regularity: return "Régularité"
        case .load: return "Charge"
        case .sport: return "Sport"
        case .zones: return "Zones"
        case .records: return "Records"
        case .restingHr: return "FC repos"
        case .respiration: return "Respiration"
        case .spo2: return "SpO2"
        case .weight: return "Poids"
        case .correlations: return "Liens"
        case .intake: return "Apport"
        case .macros: return "Macros"
        case .logging: return "Régularité"
        case .foods: return "Aliments"
        }
    }
}

/// `VIEWS[tab]` côté Angular.
func dashboardSubViews(for tab: DashboardTab) -> [DashboardSubView] {
    switch tab {
    case .sleep: return [.trend, .debt, .regularity]
    case .training: return [.load, .sport, .zones, .records]
    case .health: return [.restingHr, .respiration, .spo2, .weight, .correlations]
    case .nutrition: return [.intake, .macros, .logging, .foods]
    case .map: return []
    }
}

// MARK: - api/stats/tab-training

struct DashboardTrainingTab: Decodable, Equatable {
    let days: Int
    let count: Int
    let totalS: Int
    let perWeek: Double
    let avgHr: Int?
    let activeKcal: Int
    let deltaPct: Int?
    let weeks: [DashboardTrainingWeek]
    let shares: [DashboardSportShare]
    let streak: DashboardStreak
    let zones: [DashboardZone]
    let records: DashboardTrainingRecords
}

struct DashboardTrainingWeek: Decodable, Equatable, Identifiable {
    let week: String
    let label: String
    let load: Int
    let durationS: Int
    let sessions: Int
    let avg4: Int?
    let overload: Bool

    var id: String { week }
}

struct DashboardSportShare: Decodable, Equatable, Identifiable {
    let sport: String
    let durationS: Int
    let pct: Int

    var id: String { sport }
}

struct DashboardStreak: Decodable, Equatable {
    let best: Int
    let current: Int
}

struct DashboardZone: Decodable, Equatable, Identifiable {
    let zone: Int
    let seconds: Int

    var id: Int { zone }
}

struct DashboardTrainingRecords: Decodable, Equatable {
    let longestSession: DashboardPeriodRecord?
    let longestDistance: DashboardPeriodRecord?
    let bestPace: DashboardPeriodRecord?
    let heaviestWeek: DashboardPeriodRecord?
    let maxHr: DashboardPeriodRecord?
}

/// `value` couvre des unités différentes selon le record (secondes, mètres,
/// s/km, bpm) — l'affichage sait laquelle en fonction du champ, `Double`
/// encaisse aussi bien les entiers que les décimales renvoyées par Nest.
struct DashboardPeriodRecord: Decodable, Equatable {
    let value: Double
    let date: String?
    let label: String?
}

// MARK: - api/stats/tab-health

struct DashboardHealthTab: Decodable, Equatable {
    let days: Int
    let restingHr: Int?
    let respiration: Double?
    let spo2Night: Double?
    let stress: Int?
    let weightKg: Double?
    let sleepHours: Double?
    let restingSeries: [DashboardHealthPoint]
    let restingDelta: Int?
    let respirationSeries: [DashboardHealthPoint]
    let respirationBand: DashboardRange?
    let spo2Buckets: [DashboardSpo2Bucket]
    let spo2Nights: Int
    let weightSeries: [DashboardWeightPoint]
    let weightDelta: Double?
    let correlations: [DashboardCorrelation]
}

struct DashboardHealthPoint: Decodable, Equatable, Identifiable {
    let date: String
    let value: Double

    var id: String { date }
}

struct DashboardRange: Decodable, Equatable {
    let lo: Double
    let hi: Double
}

struct DashboardSpo2Bucket: Decodable, Equatable, Identifiable {
    let label: String
    let nights: Int

    var id: String { label }
}

struct DashboardWeightPoint: Decodable, Equatable, Identifiable {
    let date: String
    let kg: Double

    var id: String { date }
}

struct DashboardCorrelation: Decodable, Equatable, Identifiable {
    let label: String
    let r: Double?
    let strength: String
    let pairs: Int

    var id: String { label }
}

// MARK: - api/stats/tab-nutrition

struct DashboardNutritionTab: Decodable, Equatable {
    let days: Int
    let kcalPerDay: Int?
    let expenditurePerDay: Int?
    let balance: Int?
    let proteinPerDay: Int?
    let daysLogged: Int
    let completeDays: Int
    let entriesPerDay: Double
    let series: [DashboardNutritionDay]
    let macros: [DashboardMacro]
    let topFoods: [DashboardTopFood]
    let totalEntries: Int
}

/// `state` : `"complete" | "partial" | "none"`.
struct DashboardNutritionDay: Decodable, Equatable, Identifiable {
    let date: String
    let kcal: Int?
    let expenditure: Int?
    let state: String

    var id: String { date }
}

struct DashboardMacro: Decodable, Equatable, Identifiable {
    let key: String
    let label: String
    let grams: Int?
    let pct: Int

    var id: String { key }
}

struct DashboardTopFood: Decodable, Equatable, Identifiable {
    let name: String
    let uses: Int
    let kcal: Int
    let protein: Int
    let pct: Int

    var id: String { name }
}

// MARK: - api/stats/sleep-debt

struct DashboardSleepDebt: Decodable, Equatable {
    let nights: Int
    let targetHours: Int
    let debtHours: Double
    let avgHours: Double
    let deficitNights: Int
    let avgInBedHours: Double
    let avgAwakeMin: Int
    let detail: [DashboardSleepDebtNight]
}

struct DashboardSleepDebtNight: Decodable, Equatable, Identifiable {
    let date: String
    let sleepS: Int
    let inBedS: Int
    let awakeS: Int
    let deltaS: Int
    let cumulativeS: Int
    let score: Int?
    let bedtime: String?

    var id: String { date }
}

// MARK: - api/stats/sleep-insights

struct DashboardSleepInsights: Decodable, Equatable {
    let stressImpact: DashboardStressImpact
    let fragmentation: DashboardFragmentation
    let composition: DashboardComposition
    let spo2Arousal: DashboardSpo2Arousal?
}

struct DashboardStressImpact: Decodable, Equatable {
    let nights: Int
    let r: Double?
    let significant: Bool
    let buckets: [DashboardStressBucket]
}

struct DashboardStressBucket: Decodable, Equatable, Identifiable {
    let label: String
    let nights: Int
    let avgStress: Double?

    var id: String { label }
}

struct DashboardFragmentation: Decodable, Equatable {
    let nights: Int
    let avgArousals: Double
    let avgAwakeMin: Int
    let avgLongestMin: Int
    let series: [DashboardFragmentationPoint]
}

struct DashboardFragmentationPoint: Decodable, Equatable, Identifiable {
    let date: String
    let arousals: Int
    let awakeMin: Int
    let longestMin: Int

    var id: String { date }
}

struct DashboardComposition: Decodable, Equatable {
    let nights: Int
    let deep: Double
    let light: Double
    let rem: Double
    let wasoPct: Double
    let ref: DashboardCompositionRef
}

struct DashboardCompositionRef: Decodable, Equatable {
    let deep: DashboardRange
    let light: DashboardRange
    let rem: DashboardRange
}

struct DashboardSpo2Arousal: Decodable, Equatable {
    let nights: Int
    let desatTotal: Int
    let desatNearPct: Double
    let controlPct: Double
    let medianArousalMin: Int
    let microArousals: Int
    let totalArousals: Int
}

// MARK: - api/stats/sleep-regularity

struct DashboardSleepRegularity: Decodable, Equatable {
    let nights: Int
    let score: Int?
    let bedtime: String?
    let waketime: String?
    let bedStdMin: Int?
    let wakeStdMin: Int?
}

// MARK: - api/wellness/days

/// Sous-ensemble de `WellnessDayRow` (le contrôleur Nest renvoie beaucoup plus
/// de champs — `bmrKcal`, `bodyBatteryHigh/Low`, `minHr`/`maxHr`,
/// `sleepScore`… — mais seuls ceux-ci alimentent le graphe de tendance sommeil
/// du template, cf. `dayRows`/`sleepHours()`/`seriesOf()` côté Angular).
struct DashboardWellnessDayRow: Decodable, Equatable, Identifiable {
    let date: String
    let restingHr: Int?
    let avgStress: Int?
    let sleepDurationS: Int?
    let sportCalories: Double?
    let steps: Int?

    var id: String { date }
}
