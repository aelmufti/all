//
//  HealthScreenTests.swift
//  allTests
//
//  Décodage des modèles de l'écran Santé (`Pulse/Screens/Health/HealthModels.swift`)
//  contre des fixtures JSON écrites à la main, dans la forme exacte renvoyée
//  par NestJS (`custom-connect/server/src/wellness/*.controller.ts`,
//  `weight/weight.controller.ts`) — jamais de réseau réel (règle immuable du
//  dépôt) : on décode directement `PulseAPIClient.decoder` sur des `Data`
//  littérales, sans `URLSession` ni stub `URLProtocol`.
//

import Testing
import Foundation
@testable import all

struct HealthScreenTests {

    // MARK: - `GET /api/wellness/day/:date`

    @Test func decodesWellnessDayDetail() throws {
        let json = Data("""
        {
          "date": "2026-09-23",
          "summary": {
            "restingHr": 52,
            "bmrKcal": 1680,
            "bodyBatteryHigh": 87,
            "bodyBatteryLow": 22.5,
            "steps": 8342,
            "activeCalories": 410.0,
            "distanceM": 6120.4,
            "sportCalories": 180
          },
          "counterSeries": [{"minute": 60, "steps": 100, "activeCalories": 4.0}],
          "hr": [{"ts": 1758578400, "value": 58}, {"ts": 1758578460, "value": 61.5}],
          "stress": [{"ts": 1758578400, "value": 22}],
          "spo2": [{"ts": 1758578400, "value": 97}],
          "respiration": [{"ts": 1758578400, "value": 14.2}],
          "bodyBatteryPivot": [{"ts": 1758578400, "value": 65}],
          "activities": [
            {"id": 1, "sport": "running", "subSport": null, "startTs": 1758600000, "durationS": 1800, "calories": 220}
          ],
          "sleep": {
            "segments": [{"from": 1758560000, "to": 1758585000}],
            "main": {"from": 1758560000, "to": 1758585000, "durationS": 25000},
            "stages": [
              {"from": 1758560000, "to": 1758565000, "stage": "light"},
              {"from": 1758565000, "to": 1758570000, "stage": "deep"},
              {"from": 1758570000, "to": 1758575000, "stage": "rem"},
              {"from": 1758575000, "to": 1758576000, "stage": "awake"}
            ],
            "score": 78
          }
        }
        """.utf8)

        let detail = try PulseAPIClient.decoder.decode(WellnessDayDetail.self, from: json)

        #expect(detail.date == "2026-09-23")
        #expect(detail.summary.restingHr == 52)
        #expect(detail.summary.bodyBatteryLow == 22.5)
        #expect(detail.hr.count == 2)
        #expect(detail.hr[1].value == 61.5)
        #expect(detail.activities.first?.sport == "running")
        #expect(detail.activities.first?.subSport == nil)
        #expect(detail.sleep.main?.durationS == 25000)
        #expect(detail.sleep.stages.count == 4)
        #expect(detail.sleep.stages[1].stage == .deep)
        #expect(detail.sleep.score == 78)
    }

    /// Quand `wellness_days` n'a pas de ligne pour la date, Nest étale
    /// `{}` : les clés `restingHr`/`bmrKcal`/`bodyBatteryHigh`/`bodyBatteryLow`
    /// sont alors totalement absentes du JSON (pas `null`) — un `Optional`
    /// synthétisé doit décoder ça en `nil` sans jeter.
    @Test func decodesWellnessDaySummaryWithMissingKeys() throws {
        let json = Data("""
        {
          "date": "2026-09-23",
          "summary": {"steps": 4000, "activeCalories": 120, "distanceM": 3000, "sportCalories": 0},
          "hr": [], "stress": [], "spo2": [], "respiration": [], "bodyBatteryPivot": [],
          "activities": [],
          "sleep": {"segments": [], "main": null, "stages": [], "score": null}
        }
        """.utf8)

        let detail = try PulseAPIClient.decoder.decode(WellnessDayDetail.self, from: json)

        #expect(detail.summary.restingHr == nil)
        #expect(detail.summary.bmrKcal == nil)
        #expect(detail.summary.bodyBatteryHigh == nil)
        #expect(detail.sleep.main == nil)
        #expect(detail.sleep.score == nil)
    }

    // MARK: - `GET /api/wellness/days`

    @Test func decodesWellnessDayRows() throws {
        let json = Data("""
        [
          {
            "date": "2026-09-22", "restingHr": 50, "bmrKcal": 1650, "steps": 7000,
            "activeCalories": 300, "distanceM": 5200, "minHr": 48, "maxHr": 142,
            "avgStress": 24, "bodyBatteryHigh": 90, "bodyBatteryLow": 30,
            "sleepDurationS": 26100, "sleepScore": 81, "sportCalories": 0
          },
          {
            "date": "2026-09-23", "restingHr": null, "bmrKcal": null, "steps": null,
            "activeCalories": null, "distanceM": null, "minHr": null, "maxHr": null,
            "avgStress": null, "bodyBatteryHigh": null, "bodyBatteryLow": null,
            "sleepDurationS": null, "sleepScore": null, "sportCalories": null
          }
        ]
        """.utf8)

        let rows = try PulseAPIClient.decoder.decode([WellnessDayRow].self, from: json)

        #expect(rows.count == 2)
        #expect(rows[0].date == "2026-09-22")
        #expect(rows[0].sleepScore == 81)
        #expect(rows[1].restingHr == nil)
    }

