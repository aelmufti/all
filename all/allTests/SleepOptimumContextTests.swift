//
//  SleepOptimumContextTests.swift
//  allTests
//
//  Couche contextuelle de la durée idéale (v1.2, `docs/duree-ideale-sommeil.md`
//  §10, `Local/SleepOptimumContext.swift`) + ce qui l'entoure : lever habituel
//  par type de jour, contrat de l'endpoint local (`date`, cache), décodage du
//  DTO, heure de coucher par date (`SleepBedtimePlan`), sélecteur de date
//  (`SommeilDatePicking`) et borne `maxReachableDate`. Données SYNTHÉTIQUES
//  uniquement.
//

import Testing
import Foundation
@testable import all

// MARK: - Données synthétiques

private enum Synth {
    /// 2026-10-05 est un lundi.
    static func dayStart(_ date: String) -> Double { DashboardStatsTime.dayStartUnixUTC(date) }

    /// `count` nuits où le sport de la veille (`sportPrev` ∈ {0, 90} min) décide
    /// de la courbe vraie : sans sport le gain plafonne à 7 h, avec sport à 9 h.
    /// Issue composite fournie par `bbMorning`/`bbEvening` (même signal).
    static func sportNights(count: Int, seed: UInt32 = 7) -> [SleepOptimumNightInput] {
        var rng = Mulberry32(seed: seed)
        var out: [SleepOptimumNightInput] = []
        for i in 0..<count {
            let s = 5.5 + 4 * rng.nextUniform()
            let sport: Double = rng.nextUniform() < 0.5 ? 90 : 0
            let plateau = sport > 0 ? 9.0 : 7.0
            let y = min(s, plateau) + 0.1 * rng.nextNormal()
            out.append(SleepOptimumNightInput(
                date: String(format: "2026-%02d-%02d", 1 + i / 28, 1 + i % 28), S: s,
                bbMorning: y, bbEvening: y, sportPrev: sport))
        }
        return out
    }

    static func fits(_ nights: [SleepOptimumNightInput]) -> (built: SleepOptimumFeatures.Built, fit: SleepOptimumModel.Fit, ctx: SleepOptimumContext.Model) {
        let built = SleepOptimumFeatures.build(nights: nights)
        let fit = SleepOptimumModel.fit(X: built.X, y: built.y)
        return (built, fit, SleepOptimumContext.fit(built: built, globalFit: fit))
    }

    static func recoNight(_ date: String, wakeHour: Double, offsetS: Double = 0) -> SleepRecommendationLocal.RecoNight {
        let endTs = dayStart(date) + wakeHour * 3600 - offsetS
        return SleepRecommendationLocal.RecoNight(
            date: date, startTs: endTs - 8 * 3600, endTs: endTs,
            deepS: 4 * 3600, lightS: 3 * 3600, remS: 3600, awakeS: 0, offsetS: offsetS)
    }
}

// MARK: - Idéal contextuel

struct SleepOptimumContextTests {
    @Test func builtExposesTheStatsUsedForZScoring() {
        let nights = Synth.sportNights(count: 40)
        let built = SleepOptimumFeatures.build(nights: nights)
        #expect(built.covariateStats.count == 7)
        // Colonne `sportPrev` (rang 2, colonne 14 + 2) == z-score avec les stats exposées.
        for (row, night) in zip(built.X, built.nightsUsed) {
            #expect(abs(row[16] - built.covariateStats[2].z(night.sportPrev)) < 1e-12)
        }
        // Covariable absente partout → écart-type nul → z = 0.
        #expect(built.covariateStats[0].sd == 0)
        #expect(built.covariateStats[0].z(55) == 0)
    }

    @Test func contextualIdealEqualsGlobalWithNoNights() {
        let (_, fit, ctx) = Synth.fits([])
        #expect(ctx.n == 0)
        let ideal = SleepOptimumContext.nightIdealHours(model: ctx, covariates: .init(sportPrev: 90))
        #expect(ideal == fit.idealHours)
    }

    @Test func contextualIdealEqualsGlobalUnder30Nights() {
        let (_, fit, ctx) = Synth.fits(Synth.sportNights(count: 29))
        #expect(ctx.n == 29)
        #expect(SleepOptimumContext.nightIdealHours(model: ctx, covariates: .init(sportPrev: 90)) == fit.idealHours)
        #expect(SleepOptimumContext.nightIdealHours(model: ctx, covariates: .init(sportPrev: 0)) == fit.idealHours)
    }

    @Test func contextualIdealEqualsGlobalWhenAllCovariatesAbsent() {
        let (_, fit, ctx) = Synth.fits(Synth.sportNights(count: 120))
        #expect(ctx.n >= SleepOptimumContext.minNights)
        #expect(SleepOptimumContext.nightIdealHours(model: ctx, covariates: .init()) == fit.idealHours)
    }

