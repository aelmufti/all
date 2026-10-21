//
//  NutritionProgrammeBalanceTests.swift
//  allTests
//
//  Bilan énergétique fixé par un programme alimentation (`weeklyWeightPct`) —
//  miroir des cas de `target.test.ts` / `catalogue.test.ts` (« bilan fixe par
//  le programme »).
//

import Testing
import Foundation
@testable import all

struct NutritionProgrammeBalanceTests {
    private let profile80 = NutritionEngineProfile(birthYear: 1996, sex: "male", weightKg: 80, heightCm: 180)
    private let watch = NutritionEngineWatchDay(restingKcal: 2341, activeKcal: 988)

    private func constraints(_ pct: Double?) -> ProgrammeEngineMacroConstraints {
        let none = ProgrammeEngineMacroBound(min: nil, max: nil)
        return ProgrammeEngineMacroConstraints(
            name: "Programme test", proteinPerKg: none, carbsPerKg: none, fatPerKg: none, fiberG: none,
            weeklyWeightPct: pct)
    }

    private func run(
        profile: NutritionEngineProfile? = nil, constraints: ProgrammeEngineMacroConstraints?
    ) -> NutritionEngineTargetResult {
        NutritionTargetEngine.computeDayTarget(
            date: "2026-08-05", profile: profile ?? profile80, watch: watch, sessions: [],
            settings: .defaults, constraints: constraints)
    }

    @Test func surplusRaisesTargetAboveExpenditure() {
        let r = run(constraints: constraints(0.25))
        #expect(r.balanceSource == "programme")
        #expect(r.expenditureKcal == 3329)
        #expect(r.targetKcal == 3549)
        #expect(r.deficitKcal == -220)
        #expect(r.plannedDeficitKcal == -220)
        #expect(r.weeklyLossKg == -0.2)
        #expect(r.guardStatus == "none")
        #expect(r.macros.bonuses.allSatisfy { $0.key != "deficit" })
        #expect(r.macros.proteinCutFloor == false)
    }

    @Test func maintenanceTargetEqualsExpenditure() {
        let r = run(constraints: constraints(0))
        #expect(r.balanceSource == "programme")
        #expect(r.targetKcal == r.expenditureKcal)
        #expect(r.deficitKcal == 0)
    }

    @Test func signedLossReplacesSettingsDeficit() {
        let r = run(constraints: constraints(-0.5))
        #expect(r.balanceSource == "programme")
        #expect(r.plannedDeficitKcal == 440)
        #expect(r.deficitKcal == 440)
    }

    @Test func missingFieldKeepsSettingsBehaviour() {
        let plain = run(constraints: nil)
        let framed = run(constraints: constraints(nil))
        #expect(plain.balanceSource == "settings")
        #expect(framed.balanceSource == "settings")
        #expect(framed.targetKcal == plain.targetKcal)
        #expect(framed.deficitKcal == plain.deficitKcal)
    }

    @Test func unknownWeightFallsBackToSettings() {
        let noWeight = NutritionEngineProfile(birthYear: 1996, sex: "male", weightKg: nil, heightCm: 180)
        let r = run(profile: noWeight, constraints: constraints(0.25))
        #expect(r.balanceSource == "settings")
        #expect(r.plannedDeficitKcal == NutritionEngineSettings.defaults.deficitKcal)
    }

    @Test func newNutritionProgrammesAreInCatalogue() {
        let maintain = ProgrammeCatalogue.programme(byId: "maintien-nutrition-acsm-2016")!
        #expect(maintain.kind == .nutrition)
        #expect(maintain.weeklyWeightPct == 0)
        #expect(maintain.rules.map(\.metric) == ["protein", "carbs", "fiber"])
        #expect(maintain.notes.count == 3)
        let lean = ProgrammeCatalogue.programme(byId: "masse-seche-nutrition-iraki-2019")!
        #expect(lean.weeklyWeightPct == 0.25)
        #expect(lean.rules.map(\.metric) == ["protein", "carbs", "fat", "fiber"])
        #expect(lean.rules[2].max == 1.5)
        #expect(ProgrammeCatalogue.programme(byId: "seche-nutrients-2021")!.weeklyWeightPct == nil)
        #expect(ProgrammeConstraintsEngine.macroConstraints(lean)?.weeklyWeightPct == 0.25)
    }
}
