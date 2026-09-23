//
//  DashboardScreenTests.swift
//  allTests
//
//  Décodage des modèles de l'écran Dashboard
//  (`Pulse/Screens/Dashboard/DashboardModels.swift`) contre des fixtures JSON
//  écrites à la main, dans la forme exacte renvoyée par NestJS
//  (`custom-connect/server/src/stats/stats.controller.ts`,
//  `wellness/wellness.controller.ts`) — jamais de réseau réel (règle immuable
//  du dépôt) : on décode directement `PulseAPIClient.decoder` sur des `Data`
//  littérales, sans `URLSession` ni stub `URLProtocol`. Quelques tests de
//  formatage purs (`DashboardFormatting.swift`) complètent la couverture.
//

import Testing
import Foundation
@testable import all

struct DashboardScreenTests {

    // MARK: - GET api/stats/tab-training

    @Test func decodesTrainingTab() throws {
        let json = Data("""
        {
          "days": 30,
          "count": 9,
          "totalS": 32400,
          "perWeek": 2.1,
          "avgHr": 138,
          "activeKcal": 5400,
          "deltaPct": 12,
          "weeks": [
            {"week": "2026-08-31", "label": "S36", "load": 320, "durationS": 10800, "sessions": 3, "avg4": null, "overload": false},
            {"week": "2026-09-07", "label": "S37", "load": 480, "durationS": 14400, "sessions": 4, "avg4": 320, "overload": true}
          ],
          "shares": [
            {"sport": "running", "durationS": 18000, "pct": 56},
            {"sport": "cycling", "durationS": 14400, "pct": 44}
          ],
          "streak": {"best": 6, "current": 3},
          "zones": [
            {"zone": 1, "seconds": 3600},
            {"zone": 2, "seconds": 9000},
            {"zone": 3, "seconds": 12000},
            {"zone": 4, "seconds": 5400},
            {"zone": 5, "seconds": 2400}
          ],
          "records": {
            "longestSession": {"value": 5400, "date": "2026-09-12T07:30:00.000Z"},
            "longestDistance": {"value": 12000, "date": "2026-09-05T06:00:00.000Z"},
            "bestPace": {"value": 285.5, "date": "2026-09-19T06:15:00.000Z"},
            "heaviestWeek": {"value": 14400, "label": "S37"},
            "maxHr": {"value": 172, "date": "2026-09-12T07:30:00.000Z"}
          }
        }
        """.utf8)

        let training = try PulseAPIClient.decoder.decode(DashboardTrainingTab.self, from: json)

        #expect(training.count == 9)
        #expect(training.avgHr == 138)
        #expect(training.weeks.count == 2)
        #expect(training.weeks[1].overload == true)
        #expect(training.weeks[0].avg4 == nil)
        #expect(training.shares.first?.sport == "running")
        #expect(training.streak.best == 6)
        #expect(training.zones.count == 5)
        #expect(training.records.longestSession?.value == 5400)
        #expect(training.records.bestPace?.value == 285.5)
        #expect(training.records.heaviestWeek?.label == "S37")
    }

    @Test func decodesTrainingTabWithNoRecords() throws {
        let json = Data("""
        {
          "days": 30, "count": 0, "totalS": 0, "perWeek": 0, "avgHr": null,
          "activeKcal": 0, "deltaPct": null, "weeks": [], "shares": [],
          "streak": {"best": 0, "current": 0}, "zones": [],
          "records": {
            "longestSession": null, "longestDistance": null, "bestPace": null,
            "heaviestWeek": null, "maxHr": null
          }
        }
        """.utf8)

        let training = try PulseAPIClient.decoder.decode(DashboardTrainingTab.self, from: json)
        #expect(training.count == 0)
        #expect(training.records.longestSession == nil)
    }

    // MARK: - GET api/stats/tab-health