    /// Données où le sport de la veille décale vraiment l'optimum (7 h sans,
    /// 9 h avec) : l'idéal de la nuit doit bouger dans le bon sens, rester à
    /// ± 1 h de l'idéal brut global et sur une grille de 5 minutes.
    @Test func highSportContextMovesIdealUpAndLowSportDown() {
        let (_, fit, ctx) = Synth.fits(Synth.sportNights(count: 150))
        let high = SleepOptimumContext.nightIdealHours(model: ctx, covariates: .init(sportPrev: 90))
        let low = SleepOptimumContext.nightIdealHours(model: ctx, covariates: .init(sportPrev: 0))
        #expect(high > low)
        #expect(high - low >= 0.25) // décalage réel, pas un artefact d'arrondi
        for v in [high, low] {
            #expect(v >= 7 && v <= 9.5)
            #expect(abs(v - fit.idealRaw) <= 1 + 1e-9 || v == 7 || v == 9.5)
            #expect(abs(v * 12 - (v * 12).rounded()) < 1e-9) // multiple de 5 min
        }
        #expect(ctx.gamma[2] > 0) // γ_sportPrev positif : plus de sport → plus de gain avec la durée
    }

    private func model(
        gamma: Double, globalRaw: Double, d: [Double] = Array(repeating: 0, count: 12)
    ) -> SleepOptimumContext.Model {
        SleepOptimumContext.Model(
            n: 100, alpha: 1, d: d, gamma: [gamma, 0, 0, 0],
            stats: Array(repeating: SleepOptimumFeatures.CovariateStat(mean: 0, sd: 1), count: 4),
            globalIdealRaw: globalRaw, globalIdealHours: SleepOptimumModel.round025(SleepOptimumModel.clampHours(globalRaw)))
    }

    @Test func idealIsBoundedToPlusOrMinusOneHourAroundGlobalRaw() {
        // γ énorme → idéal brut ≈ 10 h ; borné à globalRaw + 1 = 9,0 h.
        let up = SleepOptimumContext.nightIdealHours(model: model(gamma: 5, globalRaw: 8.0), covariates: .init(bbBed: 3))
        #expect(up == SleepOptimumContext.round5min(9.0))
        // γ très négatif → idéal brut 5 h ; borné à globalRaw − 1 = 7,2 h, arrondi à 5 min.
        let down = SleepOptimumContext.nightIdealHours(model: model(gamma: -5, globalRaw: 8.2), covariates: .init(bbBed: 3))
        #expect(abs(down - 7.2) <= 1.0 / 24 + 1e-9)
        #expect(abs(down * 12 - (down * 12).rounded()) < 1e-9)
    }

    @Test func idealIsClampedTo7And95AfterTheBand() {
        // Gain concentré sur 9-10 h (écarts d_9, d_9.5 forts) → idéal brut ≈ 9,9 ; globalRaw 9,0 →
        // bande jusqu'à 10 → plafonné à 9,5.
        var d = Array(repeating: 0.0, count: 12)
        d[10] = 3; d[11] = 3
        let top = SleepOptimumContext.nightIdealHours(model: model(gamma: 0, globalRaw: 9.0, d: d), covariates: .init(bbBed: 3))
        #expect(top == 9.5)
        // globalRaw 7,5 → bande jusqu'à 6,5 → plancher 7.
        let floor = SleepOptimumContext.nightIdealHours(model: model(gamma: -5, globalRaw: 7.5), covariates: .init(bbBed: 3))
        #expect(floor == 7)
    }

    // MARK: - Covariables d'une nuit à venir

    private let onsetRef = Synth.dayStart("2026-10-05") + 23 * 3600 // lundi 23:00 UTC

    @Test func upcomingCovariatesUseSpecWindows() {
        // bb : un échantillon trop ancien (−90 min), deux dans l'heure : le dernier gagne.
        let bb = [
            SleepRecommendationLocal.Sample(ts: onsetRef - 5400, value: 10),
            SleepRecommendationLocal.Sample(ts: onsetRef - 3000, value: 40),
            SleepRecommendationLocal.Sample(ts: onsetRef - 600, value: 55),
            SleepRecommendationLocal.Sample(ts: onsetRef + 600, value: 99), // futur : exclu
        ]
        // stress : 60 échantillons à 30 dans la fenêtre, un hors fenêtre à 100.
        var stress = (0..<60).map { SleepRecommendationLocal.Sample(ts: onsetRef - 14 * 3600 + Double($0) * 60 + 1, value: 30) }
        stress.append(SleepRecommendationLocal.Sample(ts: onsetRef - 600, value: 100)) // < 30 min avant : exclu
        let activities = [
            SleepRecommendationLocal.ActivityWindow(startTs: onsetRef - 25 * 3600, durationMin: 500), // trop ancien
            SleepRecommendationLocal.ActivityWindow(startTs: onsetRef - 3 * 3600, durationMin: 40),
            SleepRecommendationLocal.ActivityWindow(startTs: onsetRef - 20 * 3600, durationMin: 20),
        ]
        let covs = SleepOptimumContext.upcomingNightCovariates(
            date: "2026-10-06", onsetRef: onsetRef, bbSamples: bb, stressSamples: stress,
            activities: activities, sleepByDate: ["2026-10-05": 8, "2026-10-04": 6])
        #expect(covs.bbBed == 55)
        #expect(covs.stressPrevDay == 30)
        #expect(covs.sportPrev == 60)
        // priorSleep : (1·8 + 0,5·6) / 1,5 = 7,333…
        #expect(abs((covs.priorSleep ?? 0) - 11.0 / 1.5) < 1e-9)
    }

