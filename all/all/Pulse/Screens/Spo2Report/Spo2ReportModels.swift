//
//  Spo2ReportModels.swift
//  all (bridge-connect)
//
//  Modèles `Codable` de l'écran Rapport SpO2 — miroir de la forme JSON
//  exposée par `GET api/wellness/spo2-report`
//  (`custom-connect/server/src/wellness/wellness.controller.ts`, interfaces
//  `Spo2Night`/`Spo2Report` ~ligne 57). Endpoint sans paramètre de requête :
//  il renvoie l'historique complet des nuits exploitables (filtrage/exclusion
//  déjà faits côté serveur, cf. `MIN_SPO2_COVERAGE_S`).
//
//  Dates : `date` est une chaîne calendaire `YYYY-MM-DD` (jamais `Date`),
//  `startTs`/`endTs`/`generatedAt`/`samples[].ts` sont des epoch secondes déjà
//  décalées côté serveur au fuseau d'affichage (`tzOffsetSeconds`) — donc
//  formatées côté écran en UTC pour retrouver l'heure locale, comme
//  `Screens/Health/HealthViewModel.swift`.
//
//  Convention : tous les types top-level (et sous-vues privées, cf.
//  `Spo2ReportView.swift`) sont préfixés `Spo2` pour éviter toute collision
//  de symboles avec les autres écrans compilés dans la même cible — même
//  raisonnement que `Screens/Nutrition/NutritionModels.swift`.
//

import Foundation

/// Un point `{ ts, value }` de la série SpO2 d'une nuit.
struct Spo2Sample: Codable {
    let ts: Int
    let value: Double
}

/// Une nuit exploitable (coverage ≥ `Spo2Report.minCoverageS`), avec ses
/// statistiques déjà calculées côté serveur (`WellnessController.spo2Report`).
struct Spo2Night: Codable, Identifiable {
    let date: String
    let startTs: Int
    let endTs: Int
    let sampleCount: Int
    let intervalS: Int
    let coverageS: Int
    let mean: Double
    let min: Double
    let p5: Double
    let median: Double
    let below90: Int
    let below88: Int
    let below85: Int
    let samples: [Spo2Sample]

    var id: String { date }
}

/// Réponse complète de `GET api/wellness/spo2-report`.
struct Spo2Report: Codable {
    let generatedAt: Int
    let nights: [Spo2Night]
    let excludedNights: Int
    let minCoverageS: Int
}
