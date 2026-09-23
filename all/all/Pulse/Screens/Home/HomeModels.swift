//
//  HomeModels.swift
//  all (bridge-connect)
//
//  Modèles `Codable` de l'écran Accueil — sous-ensemble des réponses Pulse
//  réellement consommé par `HomeView`/`HomeViewModel` (entraînement +
//  intensité du jour, + FC « Maintenant »). Formes dérivées en lisant les
//  contrôleurs NestJS (pas devinées) :
//    - `GET api/wellness/day/:date`      → `server/src/wellness/wellness.controller.ts` (méthode `day`)
//    - `GET api/wellness/days`           → idem, méthode `days`
//    - `GET api/activities`              → `server/src/activities/activities.controller.ts` (méthode `list`)
//    - `GET api/wellness/intensity`      → `server/src/wellness/intensity.service.ts` (méthode `report`)
//    - `GET api/programme`               → `server/src/programme/programme.controller.ts` (méthode `current`/`domainView`)
//    - `GET/POST api/live/hr`            → `server/src/sync/live.controller.ts`
//
//  Aucun champ `Date` : l'API renvoie soit des epoch secondes (`Int`/`Double`),
//  soit des chaînes calendaires `YYYY-MM-DD` (`String`) — cf. commentaire de
//  `PulseAPIClient.decoder`. On type en conséquence et on convertit localement
//  dans le view-model.
//

import Foundation

// MARK: - Jour (FC « Maintenant » + vitaux)

/// Un échantillon d'une série temporelle (`wellness_samples`) — `ts` en epoch
/// secondes Unix (déjà corrigé du fuseau côté serveur), `value` en `Double`
/// pour couvrir aussi bien les métriques entières (FC, stress) que décimales.
struct HomeSample: Decodable {
    let ts: Int
    let value: Double
}

/// `restingHr` typé `Double?` (pas `Int?`) : même prudence que
/// `WellnessDaySummary` côté écran Santé — la colonne SQLite sous-jacente
/// peut être entière ou flottante selon la provenance, un `Int` planterait
/// sur une valeur fractionnaire. `HomeViewModel` arrondit à l'affichage.
struct HomeDaySummary: Decodable {
    let restingHr: Double?
    let bmrKcal: Double?
    let steps: Double?
    let activeCalories: Double?
    let sportCalories: Double?
    let distanceM: Double?
}

// MARK: - Sommeil (nuit du jour affiché)

enum HomeSleepStageKind: String, Decodable {
    case awake, light, deep, rem
}

/// Un segment de phase de sommeil — `SleepStage` côté Angular. `from`/`to` en
/// secondes epoch (déjà décalées au fuseau d'affichage côté serveur, comme
/// `HomeSample.ts`) : la largeur d'un bloc d'hypnogramme est directement
/// `to - from`, pas la peine de reconvertir.
struct HomeSleepInterval: Decodable {
    let from: Int
    let to: Int
    let stage: HomeSleepStageKind
}

struct HomeSleepMain: Decodable {
    let from: Int
    let to: Int
    let durationS: Double
}

/// Toujours présent dans la réponse (même sans nuit : `main: null`,
/// `stages: []`, `score: null`) — cf. `WellnessController.day`,
/// `sleep: { segments, main: nightSleep?.main ?? null, stages: … ?? [], score: … ?? null }`.
struct HomeDaySleep: Decodable {
    let main: HomeSleepMain?
    let stages: [HomeSleepInterval]
    let score: Double?
}

/// `GET api/wellness/day/:date` — sous-ensemble utile à l'Accueil (FC, stress,
/// SpO2, respiration, sommeil de la nuit + FC de repos/pas/calories « depuis
/// le réveil »).
struct HomeDayDetail: Decodable {
    let date: String
    let summary: HomeDaySummary
    let hr: [HomeSample]
    let stress: [HomeSample]
    let spo2: [HomeSample]
    let respiration: [HomeSample]
    let sleep: HomeDaySleep

    /// Miroir de `hasData()` côté Angular (`home.component.ts`) : un jour
    /// « vide » (aucune FC/stress/pas/nuit) déclenche le repli sur le
    /// dernier jour connu plutôt que d'afficher une page blanche.
    var hasData: Bool {
        !hr.isEmpty || !stress.isEmpty || (summary.steps ?? 0) > 0 || sleep.main != nil
    }
}

// MARK: - Dette de sommeil (« Nuit dernière » — écart vs habitude)

/// `GET api/stats/sleep-debt` — sous-ensemble utile à l'Accueil
/// (`SleepDebt` côté Angular). Le reste de la réponse (`debtHours`,
/// `deficitNights`, `detail`…) sert d'autres écrans.
struct HomeSleepDebt: Decodable {
    let nights: Int
    let targetHours: Double
    let avgHours: Double
}

// MARK: - Nutrition du jour (gabarit « Cal. mangées » de « Depuis le réveil »)

struct HomeNutritionAmount: Decodable {
    let kcal: Double?
}

/// Entrée du journal alimentaire — seul le nombre d'entrées importe ici
/// (`entries.length > 0` côté Angular, pour décider si `totals` est
/// significatif) : struct vide, `Decodable` synthétisé ignore les clés en
/// trop sans erreur.
struct HomeIgnoredEntry: Decodable {}

/// `GET api/nutrition/day/:date`.
struct HomeNutritionDayResponse: Decodable {
    let entries: [HomeIgnoredEntry]
    let totals: HomeNutritionAmount
    let targets: HomeNutritionAmount
}