    @Test func upcomingCovariatesAbsentWhenNoDataOrTooFewStressSamples() {
        let stress = (0..<59).map { SleepRecommendationLocal.Sample(ts: onsetRef - 14 * 3600 + Double($0) * 60 + 1, value: 30) }
        let covs = SleepOptimumContext.upcomingNightCovariates(
            date: "2026-10-06", onsetRef: onsetRef, bbSamples: [], stressSamples: stress,
            activities: [], sleepByDate: [:])
        #expect(covs.bbBed == nil)
        #expect(covs.stressPrevDay == nil) // 59 < 60
        #expect(covs.sportPrev == 0) // jamais nil
        #expect(covs.priorSleep == nil)
        #expect(!covs.allAbsent) // sportPrev = 0 est une valeur présente
    }

    @Test func onsetReferenceIsMinOfNowAndHabitualOnset() {
        // Endormissement habituel 23:30 local, UTC : nuit qui finit le 2026-10-06 → 2026-10-05 23:30.
        let habitual = Synth.dayStart("2026-10-05") + 23.5 * 3600
        #expect(SleepOptimumContext.onsetReference(
            date: "2026-10-06", nowS: habitual + 7200, habitualOnsetMin: 1410, offsetS: 0) == habitual)
        #expect(SleepOptimumContext.onsetReference(
            date: "2026-10-06", nowS: habitual - 3600, habitualOnsetMin: 1410, offsetS: 0) == habitual - 3600)
        // Sans endormissement habituel : maintenant.
        #expect(SleepOptimumContext.onsetReference(date: "2026-10-06", nowS: 1234, habitualOnsetMin: nil, offsetS: 0) == 1234)
    }

    @Test func onsetReferenceHandlesAfterMidnightOnsetAndTimezone() {
        // Coucher habituel 01:00 local (après minuit) : tombe le 2026-10-06 à 01:00 local.
        let far = Synth.dayStart("2026-10-10")
        let utc = SleepOptimumContext.onsetReference(date: "2026-10-06", nowS: far, habitualOnsetMin: 60, offsetS: 0)
        #expect(utc == Synth.dayStart("2026-10-06") + 3600)
        // UTC+2 : le même 01:00 LOCAL est 23:00 UTC la veille.
        let plus2 = SleepOptimumContext.onsetReference(date: "2026-10-06", nowS: far, habitualOnsetMin: 60, offsetS: 7200)
        #expect(plus2 == Synth.dayStart("2026-10-06") + 3600 - 7200)
    }

    @Test func habitualOnsetIsMedianOfLast7RecenteredOnsets() {
        // 8 nuits : la plus ancienne (coucher 10:00, aberrante) sort de la fenêtre de 7.
        var nights: [SleepRecommendationLocal.ModelRawNight] = []
        for i in 0..<8 {
            let startTs = Synth.dayStart("2026-09-2\(i)") + (i == 0 ? 10 : 23.5) * 3600
            nights.append(.init(date: "2026-09-2\(i + 1)", startTs: startTs, endTs: startTs + 8 * 3600, S: 7.5, offsetS: 0))
        }
        #expect(SleepOptimumContext.habitualOnsetMin(nights: nights) == 1410)
        #expect(SleepOptimumContext.habitualOnsetMin(nights: []) == nil)
    }

    // MARK: - Lever habituel par type de jour

    @Test func wakeMedianByDayTypeSplitsWeekdaysAndWeekend() {
        // 2026-10-05 lundi … 2026-10-11 dimanche, + 2026-10-12 lundi.
        let workdays = ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09"].enumerated()
            .map { Synth.recoNight($1, wakeHour: $0 == 4 ? 8 : 7) } // médiane 7:00
        let weekend = ["2026-10-10", "2026-10-11", "2026-10-17"].map { Synth.recoNight($0, wakeHour: 9.5) }
        let r = SleepRecommendationLocal.wakeMedianByDayType(workdays + weekend)
        #expect(r.workday == 420)
        #expect(r.freeDay == 570)
    }

    @Test func wakeMedianByDayTypeNeedsThreeNightsOfEachType() {
        let nights = [
            Synth.recoNight("2026-10-05", wakeHour: 7), Synth.recoNight("2026-10-06", wakeHour: 7),
            Synth.recoNight("2026-10-07", wakeHour: 7), // 3 jours de semaine
            Synth.recoNight("2026-10-10", wakeHour: 10), Synth.recoNight("2026-10-11", wakeHour: 10), // 2 week-end
        ]
        let r = SleepRecommendationLocal.wakeMedianByDayType(nights)
        #expect(r.workday == 420)
        #expect(r.freeDay == nil)
    }

    @Test func wakeMedianByDayTypeUsesLocalWakeDay() {
        // Réveil local dimanche 23:30 (UTC−1) = lundi 00:30 UTC : le jour LOCAL (dimanche) compte.
        let n = (0..<3).map { _ in Synth.recoNight("2026-10-04", wakeHour: 23.5, offsetS: -3600) }
        #expect(n[0].endTs == Synth.dayStart("2026-10-05") + 0.5 * 3600) // bien lundi 00:30 en UTC
        let r = SleepRecommendationLocal.wakeMedianByDayType(n)
        #expect(r.workday == nil)
        #expect(r.freeDay == 1410) // 23:30
    }

    @Test func computeSleepRecommendationExposesDayTypeWakeTimes() {
        let nights = ["2026-10-05", "2026-10-06", "2026-10-07"].map { Synth.recoNight($0, wakeHour: 6.5) }
        let fit = SleepOptimumModel.fit(X: [], y: [])
        guard case .ok(let ok) = SleepRecommendationLocal.computeSleepRecommendation(nights: nights, fit: fit, todayKey: "2026-10-08") else {
            Issue.record("attendu .ok"); return
        }
        #expect(ok.waketime == "06:30")
        #expect(ok.waketimeWorkday == "06:30")
        #expect(ok.waketimeFreeDay == nil)
    }
}

