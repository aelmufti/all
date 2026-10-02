//
//  SleepOptimumTests.swift
//  allTests
//
//  Valide le portage Swift de la durée idéale de sommeil
//  (`all/docs/duree-ideale-sommeil.md`, `Local/SleepOptimum.swift`).
//
//  Trois familles :
//  - PRNG (`mulberry32`/`fnv1a32`) contre des valeurs de référence calculées
//    EN LOCAL (`node`, aucun réseau) avec l'algorithme JS canonique cité par
//    la spec §8 — donc déjà la même arithmétique 32 bits que doit produire le
//    portage TS. Les uniformes (arithmétique entière pure) sont comparés EXACTEMENT ;
//    les normales (Box–Muller, `log`/`cos`) avec une tolérance `1e-9` (libm
//    peut différer d'un dernier bit entre plateformes).
//  - Comportements attendus du modèle sur données synthétiques (`n = 0`,
//    plateau, nuits courtes seulement) — eux aussi vérifiés contre une
//    réplique Node locale du même algorithme avant d'être figés ici.
//  - Fixture dorée partagée avec le port TS (`allTests/Fixtures/sleep-optimum.golden.json`,
//    pas encore produite au moment de ce commit) : lue via `#filePath`,
//    passage à vide (skip propre, comme `FitSamples.available`) si absente.
//

import Testing
import Foundation
@testable import all

struct SleepOptimumTests {
    // MARK: - PRNG : mulberry32

    /// Référence calculée en local (`node`, algorithme JS canonique) :
    /// `mulberry32(42)`, 5 premiers uniformes.
    @Test func mulberry32MatchesReferenceUniforms() {
        var rng = Mulberry32(seed: 42)
        let expected: [Double] = [
            0.6011037519201636, 0.44829055899754167, 0.8524657934904099,
            0.6697340414393693, 0.17481389874592423,
        ]
        for e in expected {
            #expect(rng.nextUniform() == e)
        }
    }

    /// Référence : `mulberry32(0x5EED0001)` (= `SEED_CI`, spec §6), 5 premiers
    /// uniformes.
    @Test func mulberry32MatchesReferenceUniformsForCISeed() {
        var rng = Mulberry32(seed: 0x5EED_0001)
        let expected: [Double] = [
            0.27013952494598925, 0.7382150527555496, 0.700461330357939,
            0.05320635414682329, 0.9139929655939341,
        ]
        for e in expected {
            #expect(rng.nextUniform() == e)
        }
    }

    /// Référence : `mulberry32(1)`, 5 premières normales (Box–Muller, spec §8).
    @Test func mulberry32MatchesReferenceNormals() {
        var rng = Mulberry32(seed: 1)
        let expected: [Double] = [
            1.4043387784152637, 1.2157546192705377, -0.5103768768108126,
            -0.2518183315501483, 1.0527919147074805,
        ]
        for e in expected {
            #expect(abs(rng.nextNormal() - e) < 1e-9)
        }
    }

    // MARK: - fnv1a32

    @Test func fnv1a32MatchesReferenceValues() {
        #expect(fnv1a32("") == 2_166_136_261)
        #expect(fnv1a32("a") == 3_826_002_220)
        #expect(fnv1a32("hello") == 1_335_831_723)
        #expect(fnv1a32("2026-10-02") == 1_652_370_116)
    }

    // MARK: - Modèle : `n = 0` → idéal a priori borné (spec §6)

    @Test func zeroNightsFallsBackToBoundedPriorIdeal() {
        let fit = SleepOptimumModel.fit(X: [], y: [])
        #expect(fit.n == 0)
        #expect(fit.basis == "prior")
        #expect(fit.idealHours == 7.75)
        #expect(fit.belowFloor == false)
    }

    // MARK: - `idealFromParams` : plateau à 6,5 h → brut ≈ 6,5 (+ sous plancher)

    /// Écarts locaux `d` construits pour que le gain plafonne à 6,5 h (`d_4,
    /// d_4.5, d_5, d_5.5, d_6` actifs à poids égal, nuls au-delà — nœuds
    /// v1.1, pas 0,5 h) ; amplitude `α = 0` pour isoler la contribution des
    /// écarts (vérifié contre la réplique Node locale de l'algorithme :
    /// `idealFromParams(0, [0.3×5, 0×7]) = 6.45`).
    @Test func idealFromParamsPlateauNear65Hours() {
        let d: [Double] = [0.3, 0.3, 0.3, 0.3, 0.3, 0, 0, 0, 0, 0, 0, 0]
        let idealRaw = SleepOptimumModel.idealFromParams(alpha: 0, d: d)
        #expect(abs(idealRaw - 6.5) < 0.1)
        #expect(idealRaw < 7) // sous le plancher — `belowFloor` serait vrai.
    }

    // MARK: - Nuits courtes SEULEMENT → idéal > 6 h (pas d'extrapolation, spec §0/§5)

