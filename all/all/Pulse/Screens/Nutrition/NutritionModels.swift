//
//  NutritionModels.swift
//  all (bridge-connect)
//
//  Modèles `Codable` de l'écran Nutrition — miroir de la forme JSON exposée
//  par `custom-connect/server/src/nutrition/nutrition.controller.ts` (et
//  `target.ts` pour le détail de l'objectif automatique). Les dates sont
//  toujours des chaînes calendaires `YYYY-MM-DD` (jamais `Date`, cf. le
//  commentaire de `PulseAPIClient.decoder`) ; les horodatages de repas sont
//  des epoch secondes Unix (`Int`).
//
//  Convention : tous les types sont préfixés `Nutrition` pour éviter toute
//  collision de symboles avec les autres écrans compilés dans la même
//  cible (`Screens/Home`, `Screens/Health`…) — Swift compile tout le module
//  d'un coup, les noms génériques comme `Entry` ou `Macros` s'y prêteraient
//  mal.
//
//  Champs volontairement omis (présents côté serveur mais non consommés par
//  cet écran, donc absents des structs ci-dessous — `Decodable` ignore les
//  clés JSON en trop) : détail de calcul de l'objectif (`detail.sessions`,
//  bonus de protéines, plan de macros du programme…), réglages bruts
//  (`settings`), historique de dates (`history`), recherche/scan/aliments
//  (`foods`, `search`, `barcode`) — cf. rendu final pour la justification.
//

import Foundation

// MARK: - Blocs partagés

/// Groupe de 5 macros optionnelles — sert à la fois pour `totals` (toujours
/// renseigné côté serveur, jamais `null` en pratique), `targets` et
/// `remaining` (peuvent être `null` si aucune cible n'est calculable).
struct NutritionMacros: Codable {
    let kcal: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let fiber: Double?
}

/// Fourchette min/max d'une macro (cadre de programme ou cibles manuelles
/// min/max) — `targetRanges` dans `day/:date`.
struct NutritionMacroRange: Codable {
    let min: Double?
    let max: Double?
}

struct NutritionProgrammeRef: Codable {
    let name: String
}

// MARK: - `GET api/nutrition/day/:date`

struct NutritionEntry: Codable, Identifiable {
    let id: Int
    let name: String
    let grams: Double
    let kcal: Double?
    let protein: Double?
    let carbs: Double?
    let fiber: Double?
    let fat: Double?
    let unitLabel: String?
    let unitQty: Double?
    /// Epoch secondes Unix, `nil` si l'heure n'a pas été saisie.
    let ts: Int?
}

struct NutritionDay: Codable {
    let date: String
    let entries: [NutritionEntry]
    let totals: NutritionMacros
    let targets: NutritionMacros
    let targetRanges: [String: NutritionMacroRange]?
    let programme: NutritionProgrammeRef?
    let remaining: NutritionMacros
    let proteinPerKg: Double?
}

// MARK: - `GET api/nutrition/targets`

struct NutritionAutoDetail: Codable {
    let restingKcal: Double?
    let activeKcal: Double?
}

struct NutritionMacroProgrammePlan: Codable {
    let name: String
    let unmet: [String]
}

struct NutritionMacroPlan: Codable {
    let proteinG: Double?
    let fatG: Double?
    let carbsG: Double?
    let fiberG: Double?
    let proteinPerKg: Double?
    let programme: NutritionMacroProgrammePlan?
}

/// Sous-arbre `auto` de la réponse `targets` — calcul automatique de
/// l'objectif du jour (`computeDayTarget` côté serveur, cf. `target.ts`).
struct NutritionAutoTarget: Codable {
    /// `"ok"` (calcul possible) ou `"unavailable"` (profil incomplet).
    let status: String
    /// `"watch"` | `"watch-sessions"` | `"formula"`.
    let source: String
    /// Champs de profil manquants (`birthYear`, `sex`, `weightKg`, `heightCm`).
    let missing: [String]
    let targetKcal: Double?
    let expenditureKcal: Double?
    let deficitKcal: Double?
    let macros: NutritionMacroPlan
    /// `"none"` | `"availability"` | `"resting"` | `"absolute"` — plancher
    /// qui a relevé l'objectif, si applicable. Nommé `guardStatus` côté
    /// Swift, `guard` étant un mot réservé.
    let guardStatus: String
    let detail: NutritionAutoDetail

