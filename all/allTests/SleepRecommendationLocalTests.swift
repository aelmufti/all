//
//  SleepRecommendationLocalTests.swift
//  allTests
//
//  Valide le port Swift de `sleep-recommendation.ts`
//  (`Local/SleepRecommendationLocal.swift`) : `wakeStressByNight` (port
//  intégral) et la mécanique lever/coucher/latence/paliers de
//  `computeSleepRecommendation`, recombinée avec l'optimum
//  (`Local/SleepOptimum.swift`). Données SYNTHÉTIQUES uniquement (horaires
//  calés sur minuit UTC pour un calcul de tête vérifiable).
//

import Testing
import Foundation
@testable import all

struct SleepRecommendationLocalTests {
    // MARK: - `wakeStressByNight`

    @Test func wakeStressByNightAveragesSamplesInWindowBoundedByNextNight() {
        let nightA = SleepRecommendationLocal.NightWindow(startTs: 0, endTs: 1000)
        let nightB = SleepRecommendationLocal.NightWindow(startTs: 100_000, endTs: 101_000)
        // Fenêtre de A : [endTs, min(nextStart, endTs+16h)) = [1000, 58600).
        let samples = (0..<60).map {
            SleepRecommendationLocal.StressSample(ts: 1000 + Double($0) * 100, value: 50)
        }
        let result = SleepRecommendationLocal.wakeStressByNight(
            nights: [nightA, nightB], samples: samples, nowS: 1_000_000)
        #expect(result[0] == 50)
    }

    @Test func wakeStressByNightReturnsNilUnderMinimumSampleCount() {
        let nightA = SleepRecommendationLocal.NightWindow(startTs: 0, endTs: 1000)
        let nightB = SleepRecommendationLocal.NightWindow(startTs: 100_000, endTs: 101_000)
        let samples = (0..<10).map {
            SleepRecommendationLocal.StressSample(ts: 1000 + Double($0) * 100, value: 50)
        }
        let result = SleepRecommendationLocal.wakeStressByNight(
            nights: [nightA, nightB], samples: samples, nowS: 1_000_000)
        #expect(result[0] == nil)
    }

    @Test func wakeStressByNightReturnsNilForLastNightBeforeDayEnds() {
        let night = SleepRecommendationLocal.NightWindow(startTs: 0, endTs: 1000)
        // Dernière nuit (pas de suivante) : jour = [endTs, endTs+16h). `nowS`
        // AVANT la fin de ce jour → pas encore conclu, `nil` quel que soit
        // l'échantillonnage.
        let result = SleepRecommendationLocal.wakeStressByNight(nights: [night], samples: [], nowS: 2000)
        #expect(result[0] == nil)
    }

    // MARK: - `computeSleepRecommendation` (lever/coucher/latence/paliers + optimum)

    /// 3 nuits identiques (8 h de sommeil, coucher 23:00 UTC, lever 07:00
    /// UTC, `offsetS = 0`) + un `Fit` `n = 0` (idéal a priori 7,75 h, basis
    /// `"prior"`) — calcul de tête vérifiable (cf. commentaires).
    @Test func computeSleepRecommendationMatchesHandComputedBedtimeForUniformNights() {
        func night(dayIndex: Int) -> SleepRecommendationLocal.RecoNight {
            let endTs = Double(dayIndex) * 86400 + 7 * 3600 // 07:00 UTC
            let startTs = endTs - 8 * 3600 // 23:00 UTC la veille
            return SleepRecommendationLocal.RecoNight(
                date: "2026-01-0\(dayIndex + 1)", startTs: startTs, endTs: endTs,
                deepS: 4 * 3600, lightS: 3 * 3600, remS: 1 * 3600, awakeS: 0, offsetS: 0)
        }
        let nights = (0..<3).map { night(dayIndex: $0) }
        let fit = SleepOptimumModel.fit(X: [], y: []) // n = 0 → idealHours = 7.75, basis "prior".

        let result = SleepRecommendationLocal.computeSleepRecommendation(
            nights: nights, fit: fit, todayKey: "2026-01-04")

        guard case .ok(let ok) = result else {
            Issue.record("attendu .ok, reçu \(result)")
            return
        }
        #expect(ok.nights == 3)
        #expect(ok.basis == "prior")
        #expect(ok.idealHours == 7.75)
        // trial impossible hors basis "modele" (spec §7.1).
        #expect(ok.trial == false)
        // Dette nulle : 3 nuits de 8h > idéal 7.75h → somme des écarts négative, bornée à 0.
        #expect(ok.debtHours == 0)
        #expect(ok.debtBonusMin == 0)
        #expect(ok.targetHours == 7.8) // round1(7.75) = 7.8 (arrondi away-from-zero, comme `Math.round`).
        #expect(ok.waketime == "07:00")
        #expect(ok.currentBedtime == "22:45") // 23:00 habituel − 15 min de latence.
        #expect(ok.targetBedtime == "23:00") // 07:00 − (7.75h cible + 15 min latence) ≈ 23:00.
        #expect(ok.recommendedBedtime == "23:00")
        #expect(ok.stepped == false)
        #expect(ok.avgAwakeMin == 0)
    }

    @Test func computeSleepRecommendationUnderThreeNightsReturnsInsufficient() {
        let fit = SleepOptimumModel.fit(X: [], y: [])
        let result = SleepRecommendationLocal.computeSleepRecommendation(nights: [], fit: fit, todayKey: "2026-01-01")
        guard case .insufficient(let n) = result else {
            Issue.record("attendu .insufficient, reçu \(result)")
            return
        }
        #expect(n == 0)
    }
}