// MARK: - Fixture dorée de la couche contextuelle (parité TS ↔ Swift)

/// `custom-connect/server/src/stats/__fixtures__/sleep-optimum-context.golden.json`,
/// générée par le port TS (`sleep-optimum-context.ts`) sur des entrées SYNTHÉTIQUES
/// puis copiée dans `allTests/Fixtures/`. Même patron que le test doré du modèle
/// global (`SleepOptimumTests.goldenFixtureMatchesTSReferenceWhenPresent`).
struct SleepOptimumContextGoldenTests {
    private struct Night: Decodable {
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

        var input: SleepOptimumNightInput {
            SleepOptimumNightInput(
                date: date, S: S, bbMorning: bbMorning, bbEvening: bbEvening, wakeStress: wakeStress,
                bbBed: bbBed, stressPrevDay: stressPrevDay, sportPrev: sportPrev, sportNext: sportNext,
                workdayNext: workdayNext, onsetShift: onsetShift, priorSleep: priorSleep)
        }
    }

    private struct Covs: Decodable {
        let bbBed: Double?
        let stressPrevDay: Double?
        let sportPrev: Double?
        let priorSleep: Double?

        var value: SleepOptimumContext.Covariates {
            SleepOptimumContext.Covariates(
                bbBed: bbBed, stressPrevDay: stressPrevDay, sportPrev: sportPrev, priorSleep: priorSleep)
        }
    }

    private struct Stat: Decodable { let mean: Double; let sd: Double }

    private struct ContextExpectation: Decodable {
        let name: String
        let covariates: Covs
        let z: [Double]
        let idealRaw: Double
        let idealHours: Double
    }

    private struct FitExpectation: Decodable {
        let n: Int
        let alpha: Double
        let d: [Double]
        let gamma: [Double]
        let stats: [Stat]
        let globalIdealRaw: Double
        let globalIdealHours: Double
        let contexts: [ContextExpectation]
    }

    private struct FitCase: Decodable {
        let name: String
        let todayKey: String
        let nights: [Night]
        let expected: FitExpectation
    }

    private struct Sample: Decodable { let ts: Double; let value: Double }
    private struct Activity: Decodable { let startTs: Double; let durationS: Double? }
    private struct HabitualNight: Decodable { let startTs: Double; let offsetS: Double }

    private struct UpcomingExpectation: Decodable {
        let onsetRef: Double
        let covariates: Covs
        let nightIdealHours: Double
    }

    private struct UpcomingCase: Decodable {
        let name: String
        let nowS: Double
        let bbSamples: [Sample]
        let stressSamples: [Sample]
        let activities: [Activity]
        let expected: UpcomingExpectation
    }

    private struct Upcoming: Decodable {
        let date: String
        let offsetS: Double
        let sleepByDate: [String: Double]
        let habitualNights: [HabitualNight]
        let expectedHabitualOnsetMin: Double
        let modelCase: String
        let cases: [UpcomingCase]
    }

    private struct Fixture: Decodable {
        let fitCases: [FitCase]
        let upcoming: Upcoming
    }