    // MARK: - `GET /api/wellness/intensity/day/:date`

    @Test func decodesIntensityDayDetail() throws {
        let json = Data("""
        {
          "date": "2026-09-23",
          "minutes": 42.5,
          "moderateMin": 30,
          "vigorousMin": 6.25,
          "coverage": 0.92,
          "elapsed": 1,
          "bouts": [
            {"from": 1758600000, "to": 1758601800, "moderateMin": 20, "vigorousMin": 5, "minutes": 30, "straddles": false}
          ],
          "params": {
            "maxHeartRate": 190, "moderateBpm": 120, "vigorousBpm": 150,
            "moderatePct": 0.64, "vigorousPct": 0.76, "minBoutS": 600,
            "maxGapS": 120, "dipToleranceS": 90, "minCoverage": 0.7,
            "source": "watch", "measuredAt": "2026-09-01T00:00:00.000Z",
            "hrCalcType": "watch", "restingHeartRate": 52, "restingSource": "measured"
          }
        }
        """.utf8)

        let detail = try PulseAPIClient.decoder.decode(IntensityDayDetail.self, from: json)

        #expect(detail.minutes == 42.5)
        #expect(detail.bouts.first?.straddles == false)
        #expect(detail.params.source == "watch")
        #expect(detail.params.measuredAt == "2026-09-01T00:00:00.000Z")
    }

    /// `hrCalcType`/`measuredAt` peuvent être explicitement `null` (pas de
    /// FC max mesurée par la montre) — vérifie que ces `String?` acceptent
    /// bien un `null` JSON explicite, pas seulement une clé absente.
    @Test func decodesIntensityParamsWithNullOptionals() throws {
        let json = Data("""
        {
          "maxHeartRate": 190, "moderateBpm": 120, "vigorousBpm": 150,
          "moderatePct": 0.64, "vigorousPct": 0.76, "minBoutS": 600,
          "maxGapS": 120, "dipToleranceS": 90, "minCoverage": 0.7,
          "source": "default", "measuredAt": null, "hrCalcType": null,
          "restingHeartRate": 60, "restingSource": "default"
        }
        """.utf8)

        let params = try PulseAPIClient.decoder.decode(IntensityParamsView.self, from: json)

        #expect(params.measuredAt == nil)
        #expect(params.hrCalcType == nil)
        #expect(params.source == "default")
    }

    // MARK: - `GET /api/weight`

    @Test func decodesWeightData() throws {
        let json = Data("""
        {
          "current": 74.2, "currentDate": "2026-09-23", "deltaKg": -1.3,
          "minKg": 73.0, "maxKg": 75.5, "entries": 12, "rangeDays": 90,
          "series": [
            {"date": "2026-09-01", "kg": 75.5, "avg": 75.5},
            {"date": "2026-09-23", "kg": 74.2, "avg": 74.6}
          ],
          "push": {"status": "sent", "kg": 74.2, "at": "2026-09-23T08:00:00.000Z"}
        }
        """.utf8)

        let weight = try PulseAPIClient.decoder.decode(WeightData.self, from: json)

        #expect(weight.current == 74.2)
        #expect(weight.entries == 12)
        #expect(weight.series.count == 2)
        #expect(weight.push.status == "sent")
        #expect(weight.push.kg == 74.2)
    }

    /// Aucune pesée enregistrée : `WeightController.list` renvoie `current`/
    /// `currentDate`/`deltaKg` à `null` et `push` à l'état `idle`.
    @Test func decodesWeightDataWhenEmpty() throws {
        let json = Data("""
        {
          "current": null, "currentDate": null, "deltaKg": null,
          "minKg": null, "maxKg": null, "entries": 0, "rangeDays": 90,
          "series": [], "push": {"status": "idle", "kg": null, "at": null}
        }
        """.utf8)

        let weight = try PulseAPIClient.decoder.decode(WeightData.self, from: json)

        #expect(weight.current == nil)
        #expect(weight.entries == 0)
        #expect(weight.push.status == "idle")
    }

    // MARK: - `POST /api/weight` (corps envoyé)

    @Test func encodesWeightSaveRequest() throws {
        let request = WeightSaveRequest(date: "2026-09-23", kg: 74.2)
        let data = try PulseAPIClient.encoder.encode(request)
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)

        #expect(decoded["date"] == .string("2026-09-23"))
        #expect(decoded["kg"] == .double(74.2))
    }
}

/// Petit helper de test pour inspecter un corps JSON encodé sans connaître le
/// type exact de chaque valeur à l'avance — utilisé uniquement par
/// `encodesWeightSaveRequest` ci-dessus.
private enum JSONValue: Decodable, Equatable {
    case string(String)
    case double(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .double(try container.decode(Double.self))
        }
    }
}