    enum CodingKeys: String, CodingKey {
        case status, source, missing, targetKcal, expenditureKcal, deficitKcal, macros, detail
        case guardStatus = "guard"
    }
}

struct NutritionTargetInfo: Codable {
    /// `"auto"` ou `"manual"` — réglage de `settings > Synchronisation`.
    let mode: String
    /// Cibles effectivement retenues (auto si `mode == "auto"` et calcul
    /// possible, sinon les valeurs manuelles) — mêmes clés que `NutritionMacros`.
    let targets: NutritionMacros
    /// `"auto"` ou `"manual"` — origine réelle de `targets` (peut différer de
    /// `mode` si le calcul auto est indisponible).
    let source: String
    let auto: NutritionAutoTarget
}

// MARK: - `GET api/nutrition/weekly`

struct NutritionWeekly: Codable {
    let loggedDays: Int
    let partialDays: Int
    let emptyDays: Int
    let avgDeficitKcal: Double?
    let alert: Bool
    let thresholdKcal: Double
}

// MARK: - `GET api/nutrition/timing/:date`

struct NutritionMealTiming: Codable {
    let lastMealTs: Int
    let digestionEndTs: Int
    let nextMealTs: Int
    let avgStress: Int?
    let windowH: Double
}

struct NutritionTimingResponse: Codable {
    let meal: NutritionMealTiming?
}

// MARK: - `GET api/nutrition/suggestions/:date`

/// Idée d'aliment pour finir la journée — `grams`/`kcal`/`protein`/`carbs`/
/// `fiber` sont déjà la quantité **absolue** pour la portion suggérée (pas du
/// pour-100 g), cf. `NutritionController.suggestions`.
struct NutritionSuggestionItem: Codable, Identifiable {
    let foodId: Int
    let name: String
    let grams: Double
    let units: Double?
    let unitLabel: String?
    let unitGrams: Double?
    let kcal: Double
    let protein: Double
    let carbs: Double
    let fiber: Double

    var id: Int { foodId }
}

struct NutritionSuggestionsResponse: Codable {
    let remaining: NutritionMacros
    let items: [NutritionSuggestionItem]
    let reason: String?
}

// MARK: - `GET api/nutrition/frequent`

/// Aliment fréquent — `kcal`/`protein`/`carbs`/`fiber`/`fat` sont ici des
/// valeurs **pour 100 g** (médiane/dernière valeur connue), contrairement à
/// `NutritionSuggestionItem`. C'est ce que réutilise `POST log` pour mettre
/// à l'échelle sur la portion choisie.
struct NutritionFrequentFood: Codable, Identifiable {
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

    var id: String { foodId.map(String.init) ?? name }
}

// MARK: - `POST/DELETE api/nutrition/log`

/// Corps de `POST api/nutrition/log` — reflète `LogBody` côté serveur. Si
/// `foodId` est renseigné et correspond à un aliment connu, le serveur
/// recalcule lui-même les macros à partir de la fiche produit et ignore
/// `kcal`/`protein`/`carbs`/`fiber`/`fat` du corps ; ceux-ci ne servent donc
/// que de repli (aliment fréquent sans `foodId`, ex. saisie manuelle passée).
struct NutritionLogRequest: Encodable {
    var date: String
    var name: String
    var foodId: Int?
    var grams: Double?
    var units: Double?
    var unitLabel: String?
    var unitGrams: Double?
    var kcal: Double?
    var protein: Double?
    var carbs: Double?
    var fiber: Double?
    var fat: Double?
    var ts: Int?
}

struct NutritionLogResponse: Decodable {
    let id: Int
}