    /// Lue via `#filePath` (même patron que `SleepOptimumTests`), pas une ressource
    /// bundle. Absente : passage à vide (skip propre) plutôt qu'un échec.
    private static var fixturePath: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sleep-optimum-context.golden.json")
    }

    private static let tol = 1e-9

    private func fit(_ nights: [Night]) -> (global: SleepOptimumModel.Fit, ctx: SleepOptimumContext.Model) {
        let built = SleepOptimumFeatures.build(nights: nights.map(\.input))
        let global = SleepOptimumModel.fit(X: built.X, y: built.y)
        return (global, SleepOptimumContext.fit(built: built, globalFit: global))
    }

    @Test func goldenContextFixtureMatchesTSReferenceWhenPresent() throws {
        guard let data = try? Data(contentsOf: Self.fixturePath) else {
            return // fixture pas encore livrée côté TS — skip propre.
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)

        for c in fixture.fitCases {
            let (global, ctx) = fit(c.nights)
            let e = c.expected
            #expect(ctx.n == e.n, "\(c.name) n")
            #expect(abs(ctx.alpha - e.alpha) < Self.tol, "\(c.name) alpha")
            #expect(ctx.d.count == e.d.count)
            for (a, b) in zip(ctx.d, e.d) { #expect(abs(a - b) < Self.tol, "\(c.name) d") }
            #expect(ctx.gamma.count == e.gamma.count)
            for (a, b) in zip(ctx.gamma, e.gamma) { #expect(abs(a - b) < Self.tol, "\(c.name) gamma") }
            #expect(ctx.stats.count == e.stats.count)
            for (a, b) in zip(ctx.stats, e.stats) {
                #expect(abs(a.mean - b.mean) < Self.tol, "\(c.name) stats.mean")
                #expect(abs(a.sd - b.sd) < Self.tol, "\(c.name) stats.sd")
            }
            #expect(abs(global.idealRaw - e.globalIdealRaw) < Self.tol, "\(c.name) globalIdealRaw")
            #expect(global.idealHours == e.globalIdealHours, "\(c.name) globalIdealHours")

            for x in e.contexts {
                let covs = x.covariates.value
                let z = zip(ctx.stats, covs.values).map { $0.z($1) }
                #expect(z.count == x.z.count)
                for (a, b) in zip(z, x.z) { #expect(abs(a - b) < Self.tol, "\(c.name) / \(x.name) z") }
                #expect(abs(SleepOptimumContext.idealRaw(model: ctx, z: z) - x.idealRaw) < Self.tol,
                        "\(c.name) / \(x.name) idealRaw")
                #expect(SleepOptimumContext.nightIdealHours(model: ctx, covariates: covs) == x.idealHours,
                        "\(c.name) / \(x.name) idealHours")
            }
        }

        // Nuit à venir : endormissement habituel, onsetRef, covariables, idéal.
        let u = fixture.upcoming
        let habitualNights = u.habitualNights.enumerated().map { i, n in
            SleepRecommendationLocal.ModelRawNight(
                date: "h\(i)", startTs: n.startTs, endTs: n.startTs + 8 * 3600, S: 7.5, offsetS: n.offsetS)
        }
        let habitual = SleepOptimumContext.habitualOnsetMin(nights: habitualNights)
        #expect(habitual != nil)
        #expect(abs((habitual ?? -1) - u.expectedHabitualOnsetMin) < Self.tol, "habitualOnsetMin")

        let modelCase = try #require(fixture.fitCases.first { $0.name == u.modelCase })
        let (_, ctx) = fit(modelCase.nights)
        for c in u.cases {
            let onsetRef = SleepOptimumContext.onsetReference(
                date: u.date, nowS: c.nowS, habitualOnsetMin: habitual, offsetS: u.offsetS)
            #expect(abs(onsetRef - c.expected.onsetRef) < Self.tol, "\(c.name) onsetRef")
            let covs = SleepOptimumContext.upcomingNightCovariates(
                date: u.date, onsetRef: onsetRef,
                bbSamples: c.bbSamples.map { .init(ts: $0.ts, value: $0.value) },
                stressSamples: c.stressSamples.map { .init(ts: $0.ts, value: $0.value) },
                activities: c.activities.map { .init(startTs: $0.startTs, durationMin: ($0.durationS ?? 0) / 60) },
                sleepByDate: u.sleepByDate)
            let e = c.expected.covariates
            #expect(covs.bbBed == e.bbBed, "\(c.name) bbBed")
            #expect(covs.sportPrev == e.sportPrev, "\(c.name) sportPrev")
            #expect(abs((covs.stressPrevDay ?? -1) - (e.stressPrevDay ?? -2)) < Self.tol, "\(c.name) stressPrevDay")
            #expect(abs((covs.priorSleep ?? -1) - (e.priorSleep ?? -2)) < Self.tol, "\(c.name) priorSleep")
            #expect(SleepOptimumContext.nightIdealHours(model: ctx, covariates: covs) == c.expected.nightIdealHours,
                    "\(c.name) nightIdealHours")
        }
    }
}

// MARK: - Heure de coucher par date (fonction pure de la carte)

struct SleepBedtimePlanTests {
    private func reco(_ extra: String = "") throws -> DashboardSleepRecommendation {
        let json = """
        {"nights":20,"status":"ok","waketime":"07:00","recommendedBedtime":"23:00","targetHours":8.25,
         "avgAwakeMin":20,"latencyMin":15,"idealHours":8.0\(extra)}
        """
        return try PulseAPIClient.decoder.decode(DashboardSleepRecommendation.self, from: Data(json.utf8))
    }

    // Lundi 2026-10-05 … dimanche 2026-10-11.
    @Test func weekdayConventionIsSundayOne() {
        #expect(SleepBedtimePlan.weekday(ofDateKey: "2026-10-04") == 1) // dimanche
        #expect(SleepBedtimePlan.weekday(ofDateKey: "2026-10-05") == 2) // lundi
        #expect(SleepBedtimePlan.weekday(ofDateKey: "2026-10-10") == 7) // samedi
        #expect(SleepBedtimePlan.weekday(ofDateKey: "pas-une-date") == nil)
    }

    @Test func globalFallbackUsesIdealAndGlobalWaketime() throws {
        // 07:00 − (8 h + 20 + 15 min) = 22:25.
        let plan = try #require(SleepBedtimePlan.plan(reco: reco(), date: "2026-10-05", alarmMinutes: nil))
        #expect(plan.bedtime == "22:25")
        #expect(plan.wakeMinutes == 420)
        #expect(plan.isNightSpecific == false)
    }

