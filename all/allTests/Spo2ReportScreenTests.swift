//
//  Spo2ReportScreenTests.swift
//  allTests
//
//  Décodage des modèles de l'écran Rapport SpO2
//  (`Pulse/Screens/Spo2Report/Spo2ReportModels.swift`) contre des fixtures
//  JSON écrites à la main, dans la forme exacte renvoyée par
//  `WellnessController.spo2Report` (`GET api/wellness/spo2-report`,
//  `custom-connect/server/src/wellness/wellness.controller.ts` ~ligne 387) —
//  jamais de réseau réel (règle immuable du dépôt) : on décode directement
//  `PulseAPIClient.decoder` sur des `Data` littérales, comme
//  `HealthScreenTests.swift`/`NutritionScreenTests.swift`.
//

import Testing
import Foundation
@testable import all

struct Spo2ReportScreenTests {

    // MARK: - `GET api/wellness/spo2-report`

    @Test func decodesSpo2Report() throws {
        let json = Data("""
        {
          "generatedAt": 1758617000,
          "nights": [
            {
              "date": "2026-09-22",
              "startTs": 1758560000,
              "endTs": 1758585000,
              "sampleCount": 480,
              "intervalS": 60,
              "coverageS": 28800,
              "mean": 95.4,
              "min": 84,
              "p5": 90,
              "median": 96,
              "below90": 22,
              "below88": 6,
              "below85": 1,
              "samples": [
                {"ts": 1758560000, "value": 97},
                {"ts": 1758560060, "value": 96.5}
              ]
            },
            {
              "date": "2026-09-23",
              "startTs": 1758646400,
              "endTs": 1758671000,
              "sampleCount": 410,
              "intervalS": 60,
              "coverageS": 24600,
              "mean": 96.1,
              "min": 91,
              "p5": 93,
              "median": 97,
              "below90": 0,
              "below88": 0,
              "below85": 0,
              "samples": [
                {"ts": 1758646400, "value": 98}
              ]
            }
          ],
          "excludedNights": 1,
          "minCoverageS": 1800
        }
        """.utf8)

        let report = try PulseAPIClient.decoder.decode(Spo2Report.self, from: json)

        #expect(report.generatedAt == 1758617000)
        #expect(report.excludedNights == 1)
        #expect(report.minCoverageS == 1800)
        #expect(report.nights.count == 2)

        let first = report.nights[0]
        #expect(first.date == "2026-09-22")
        #expect(first.sampleCount == 480)
        #expect(first.mean == 95.4)
        #expect(first.min == 84)
        #expect(first.p5 == 90)
        #expect(first.median == 96)
        #expect(first.below90 == 22)
        #expect(first.below88 == 6)
        #expect(first.below85 == 1)
        #expect(first.samples.count == 2)
        #expect(first.samples[1].value == 96.5)
        #expect(first.id == "2026-09-22")

        #expect(report.nights[1].below90 == 0)
    }

    /// Aucune nuit exploitable (toutes sous `minCoverageS`) : `nights` est un
    /// tableau vide et `excludedNights` reflète le nombre écarté — cf. le
    /// message dédié affiché côté Angular (`empty`) plutôt qu'un tableau vide
    /// silencieux.
    @Test func decodesSpo2ReportWithNoExploitableNight() throws {
        let json = Data("""
        {
          "generatedAt": 1758617000,
          "nights": [],
          "excludedNights": 3,
          "minCoverageS": 1800
        }
        """.utf8)

        let report = try PulseAPIClient.decoder.decode(Spo2Report.self, from: json)

        #expect(report.nights.isEmpty)
        #expect(report.excludedNights == 3)
        #expect(report.minCoverageS == 1800)
    }

    /// Les valeurs SpO2 (`mean`/`min`/`p5`/`median`/`value`) sont parfois des
    /// entiers JSON, parfois des décimaux (moyenne arrondie au dixième côté
    /// serveur) — `Double` doit accepter les deux sans jeter.
    @Test func decodesSpo2SampleWithIntegerOrDecimalValue() throws {
        let json = Data("""
        [{"ts": 1758560000, "value": 97}, {"ts": 1758560060, "value": 96.5}]
        """.utf8)

        let samples = try PulseAPIClient.decoder.decode([Spo2Sample].self, from: json)

        #expect(samples[0].value == 97)
        #expect(samples[1].value == 96.5)
    }
}