/// Sous-ensemble de `auto` dans `GET api/nutrition/targets` — `DayTarget`
/// côté Angular.
struct HomeDayTargetAuto: Decodable {
    let status: String
    let targetKcal: Double?
    let expenditureKcal: Double?
}

struct HomeNutritionTargetsResponse: Decodable {
    let auto: HomeDayTargetAuto
}

/// `GET api/wellness/days?limit=1` — un élément suffit à l'Accueil (retrouver
/// la dernière date connue quand le jour courant est vide).
struct HomeDaySummaryDate: Decodable {
    let date: String
}

// MARK: - Activités (semaine d'entraînement)

/// `GET api/activities` — mêmes champs que `Activity` côté Angular
/// (`web/src/app/core/api.types.ts`).
struct HomeActivity: Decodable {
    let id: Int
    let startTime: String?
    let durationS: Double?
}

struct HomeActivityListResponse: Decodable {
    let total: Int
    let items: [HomeActivity]
}

// MARK: - FC en direct (optionnel)

/// `GET/POST api/live/hr` — `LiveHeartRate` côté serveur
/// (`server/src/sync/sync.types.ts`).
struct HomeLiveHeartRate: Decodable {
    let reachable: Bool
    let detail: String?
    let enabled: Bool
    let broadcasting: Bool
    let heartRate: Int?
    let measuredAt: String?
    let stale: Bool
    let hint: String?
}

// MARK: - Intensité

enum IntensityGoalReason: String, Decodable {
    case seed
    case raised
    case lowered
    case light
    case held
    case pinned
    case skipped
}

struct IntensityDay: Decodable {
    let date: String
    let minutes: Double
    let cumulative: Double
}

/// `current` dans `IntensityReport` — semaine en cours, avec le rythme
/// (`pace`) et le détail jour par jour depuis lundi.
struct IntensityCurrentWeek: Decodable {
    let minutes: Double
    let goal: Double
    let light: Bool
    let reason: IntensityGoalReason
    let pace: Double
    let days: [IntensityDay]
}

/// `GET api/wellness/intensity` — seuls `today`/`current` sont utilisés par
/// l'Accueil (`history`/`params`/`next` servent d'autres écrans).
struct HomeIntensityReport: Decodable {
    let today: IntensityDay
    let current: IntensityCurrentWeek
}

// MARK: - Programme (semaine d'entraînement + séance)

struct HomeProgrammeResponse: Decodable {
    let domains: [HomeProgrammeDomain]
}

struct HomeProgrammeActive: Decodable {
    let week: Int
    let weeks: Int
}

/// Un item de séance (échauffement, série…) — `TrainingItem` côté Angular.
struct HomeTrainingItem: Decodable {
    let name: String
    let prescription: String
    let note: String?
}

struct HomeSessionInfo: Decodable {
    let name: String
    let minMinutes: Double?
    let items: [HomeTrainingItem]?
}

/// Une séance planifiée/faite du programme d'entraînement actif —
/// `ProgrammeSession` côté Angular.
struct HomeProgrammeSession: Decodable {
    let week: Int
    let session: HomeSessionInfo
    let plannedOn: String?
    let done: Bool
    let date: String?
}

struct HomeFocusItem: Decodable {
    let index: Int
    let focus: String?
}

/// Axe de régularité du coucher/lever — `SleepAxis` côté Angular
/// (`server/src/programme/sleep.ts`). `onsetMean`/`onsetSd` sont dans
/// l'« espace axe » du serveur (origine décalée de 12 h, cf. `axisMinute()`) :
/// pas des minutes d'horloge directes, `HomeViewModel.clockLabel` fait la
/// conversion à l'affichage — même règle côté Angular (`clockLabel()`).
struct HomeSleepAxis: Decodable {
    let onsetMean: Double
    let onsetSd: Double
    let wakeMean: Double
    let wakeSd: Double
}

/// Une nuit de la bande de régularité — `NightPoint` côté Angular.
struct HomeNightPoint: Decodable {
    let date: String
    let weekday: Int
    let workDay: Bool
    let onset: Double
    let wake: Double
    let sleepMin: Double
}

/// Détail du domaine — union des champs `training` (`TrainingDetail`) et
/// `sleep` (`SleepRegularity`) côté Angular : un seul domaine à la fois
/// remplit chaque sous-ensemble, le reste reste `nil` (même schéma que le
/// `Partial<…> & Partial<…>` TypeScript). `total`/`hits` ont un sens
/// différent selon le domaine consommateur (total de séances vs total de
/// critères de régularité notés) — comme côté Angular, un seul champ JSON
/// pour les deux, lu dans le bon contexte.
struct HomeProgrammeDetail: Decodable {
    // `training`
    let focus: [HomeFocusItem]?
    let sessions: [HomeProgrammeSession]?
    let done: Int?
    let missed: Int?
    // `sleep`
    let axis: HomeSleepAxis?
    let strip: [HomeNightPoint]?
    let nights: Int?
    let staleDays: Int?
    let to: String?
    // partagés (sens différent selon le domaine, cf. commentaire ci-dessus)
    let total: Int?
    let hits: Int?
}

/// Un domaine de programme (`training`, `sleep`, …) — l'Accueil ne s'intéresse
/// qu'à celui dont `kind == "training"`.
struct HomeProgrammeDomain: Decodable {
    let kind: String
    let active: HomeProgrammeActive?
    let detail: HomeProgrammeDetail?
}