    @Test func alarmTakesPriorityOverHabitualWaketimes() throws {
        let r = try reco(#","waketimeWorkday":"06:00","waketimeFreeDay":"10:00""#)
        let plan = try #require(SleepBedtimePlan.plan(reco: r, date: "2026-10-05", alarmMinutes: 6 * 60 + 30))
        #expect(plan.wakeMinutes == 390)
        #expect(plan.bedtime == "21:55") // 06:30 − 8 h 35
    }

    @Test func workdayAndFreeDayFallbacks() throws {
        let r = try reco(#","waketimeWorkday":"06:00","waketimeFreeDay":"10:00""#)
        let monday = try #require(SleepBedtimePlan.plan(reco: r, date: "2026-10-05", alarmMinutes: nil))
        let saturday = try #require(SleepBedtimePlan.plan(reco: r, date: "2026-10-10", alarmMinutes: nil))
        let sunday = try #require(SleepBedtimePlan.plan(reco: r, date: "2026-10-11", alarmMinutes: nil))
        #expect(monday.wakeMinutes == 360)
        #expect(saturday.wakeMinutes == 600)
        #expect(sunday.wakeMinutes == 600)
        // Une seule des deux clés présentes : l'autre type retombe sur `waketime`.
        let onlyWorkday = try reco(#","waketimeWorkday":"06:00""#)
        let weekend = try #require(SleepBedtimePlan.plan(reco: onlyWorkday, date: "2026-10-10", alarmMinutes: nil))
        #expect(weekend.wakeMinutes == 420)
    }

    @Test func nightIdealOnlyUsedForItsOwnDate() throws {
        let r = try reco(#","nightDate":"2026-10-06","nightIdealHours":8.5"#)
        let same = try #require(SleepBedtimePlan.plan(reco: r, date: "2026-10-06", alarmMinutes: nil))
        #expect(same.isNightSpecific)
        #expect(same.idealHours == 8.5)
        #expect(same.bedtime == "21:55") // 07:00 − (8 h 30 + 35 min)
        let other = try #require(SleepBedtimePlan.plan(reco: r, date: "2026-10-07", alarmMinutes: nil))
        #expect(!other.isNightSpecific)
        #expect(other.idealHours == 8.0)
    }

    @Test func idealFallsBackToTargetHoursThenNil() throws {
        let json = #"{"nights":5,"status":"ok","waketime":"07:00","recommendedBedtime":"23:00","targetHours":8.0,"avgAwakeMin":0,"latencyMin":0}"#
        let r = try PulseAPIClient.decoder.decode(DashboardSleepRecommendation.self, from: Data(json.utf8))
        #expect(SleepBedtimePlan.plan(reco: r, date: "2026-10-05", alarmMinutes: nil)?.bedtime == "23:00")
        let none = #"{"nights":5,"status":"ok","waketime":"07:00","recommendedBedtime":"23:00"}"#
        let r2 = try PulseAPIClient.decoder.decode(DashboardSleepRecommendation.self, from: Data(none.utf8))
        #expect(SleepBedtimePlan.plan(reco: r2, date: "2026-10-05", alarmMinutes: nil) == nil)
        // Ni réveil prévu ni lever habituel → pas de plan.
        let noWake = #"{"nights":5,"status":"ok","recommendedBedtime":"23:00","idealHours":8}"#
        let r3 = try PulseAPIClient.decoder.decode(DashboardSleepRecommendation.self, from: Data(noWake.utf8))
        #expect(SleepBedtimePlan.plan(reco: r3, date: "2026-10-05", alarmMinutes: nil) == nil)
        #expect(SleepBedtimePlan.plan(reco: r3, date: "2026-10-05", alarmMinutes: 420)?.bedtime == "23:00")
    }

    @Test func bedtimeWrapsAroundMidnight() throws {
        // Réveil 06:00 − 8 h 35 → 21:25 ; réveil 01:00 − 8 h 35 → 16:25 (jour précédent).
        #expect(try SleepBedtimePlan.plan(reco: reco(), date: "2026-10-05", alarmMinutes: 360)?.bedtime == "21:25")
        #expect(try SleepBedtimePlan.plan(reco: reco(), date: "2026-10-05", alarmMinutes: 60)?.bedtime == "16:25")
        // Réveil 00:10, idéal 15 min, ni éveil ni latence : −5 min → 23:55 (passage de minuit).
        let tiny = #"{"nights":5,"status":"ok","waketime":"00:10","recommendedBedtime":"23:00","idealHours":0.25,"avgAwakeMin":0,"latencyMin":0}"#
        let r = try PulseAPIClient.decoder.decode(DashboardSleepRecommendation.self, from: Data(tiny.utf8))
        #expect(SleepBedtimePlan.plan(reco: r, date: "2026-10-05", alarmMinutes: nil)?.bedtime == "23:55")
        // Réveil 07:00 − 8 h 35 → 22:25 : se couche AVANT minuit pour un lever matinal.
        #expect(try SleepBedtimePlan.plan(reco: reco(), date: "2026-10-05", alarmMinutes: nil)?.bedtime == "22:25")
    }

    @Test func durationLabelFormatsHoursAndMinutes() {
        #expect(SleepBedtimePlan.durationLabel(hours: 8 + 10.0 / 60) == "8 h 10")
        #expect(SleepBedtimePlan.durationLabel(hours: 7.75) == "7 h 45")
        #expect(SleepBedtimePlan.durationLabel(hours: 9) == "9 h 00")
    }

    // MARK: - Décodage du DTO

    @Test func decodesNewFieldsWhenPresent() throws {
        let r = try reco(#","waketimeWorkday":"06:45","waketimeFreeDay":"09:15","nightDate":"2026-10-06","nightIdealHours":8.1666667"#)
        #expect(r.waketimeWorkday == "06:45")
        #expect(r.waketimeFreeDay == "09:15")
        #expect(r.nightDate == "2026-10-06")
        #expect(abs((r.nightIdealHours ?? 0) - 8.1666667) < 1e-9)
    }

    @Test func decodesWithoutNewFieldsAsPulseServerWouldSend() throws {
        let r = try reco()
        #expect(r.waketimeWorkday == nil)
        #expect(r.waketimeFreeDay == nil)
        #expect(r.nightDate == nil)
        #expect(r.nightIdealHours == nil)
        #expect(r.isActionable)
        #expect(r.idealHours == 8.0)
    }
}

// MARK: - Sélecteur de date et navigation

struct SommeilDatePickingTests {
    private func calendar(_ tz: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal
    }

    @Test func keyRoundTripsWithoutShiftInExtremeTimeZones() throws {
        let keys = ["2026-10-05", "2026-03-29", "2026-10-25", "2026-01-01", "2026-12-31", "2028-02-29"]
        for tz in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "Europe/Paris", "America/Los_Angeles", "UTC"] {
            let cal = calendar(tz)
            for key in keys {
                let date = try #require(SommeilDatePicking.pickerDate(forKey: key, calendar: cal))
                #expect(SommeilDatePicking.key(forPickerDate: date, calendar: cal) == key, "\(key) @ \(tz)")
            }
        }
    }

    @Test func pickerDateHasTheKeyComponentsInTheLocalCalendar() throws {
        let cal = calendar("Pacific/Kiritimati") // UTC+14 : l'instant UTC serait au jour d'avant
        let date = try #require(SommeilDatePicking.pickerDate(forKey: "2026-10-05", calendar: cal))
        let c = cal.dateComponents([.year, .month, .day], from: date)
        #expect(c.year == 2026 && c.month == 10 && c.day == 5)
    }

    @Test func invalidKeyGivesNil() {
        #expect(SommeilDatePicking.pickerDate(forKey: "demain") == nil)
        #expect(SommeilDatePicking.pickerDate(forKey: "2026-10") == nil)
    }

    @MainActor
    @Test func maxReachableDateIsTomorrow() {
        #expect(SommeilViewModel.maxReachableDate(today: "2026-10-05") == "2026-10-06")
        #expect(SommeilViewModel.maxReachableDate(today: "2026-10-31") == "2026-11-01")
        #expect(SommeilViewModel.maxReachableDate(today: "2026-12-31") == "2027-01-01")
        #expect(SommeilViewModel.maxReachableDate(today: "2028-02-28") == "2028-02-29")
        #expect(SommeilViewModel.maxReachableDate(today: "n'importe quoi") == "n'importe quoi")
    }

    @MainActor
    @Test func viewModelRangeAndLastDayFollowMaxReachableDate() {
        let vm = SommeilViewModel()
        // Avant tout chargement : date = aujourd'hui, borne haute = demain.
        #expect(vm.date == HealthViewModel.todayKey())
        #expect(vm.maxReachableDate == SommeilViewModel.maxReachableDate(today: HealthViewModel.todayKey()))
        #expect(vm.isLastDay == false)
        #expect(vm.selectableRange.upperBound == vm.maxReachableDate)
        #expect(vm.selectableRange.lowerBound <= vm.selectableRange.upperBound)
    }
}

// MARK: - Endpoint local : `date`, champs optionnels, cache

struct SleepRecommendationEndpointTests {
    private func makeDb() throws -> LocalDb {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleep-context-tests-\(UUID().uuidString).sqlite").path
        return try LocalDb(path: path)
    }

    private func isoDay(daysAgo: Int) -> String {
        FitWellnessExtractor.isoDate(Date().timeIntervalSince1970 - Double(daysAgo) * 86400)
    }

    /// 35 nuits récentes (fenêtre `days=30` incluse), réveil 07:00 LOCAL en
    /// semaine / 09:30 le week-end, `S` entre 7 h et 9 h, Body Battery au réveil
    /// et à `wk + 10 h` corrélée à `S`.
    private func seed(_ db: LocalDb, nights: Int = 35) throws {
        var bb: [FitWellnessSample] = []
        for i in 0..<nights {
            let date = isoDay(daysAgo: nights - 1 - i + 1) // jusqu'à hier
            let offset = LocalDb.localOffsetSeconds(forDate: date)
            let weekday = SleepBedtimePlan.weekday(ofDateKey: date) ?? 2
            let wakeLocalH = SleepBedtimePlan.isWorkday(weekday: weekday) ? 7.0 : 9.5
            let endTs = DashboardStatsTime.dayStartUnixUTC(date) + wakeLocalH * 3600 - offset
            let sH = 7 + Double(i % 5) * 0.5
            let startTs = endTs - (sH + 0.5) * 3600
            let sleep = FitSleepSummary(
                date: date, startTs: startTs, endTs: endTs, durationS: (sH + 0.5) * 3600, score: nil,
                deepS: sH * 0.2 * 3600, lightS: sH * 0.55 * 3600, remS: sH * 0.25 * 3600, awakeS: 1800,
                awakenings: nil, phases: [])
            try db.storeSleep(sleep, hash: "synth-\(date)", fileName: "\(date).fit")
            bb.append(FitWellnessSample(metric: "bb", ts: endTs + 1800, value: 40 + sH * 4))
            bb.append(FitWellnessSample(metric: "bb", ts: endTs + 10 * 3600, value: 30 + sH * 3))
            bb.append(FitWellnessSample(metric: "bb", ts: startTs - 600, value: 50 + Double(i % 7)))
        }
        try db.insertBodyBatterySamples(bb)
    }

    private func call(_ backend: RealLocalPulseBackend, _ query: [String: String]) async throws -> DashboardSleepRecommendation {
        let data = try await backend.handle(method: "GET", path: "api/stats/sleep-recommendation", query: query, body: nil)
        return try PulseAPIClient.decoder.decode(DashboardSleepRecommendation.self, from: data)
    }

    private func raw(_ backend: RealLocalPulseBackend, _ query: [String: String]) async throws -> [String: Any] {
        let data = try await backend.handle(method: "GET", path: "api/stats/sleep-recommendation", query: query, body: nil)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func withoutDateParameterNoNightFieldsButDayTypeWakeTimes() async throws {
        let db = try makeDb()
        try seed(db)
        let backend = RealLocalPulseBackend(db: db)
        let json = try await raw(backend, ["days": "30"])
        #expect(json["nightDate"] == nil)
        #expect(json["nightIdealHours"] == nil)
        #expect(json["waketimeWorkday"] as? String == "07:00")
        #expect(json["waketimeFreeDay"] as? String == "09:30")
        #expect(json["status"] as? String == "ok")
    }

    @Test func dateParameterReturnsNightIdealForFutureAndMeasuredDates() async throws {
        let db = try makeDb()
        try seed(db)
        let backend = RealLocalPulseBackend(db: db)
        let tomorrow = isoDay(daysAgo: -1)
        let measured = isoDay(daysAgo: 5)
        for date in [tomorrow, measured] {
            let reco = try await call(backend, ["days": "30", "date": date])
            #expect(reco.nightDate == date)
            let ideal = try #require(reco.nightIdealHours)
            #expect(ideal >= 7 && ideal <= 9.5)
            #expect(abs(ideal * 12 - (ideal * 12).rounded()) < 1e-6 || ideal == reco.idealHours)
        }
    }

    @Test func invalidDateParameterIsIgnored() async throws {
        let db = try makeDb()
        try seed(db)
        let backend = RealLocalPulseBackend(db: db)
        let json = try await raw(backend, ["days": "30", "date": "2026-13-45"])
        #expect(json["nightDate"] == nil)
        #expect(json["nightIdealHours"] == nil)
        #expect(json["status"] as? String == "ok")
    }

    @Test func fewerThan30ModelNightsGiveGlobalIdealForTheNight() async throws {
        let db = try makeDb()
        try seed(db, nights: 20)
        let backend = RealLocalPulseBackend(db: db)
        let reco = try await call(backend, ["days": "30", "date": isoDay(daysAgo: -1)])
        #expect(reco.nightIdealHours == reco.idealHours)
    }

    @Test func insufficientBranchCarriesNoNewFields() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let json = try await raw(backend, ["days": "30", "date": isoDay(daysAgo: -1)])
        #expect(json["status"] as? String == "insufficient")
        #expect(json["nightDate"] == nil)
    }

    @Test func modelIsCachedAcrossDatesAndInvalidatedByNewNight() async throws {
        let db = try makeDb()
        try seed(db)
        let backend = RealLocalPulseBackend(db: db)
        _ = try await call(backend, ["days": "30", "date": isoDay(daysAgo: 1)])
        _ = try await call(backend, ["days": "30", "date": isoDay(daysAgo: 2)])
        _ = try await call(backend, ["days": "30", "date": isoDay(daysAgo: -1)])
        #expect(backend.sleepModelCache.computeCount == 1)

        // Une nuit de plus (aujourd'hui) change la clé → recalcul.
        let today = isoDay(daysAgo: 0)
        let offset = LocalDb.localOffsetSeconds(forDate: today)
        let endTs = DashboardStatsTime.dayStartUnixUTC(today) + 7 * 3600 - offset
        try db.storeSleep(FitSleepSummary(
            date: today, startTs: endTs - 8 * 3600, endTs: endTs, durationS: 8 * 3600, score: nil,
            deepS: 5000, lightS: 15000, remS: 7000, awakeS: 1000, awakenings: nil, phases: []),
            hash: "synth-today", fileName: "today.fit")
        _ = try await call(backend, ["days": "30", "date": today])
        #expect(backend.sleepModelCache.computeCount == 2)
    }

    /// Une date future sans données ne casse rien en mode local : le détail de
    /// jour se décode, sans nuit (la carte « pas de nuit » s'affiche), et la
    /// reco de cette date existe.
    @Test func futureDateWithoutDataDecodesCleanly() async throws {
        let db = try makeDb()
        try seed(db)
        let backend = RealLocalPulseBackend(db: db)
        let tomorrow = isoDay(daysAgo: -1)
        let dayData = try await backend.handle(method: "GET", path: "api/wellness/day/\(tomorrow)", query: [:], body: nil)
        let day = try PulseAPIClient.decoder.decode(WellnessDayDetail.self, from: dayData)
        #expect(day.date == tomorrow)
        #expect(day.sleep.main == nil)
        let reco = try await call(backend, ["days": "30", "date": tomorrow])
        #expect(reco.isActionable)
        #expect(reco.nightIdealHours != nil)
    }
}
