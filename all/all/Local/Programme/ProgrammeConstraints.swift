//
//  ProgrammeConstraints.swift
//  all (bridge-connect)
//
//  Portage Swift de `custom-connect/server/src/programme/constraints.ts`
//  (`macroConstraints`) — incrément L7a (`docs/stockage-local.md`).
//
//  NON câblé dans cet incrément : `macroConstraints` sert côté serveur
//  UNIQUEMENT à `NutritionController` (`nutrition.controller.ts`,
//  `activeConstraints`/`programmeFor`, `import { macroConstraints } from
//  '../programme/constraints'`) pour recadrer les cibles de la page Nutrition
//  sur un programme alimentaire actif — PAS à `GET api/programme`
//  (`programme.controller.ts` n'importe jamais `./constraints`, vérifié dans
//  la source). Porté ici pour fidélité à la consigne de l'incrément (lire/
//  porter `catalogue.ts`/`progress.ts`/`sleep.ts`/`constraints.ts`), prêt pour
//  un futur incrément qui câblerait `nutrition/day/:date`/`nutrition/targets`
//  sur un programme actif — même décision déjà assumée côté
//  `Local/NutritionTarget.swift` (moteur PROGRAMME non câblé, cf. son
//  en-tête). Ni appelé ni testé dans le périmètre de cet incrément.
//

import Foundation

struct ProgrammeEngineMacroBound {
    let min: Double?
    let max: Double?
}

struct ProgrammeEngineMacroConstraints {
    let name: String
    let proteinPerKg: ProgrammeEngineMacroBound
    let carbsPerKg: ProgrammeEngineMacroBound
    let fatPerKg: ProgrammeEngineMacroBound
    let fiberG: ProgrammeEngineMacroBound
}

enum ProgrammeConstraintsEngine {
    private static let empty = ProgrammeEngineMacroBound(min: nil, max: nil)

    private static func bound(_ programme: ProgrammeEngineProgramme, metric: String, perKg: Bool) -> ProgrammeEngineMacroBound {
        guard let rule = programme.rules.first(where: { $0.metric == metric && $0.perKg == perKg }) else { return empty }
        return ProgrammeEngineMacroBound(min: rule.min, max: rule.max)
    }

    /// Miroir de `macroConstraints` (TS) — `nil` si le programme n'est pas
    /// `nutrition` ou si aucune règle ne pose de borne.
    static func macroConstraints(_ programme: ProgrammeEngineProgramme) -> ProgrammeEngineMacroConstraints? {
        guard programme.kind == .nutrition else { return nil }
        let constraints = ProgrammeEngineMacroConstraints(
            name: programme.name,
            proteinPerKg: bound(programme, metric: "protein", perKg: true),
            carbsPerKg: bound(programme, metric: "carbs", perKg: true),
            fatPerKg: bound(programme, metric: "fat", perKg: true),
            fiberG: bound(programme, metric: "fiber", perKg: false))
        let bounds = [constraints.proteinPerKg, constraints.carbsPerKg, constraints.fatPerKg, constraints.fiberG]
        return bounds.contains(where: { $0.min != nil || $0.max != nil }) ? constraints : nil
    }
}