    @Test func decodesHealthTab() throws {
        let json = Data("""
        {
          "days": 30,
          "restingHr": 54,
          "respiration": 14.3,
          "spo2Night": 96.5,
          "stress": 28,
          "weightKg": 74.2,
          "sleepHours": 7.1,
          "restingSeries": [{"date": "2026-09-01", "value": 55}, {"date": "2026-09-20", "value": 53}],
          "restingDelta": -2,
          "respirationSeries": [{"date": "2026-09-01", "value": 14.0}],
          "respirationBand": {"lo": 12.5, "hi": 16.1},
          "spo2Buckets": [
            {"label": "<90", "nights": 0},
            {"label": "95+", "nights": 18}
          ],
          "spo2Nights": 18,
          "weightSeries": [{"date": "2026-09-01", "kg": 75.0}, {"date": "2026-09-20", "kg": 74.2}],
          "weightDelta": -0.8,
          "correlations": [
            {"label": "Sommeil ↔ stress du lendemain", "r": -0.42, "strength": "moyen", "pairs": 20},
            {"label": "Pas ↔ SpO2", "r": null, "strength": "trop peu de données", "pairs": 2}
          ]
        }
        """.utf8)

        let health = try PulseAPIClient.decoder.decode(DashboardHealthTab.self, from: json)

        #expect(health.restingHr == 54)
        #expect(health.restingSeries.count == 2)
        #expect(health.respirationBand?.lo == 12.5)
        #expect(health.spo2Buckets.count == 2)
        #expect(health.weightSeries.last?.kg == 74.2)
        #expect(health.correlations.count == 2)
        #expect(health.correlations.last?.r == nil)
    }

    // MARK: - GET api/stats/tab-nutrition

    @Test func decodesNutritionTab() throws {
        let json = Data("""
        {
          "days": 30,
          "kcalPerDay": 2100,
          "expenditurePerDay": 2400,
          "balance": -300,
          "proteinPerDay": 110,
          "daysLogged": 22,
          "completeDays": 18,
          "entriesPerDay": 3.4,
          "series": [
            {"date": "2026-09-01", "kcal": 2050, "expenditure": 2380, "state": "complete"},
            {"date": "2026-09-02", "kcal": null, "expenditure": 2200, "state": "none"},
            {"date": "2026-09-03", "kcal": 900, "expenditure": 2300, "state": "partial"}
          ],
          "macros": [
            {"key": "protein", "label": "Protéines", "grams": 110, "pct": 21, "kcal": 440},
            {"key": "carbs", "label": "Glucides", "grams": 220, "pct": 42, "kcal": 880},
            {"key": "fat", "label": "Lipides", "grams": 78, "pct": 37, "kcal": 702}
          ],
          "topFoods": [
            {"name": "Poulet", "uses": 14, "kcal": 3200, "protein": 420, "pct": 18}
          ],
          "totalEntries": 76
        }
        """.utf8)

        let nutrition = try PulseAPIClient.decoder.decode(DashboardNutritionTab.self, from: json)

        #expect(nutrition.kcalPerDay == 2100)
        #expect(nutrition.balance == -300)
        #expect(nutrition.series.count == 3)
        #expect(nutrition.series[1].kcal == nil)
        #expect(nutrition.series[1].state == "none")
        #expect(nutrition.macros.count == 3)
        // Champ `kcal` de `macros` (présent côté serveur) n'est pas modélisé —
        // seuls key/label/grams/pct sont utilisés par le template Angular.
        #expect(nutrition.macros.first?.grams == 110)
        #expect(nutrition.topFoods.first?.name == "Poulet")
    }

    @Test func decodesNutritionTabWithNoCompleteDays() throws {
        let json = Data("""
        {
          "days": 30, "kcalPerDay": null, "expenditurePerDay": null, "balance": null,
          "proteinPerDay": null, "daysLogged": 2, "completeDays": 0, "entriesPerDay": 1,
          "series": [], "macros": [
            {"key": "protein", "label": "Protéines", "grams": null, "pct": 0},
            {"key": "carbs", "label": "Glucides", "grams": null, "pct": 0},
            {"key": "fat", "label": "Lipides", "grams": null, "pct": 0}
          ],
          "topFoods": [], "totalEntries": 2
        }
        """.utf8)

        let nutrition = try PulseAPIClient.decoder.decode(DashboardNutritionTab.self, from: json)
        #expect(nutrition.completeDays == 0)
        #expect(nutrition.kcalPerDay == nil)
    }

    // MARK: - GET api/stats/sleep-debt