    /// 60 nuits synthétiques, toutes dans `[5.5, 6.5]` h, avec une issue
    /// composite CORRÉLÉE à `S` dans cette plage (plus long va mieux, même
    /// dans l'intervalle observé) — malgré ce signal, le modèle ne peut pas
    /// conclure que 6 h suffit : au-delà de 6,5 h, aucune donnée, la courbe
    /// reste sur l'a priori (gains supplémentaires jusqu'à 9 h). Résultat
    /// attendu (réplique Node locale) : `idealRaw ≈ 8.35` — très au-dessus de
    /// 6 h, la régression de confiance ici est `> 6`.
    @Test func shortNightsOnlyDoesNotCollapseIdealBelow6Hours() {
        var nights: [SleepOptimumNightInput] = []
        for i in 0..<60 {
            let s = 5.5 + Double(i % 11) * 0.1
            let y = (s - 6.0) * 2
            // Composite Y directement fourni via `bbMorning` seul ne suffit
            // pas (§3.3 exige ≥ 2 issues présentes) — on duplique le même
            // signal sur `bbMorning`/`bbEvening` pour que la nuit soit retenue.
            nights.append(SleepOptimumNightInput(date: "2026-01-\(String(format: "%02d", (i % 28) + 1))", S: s, bbMorning: y, bbEvening: y))
        }
        let built = SleepOptimumFeatures.build(nights: nights)
        let fit = SleepOptimumModel.fit(X: built.X, y: built.y)
        #expect(fit.idealRaw > 6)
    }

    // MARK: - Fixture dorée partagée (spec §8)

    private struct GoldenNight: Decodable {
        let date: String
        let S: Double
        let bbMorning: Double?
        let bbEvening: Double?
        let wakeStress: Double?
        let bbBed: Double?
        let stressPrevDay: Double?
        let sportPrev: Double?
        let sportNext: Double?
        let workdayNext: Double?
        let onsetShift: Double?
        let priorSleep: Double?
    }

    /// Le JSON de référence niche les sorties du modèle sous `expected.optimum`
    /// (et `expected.targetHours` pour la reco du soir, §7) — on décode la forme
    /// réelle telle quelle (spec §8 : fixture copiée sans retouche).
    private struct GoldenOptimum: Decodable {
        let idealHours: Double
        let idealLowHours: Double
        let idealHighHours: Double
        let idealRaw: Double
        let lowRaw: Double
        let highRaw: Double
        let belowFloor: Bool
        let modelNights: Int
        let basis: String
        let trial: Bool
    }

    private struct GoldenExpected: Decodable {
        let optimum: GoldenOptimum
        let targetHours: Double
    }

    private struct GoldenFixture: Decodable {
        let nights: [GoldenNight]
        let todayKey: String
        let expected: GoldenExpected
    }

    /// Lue via `#filePath` (même patron que `FitSamples.swift`), pas une
    /// ressource bundle. Produite par l'agent TS
    /// (`custom-connect/server/src/stats/__fixtures__/sleep-optimum.golden.json`)
    /// puis copiée ici — absente au moment de ce commit : passage à vide
    /// (skip propre) plutôt qu'un échec.
    private static var fixturePath: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sleep-optimum.golden.json")
    }

    @Test func goldenFixtureMatchesTSReferenceWhenPresent() throws {
        guard let data = try? Data(contentsOf: Self.fixturePath) else {
            return // fixture pas encore livrée côté TS — skip propre.
        }
        let fixture = try JSONDecoder().decode(GoldenFixture.self, from: data)

        let inputs = fixture.nights.map { n in
            SleepOptimumNightInput(
                date: n.date, S: n.S, bbMorning: n.bbMorning, bbEvening: n.bbEvening, wakeStress: n.wakeStress,
                bbBed: n.bbBed, stressPrevDay: n.stressPrevDay, sportPrev: n.sportPrev, sportNext: n.sportNext,
                workdayNext: n.workdayNext, onsetShift: n.onsetShift, priorSleep: n.priorSleep)
        }
        let built = SleepOptimumFeatures.build(nights: inputs)
        let fit = SleepOptimumModel.fit(X: built.X, y: built.y)

        let expected = fixture.expected.optimum
        #expect(fit.idealHours == expected.idealHours)
        #expect(fit.idealLowHours == expected.idealLowHours)
        #expect(fit.idealHighHours == expected.idealHighHours)
        #expect(abs(fit.idealRaw - expected.idealRaw) < 1e-6)
        #expect(abs(fit.lowRaw - expected.lowRaw) < 1e-6)
        #expect(abs(fit.highRaw - expected.highRaw) < 1e-6)
        #expect(fit.belowFloor == expected.belowFloor)
        #expect(fit.n == expected.modelNights)
        #expect(fit.basis == expected.basis)
    }
}
