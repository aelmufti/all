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

struct HomeDaySummary: Decodable {
    let restingHr: Int?
}

/// `GET api/wellness/day/:date` — sous-ensemble utile à l'Accueil (FC, stress,
/// SpO2, respiration + FC de repos). Le sommeil/les pas/calories vivent sur
/// l'écran Santé, pas ici.
struct HomeDayDetail: Decodable {
    let date: String
    let summary: HomeDaySummary
    let hr: [HomeSample]
    let stress: [HomeSample]
    let spo2: [HomeSample]
    let respiration: [HomeSample]

    /// Miroir de `hasData()` côté Angular (`home.component.ts`) : un jour
    /// « vide » (aucune FC/stress) déclenche le repli sur le dernier jour
    /// connu plutôt que d'afficher une page blanche.
    var hasData: Bool {
        !hr.isEmpty || !stress.isEmpty
    }
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

/// Détail du domaine — n'expose que les champs du domaine `training`
/// (`TrainingDetail` côté Angular). Le domaine `sleep` (axe/bandes de
/// régularité) n'est pas consommé ici : hors périmètre Accueil.
struct HomeProgrammeDetail: Decodable {
    let focus: [HomeFocusItem]?
    let sessions: [HomeProgrammeSession]?
    let done: Int?
    let total: Int?
    let missed: Int?
}

/// Un domaine de programme (`training`, `sleep`, …) — l'Accueil ne s'intéresse
/// qu'à celui dont `kind == "training"`.
struct HomeProgrammeDomain: Decodable {
    let kind: String
    let active: HomeProgrammeActive?
    let detail: HomeProgrammeDetail?
}