    @Test func decodesSleepDebt() throws {
        let json = Data("""
        {
          "nights": 3,
          "targetHours": 7,
          "debtHours": 1.5,
          "avgHours": 6.5,
          "deficitNights": 2,
          "avgInBedHours": 7.1,
          "avgAwakeMin": 12,
          "detail": [
            {"date": "2026-09-20", "sleepS": 23400, "inBedS": 25200, "awakeS": 1800, "deltaS": -2400, "cumulativeS": 2400, "score": 74, "bedtime": "23:12"},
            {"date": "2026-09-21", "sleepS": 25800, "inBedS": 26400, "awakeS": 600, "deltaS": 0, "cumulativeS": 2400, "score": 81, "bedtime": null},
            {"date": "2026-09-22", "sleepS": 22000, "inBedS": 23000, "awakeS": 1000, "deltaS": -3200, "cumulativeS": 5600, "score": null, "bedtime": "23:40"}
          ]
        }
        """.utf8)

        let debt = try PulseAPIClient.decoder.decode(DashboardSleepDebt.self, from: json)

        #expect(debt.nights == 3)
        #expect(debt.detail.count == 3)
        #expect(debt.detail[1].bedtime == nil)
        #expect(debt.detail[2].score == nil)
    }

    @Test func decodesEmptySleepDebt() throws {
        let json = Data("""
        {"nights": 0, "targetHours": 7, "debtHours": 0, "avgHours": 0, "deficitNights": 0, "avgInBedHours": 0, "avgAwakeMin": 0, "detail": []}
        """.utf8)

        let debt = try PulseAPIClient.decoder.decode(DashboardSleepDebt.self, from: json)
        #expect(debt.nights == 0)
        #expect(debt.detail.isEmpty)
    }

    // MARK: - GET api/stats/sleep-insights

    @Test func decodesSleepInsightsWithSpo2Arousal() throws {
        let json = Data("""
        {
          "stressImpact": {
            "nights": 20, "r": -0.31, "significant": true,
            "buckets": [
              {"label": "< 6h", "nights": 4, "avgStress": 34.2},
              {"label": "6-7h", "nights": 9, "avgStress": 29.1},
              {"label": "7h+", "nights": 7, "avgStress": null}
            ]
          },
          "fragmentation": {
            "nights": 20, "avgArousals": 3.4, "avgAwakeMin": 18, "avgLongestMin": 9,
            "series": [{"date": "2026-09-01", "arousals": 3, "awakeMin": 15, "longestMin": 8}]
          },
          "composition": {
            "nights": 20, "deep": 18.2, "light": 58.4, "rem": 23.4, "wasoPct": 6.1,
            "ref": {
              "deep": {"lo": 13, "hi": 23},
              "light": {"lo": 45, "hi": 62},
              "rem": {"lo": 20, "hi": 25}
            }
          },
          "spo2Arousal": {
            "nights": 12, "desatTotal": 40, "desatNearPct": 22.5, "controlPct": 9.1,
            "medianArousalMin": 14, "microArousals": 3, "totalArousals": 55
          }
        }
        """.utf8)

        let insights = try PulseAPIClient.decoder.decode(DashboardSleepInsights.self, from: json)

        #expect(insights.stressImpact.nights == 20)
        #expect(insights.stressImpact.buckets[2].avgStress == nil)
        #expect(insights.fragmentation.series.count == 1)
        #expect(insights.composition.ref.deep.lo == 13)
        #expect(insights.spo2Arousal?.nights == 12)
    }

    @Test func decodesSleepInsightsWithoutSpo2Arousal() throws {
        let json = Data("""
        {
          "stressImpact": {"nights": 0, "r": null, "significant": false, "buckets": []},
          "fragmentation": {"nights": 0, "avgArousals": 0, "avgAwakeMin": 0, "avgLongestMin": 0, "series": []},
          "composition": {
            "nights": 0, "deep": 0, "light": 0, "rem": 0, "wasoPct": 0,
            "ref": {"deep": {"lo": 13, "hi": 23}, "light": {"lo": 45, "hi": 62}, "rem": {"lo": 20, "hi": 25}}
          },
          "spo2Arousal": null
        }
        """.utf8)

        let insights = try PulseAPIClient.decoder.decode(DashboardSleepInsights.self, from: json)
        #expect(insights.spo2Arousal == nil)
    }

    // MARK: - GET api/stats/sleep-regularity

    @Test func decodesSleepRegularityWithScore() throws {
        let json = Data("""
        {"nights": 18, "score": 76, "bedtime": "23:05", "waketime": "06:52", "bedStdMin": 22, "wakeStdMin": 18}
        """.utf8)

        let regularity = try PulseAPIClient.decoder.decode(DashboardSleepRegularity.self, from: json)
        #expect(regularity.score == 76)
        #expect(regularity.bedtime == "23:05")
    }

    /// Moins de 3 nuits : le contrôleur renvoie `{ nights, score: null }` sans
    /// les autres clés (absentes, pas `null`).
    @Test func decodesSleepRegularityTooFewNights() throws {
        let json = Data("""
        {"nights": 1, "score": null}
        """.utf8)

        let regularity = try PulseAPIClient.decoder.decode(DashboardSleepRegularity.self, from: json)
        #expect(regularity.nights == 1)
        #expect(regularity.score == nil)
        #expect(regularity.bedtime == nil)
    }

    // MARK: - GET api/wellness/days

    /// Le contrôleur renvoie beaucoup plus de champs que ceux modélisés ici
    /// (`bmrKcal`, `bodyBatteryHigh/Low`, `minHr`, `maxHr`, `sleepScore`…) —
    /// seuls `date`/`restingHr`/`avgStress`/`sleepDurationS`/`sportCalories`/
    /// `steps` alimentent la tendance sommeil du template ; les clés en trop
    /// doivent être silencieusement ignorées par le décodeur.
    @Test func decodesWellnessDayRowIgnoringExtraFields() throws {
        let json = Data("""
        [
          {
            "date": "2026-09-22", "restingHr": 52, "bmrKcal": 1680,
            "bodyBatteryHigh": 87, "bodyBatteryLow": 22, "steps": 8400,
            "activeCalories": 410, "distanceM": 6100.5,
            "minHr": 48, "maxHr": 142, "avgStress": 24,
            "sleepDurationS": 25200, "sleepScore": 78, "sportCalories": 180.5
          },
          {
            "date": "2026-09-23", "restingHr": null, "bmrKcal": null,
            "bodyBatteryHigh": null, "bodyBatteryLow": null, "steps": null,
            "activeCalories": null, "distanceM": null,
            "minHr": null, "maxHr": null, "avgStress": null,
            "sleepDurationS": null, "sleepScore": null, "sportCalories": null
          }
        ]
        """.utf8)

        let rows = try PulseAPIClient.decoder.decode([DashboardWellnessDayRow].self, from: json)

        #expect(rows.count == 2)
        #expect(rows[0].restingHr == 52)
        #expect(rows[0].sleepDurationS == 25200)
        #expect(rows[0].sportCalories == 180.5)
        #expect(rows[1].restingHr == nil)
        #expect(rows[1].sleepDurationS == nil)
    }

    // MARK: - Formatage (`DashboardFormatting.swift`)

    @Test func formatsHoursMinutes() {
        #expect(dashboardFormatHM(3900) == "1h05")
        #expect(dashboardFormatSignedHM(-3900) == "−1h05")
        #expect(dashboardFormatSignedHM(3900) == "+1h05")
    }

    @Test func formatsPace() {
        #expect(dashboardFormatPace(secPerKm: 285) == "4'45\"/km")
        #expect(dashboardFormatPace(secPerKm: 0) == "—")
    }

    @Test func computesDebtLevel() {
        #expect(dashboardDebtLevel(debtHours: -1) == "à jour")
        #expect(dashboardDebtLevel(debtHours: 2) == "faible")
        #expect(dashboardDebtLevel(debtHours: 6) == "modérée")
        #expect(dashboardDebtLevel(debtHours: 12) == "élevée")
    }

    @Test func computesStreakLabel() {
        #expect(dashboardStreakLabel(current: 0) == "coupé")
        #expect(dashboardStreakLabel(current: 2) == "à confirmer")
        #expect(dashboardStreakLabel(current: 5) == "régulier")
        #expect(dashboardStreakLabel(current: 9) == "solide")
    }

    @Test func parsesCalendarDate() {
        let date = dashboardDate(from: "2026-09-23")
        #expect(date != nil)
        #expect(dashboardDate(from: "not-a-date") == nil)
    }

    @Test func mapsDashboardSubViewsPerTab() {
        #expect(dashboardSubViews(for: .sleep) == [.trend, .debt, .regularity])
        #expect(dashboardSubViews(for: .map).isEmpty)
    }
}
