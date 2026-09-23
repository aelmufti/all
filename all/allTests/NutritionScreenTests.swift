//
//  NutritionScreenTests.swift
//  allTests
//
//  Tests de décodage de l'écran Nutrition (`Pulse/Screens/Nutrition/`) —
//  fixtures JSON en dur, **aucun réseau**. Les fixtures reprennent la forme
//  réelle des réponses NestJS (`nutrition.controller.ts`) avec des clés non
//  modélisées par cet écran (ex. `manual`/`manualMin`/`manualMax`/`programme`
//  au niveau racine de `targets`, `detail.sessions`, `macros.bonuses`…) pour
//  vérifier que le décodage restreint tient bien face à des réponses plus
//  riches que ce que l'écran consomme.
//

import Testing
import Foundation
@testable import all

// MARK: - Fixtures

private let dayJSON = Data(
    """
    {
      "date": "2026-09-23",
      "entries": [
        {
          "id": 1, "name": "Poulet", "grams": 150,
          "kcal": 248, "protein": 46.5, "carbs": 0, "fiber": 0, "fat": 5.4,
          "unitLabel": null, "unitQty": null, "ts": 1758610000
        },
        {
          "id": 2, "name": "Riz", "grams": 200,
          "kcal": 260, "protein": 5.4, "carbs": 56, "fiber": 1.2, "fat": 0.6,
          "unitLabel": "portion", "unitQty": 1, "ts": 1758620000
        }
      ],
      "totals": {"kcal": 508, "protein": 51.9, "carbs": 56, "fat": 6, "fiber": 1.2},
      "targets": {"kcal": 2100, "protein": 140, "carbs": 210, "fat": 70, "fiber": 30},
      "targetSource": "auto",
      "targetRanges": {
        "protein": {"min": 120, "max": 160},
        "carbs": {"min": null, "max": 250}
      },
      "programme": {"name": "Sèche douce"},
      "remaining": {"kcal": 1592, "protein": 88.1, "carbs": 154, "fat": 64, "fiber": 28.8},
      "proteinPerKg": 0.74
    }
    """.utf8)

private let emptyDayJSON = Data(
    """
    {
      "date": "2026-09-23",
      "entries": [],
      "totals": {"kcal": 0, "protein": 0, "carbs": 0, "fat": 0, "fiber": 0},
      "targets": {"kcal": 2100, "protein": null, "carbs": null, "fat": null, "fiber": 20},
      "targetRanges": null,
      "programme": null,
      "remaining": {"kcal": 2100, "protein": null, "carbs": null, "fat": null, "fiber": 20},
      "proteinPerKg": null
    }
    """.utf8)

private let targetInfoJSON = Data(
    """
    {
      "date": "2026-09-23",
      "mode": "auto",
      "manual": {"kcal": null, "protein": null, "carbs": null, "fat": null, "fiber": null},
      "manualMin": {"kcal": null, "protein": null, "carbs": null, "fat": null, "fiber": null},
      "manualMax": {"kcal": null, "protein": null, "carbs": null, "fat": null, "fiber": null},
      "programme": {"name": "Sèche douce", "ranges": {"protein": {"min": 120, "max": 160}}},
      "targets": {"kcal": 2100, "protein": 140, "carbs": 210, "fat": 70, "fiber": 30},
      "source": "auto",
      "auto": {
        "status": "ok",
        "source": "watch",
        "missing": [],
        "targetKcal": 2100,
        "expenditureKcal": 2600,
        "deficitKcal": 500,
        "plannedDeficitKcal": 500,
        "deficitFromRate": false,
        "weeklyLossKg": 0.45,
        "fatFreeMassKg": 58.2,
        "availabilityFloorKcal": 1800,
        "energyAvailability": 32.1,
        "proteinG": 140,
        "macros": {
          "proteinG": 140, "fatG": 70, "carbsG": 210, "fiberG": 30, "proteinPerKg": 1.9,
          "basePerKg": 1.9, "bonuses": [{"key": "deficit", "perKg": 0.15}],
          "proteinCapped": false, "proteinCutFloor": false,
          "proteinPerMealG": {"min": 30, "max": 40}, "proteinIntakes": 4,
          "fatFloorG": 60, "fatFromFloor": false, "fatCutForCarbs": false,
          "carbsFloorG": 150, "carbsBelowFloor": false,
          "shares": {"protein": 0.27, "fat": 0.3, "carbs": 0.4},
          "programme": {"name": "Sèche douce", "applied": ["protein"], "unmet": []}
        },
        "guard": "none",
        "detail": {
          "restingKcal": 1650, "watchActiveKcal": 950, "sessionKcal": 0,
          "activeKcal": 950, "sessions": []
        }
      },
      "settings": {
        "weeklyLossPct": 0.7, "deficitKcal": 500, "sportFactor": 1,
        "proteinPerKg": 1.9, "floorKcal": 1500, "weeklyAlertKcal": 600
      }
    }
    """.utf8)

private let unavailableTargetInfoJSON = Data(
    """
    {
      "date": "2026-09-23",
      "mode": "auto",
      "manual": {"kcal": 1800, "protein": null, "carbs": null, "fat": null, "fiber": null},
      "manualMin": {"kcal": null, "protein": null, "carbs": null, "fat": null, "fiber": null},
      "manualMax": {"kcal": null, "protein": null, "carbs": null, "fat": null, "fiber": null},
      "programme": null,
      "targets": {"kcal": 1800, "protein": null, "carbs": null, "fat": null, "fiber": null},
      "source": "manual",
      "auto": {
        "status": "unavailable",
        "source": "formula",
        "missing": ["weightKg"],
        "targetKcal": null,
        "expenditureKcal": null,
        "deficitKcal": null,
        "macros": {
          "proteinG": null, "fatG": null, "carbsG": null, "fiberG": null, "proteinPerKg": null,
          "basePerKg": 1.9, "bonuses": [], "proteinCapped": false, "proteinCutFloor": false,
          "proteinPerMealG": null, "proteinIntakes": null, "fatFloorG": null,
          "fatFromFloor": false, "fatCutForCarbs": false, "carbsFloorG": null,
          "carbsBelowFloor": false, "shares": null, "programme": null
        },
        "guard": "none",
        "detail": {"restingKcal": null, "watchActiveKcal": null, "sessionKcal": 0, "activeKcal": null, "sessions": []}
      },
      "settings": {
        "weeklyLossPct": 0.7, "deficitKcal": 500, "sportFactor": 1,
        "proteinPerKg": 1.9, "floorKcal": 1500, "weeklyAlertKcal": 600
      }
    }
    """.utf8)

private let weeklyJSON = Data(
    """
    {
      "days": [],
      "loggedDays": 5, "partialDays": 1, "emptyDays": 1,
      "avgDeficitKcal": 420, "avgIntakeKcal": 2100, "avgExpenditureKcal": 2520,
      "alert": false, "thresholdKcal": 600
    }
    """.utf8)

private let timingJSON = Data(
    """
    {
      "meal": {
        "lastMealTs": 1758620000, "digestionEndTs": 1758630000, "nextMealTs": 1758630000,
        "gymStartTs": 1758627200, "gymEndTs": 1758632600, "avgStress": 24, "windowH": 2.8
      }
    }
    """.utf8)

private let emptyTimingJSON = Data(#"{"meal": null}"#.utf8)

private let suggestionsJSON = Data(
    """
    {
      "remaining": {"kcal": 600, "protein": 40, "carbs": 80, "fat": null, "fiber": 10},
      "items": [
        {
          "foodId": 7, "name": "Fromage blanc", "grams": 200, "units": null,
          "unitLabel": null, "unitGrams": null,
          "kcal": 140, "protein": 24, "carbs": 8, "fiber": 0
        },
        {
          "foodId": 9, "name": "Pomme", "grams": 300, "units": 2,
          "unitLabel": "pièce", "unitGrams": 150,
          "kcal": 156, "protein": 0.6, "carbs": 42, "fiber": 6
        }
      ]
    }
    """.utf8)

private let noTargetSuggestionsJSON = Data(
    """
    {"remaining": {"kcal": null, "protein": null, "carbs": null, "fat": null, "fiber": null}, "items": [], "reason": "no-targets"}
    """.utf8)

private let frequentJSON = Data(
    """
    [
      {
        "foodId": 3, "name": "Yaourt nature", "uses": 12, "grams": 125,
        "units": 1, "unitLabel": "pot", "unitGrams": 125, "lastTs": 1758600000,
        "kcal": 60, "protein": 5.2, "carbs": 4, "fiber": 0, "fat": 2
      },
      {
        "foodId": null, "name": "Salade maison", "uses": 3, "grams": 250,
        "units": null, "unitLabel": null, "unitGrams": null, "lastTs": 1758500000,
        "kcal": 45, "protein": 1.5, "carbs": 6, "fiber": 2.1, "fat": 1.8
      }
    ]
    """.utf8)

// MARK: - Tests

struct NutritionScreenDecodingTests {
    @Test func decodesDayWithEntriesAndRanges() throws {
        let day = try JSONDecoder().decode(NutritionDay.self, from: dayJSON)
        #expect(day.date == "2026-09-23")
        #expect(day.entries.count == 2)
        #expect(day.entries.first?.name == "Poulet")
        #expect(day.entries.last?.unitQty == 1)
        #expect(day.totals.kcal == 508)
        #expect(day.targets.protein == 140)
        #expect(day.targetRanges?["protein"]?.min == 120)
        #expect(day.targetRanges?["carbs"]?.min == nil)
        #expect(day.targetRanges?["carbs"]?.max == 250)
        #expect(day.programme?.name == "Sèche douce")
        #expect(day.proteinPerKg == 0.74)
    }

    @Test func decodesEmptyDayWithNullTargets() throws {
        let day = try JSONDecoder().decode(NutritionDay.self, from: emptyDayJSON)
        #expect(day.entries.isEmpty)
        #expect(day.totals.kcal == 0)
        #expect(day.targets.protein == nil)
        #expect(day.targetRanges == nil)
        #expect(day.programme == nil)
        #expect(day.proteinPerKg == nil)
    }

    @Test func decodesOkTargetInfoIgnoringUnmodeledTopLevelFields() throws {
        let info = try JSONDecoder().decode(NutritionTargetInfo.self, from: targetInfoJSON)
        #expect(info.mode == "auto")
        #expect(info.source == "auto")
        #expect(info.targets.kcal == 2100)
        #expect(info.auto.status == "ok")
        #expect(info.auto.source == "watch")
        #expect(info.auto.targetKcal == 2100)
        #expect(info.auto.guardStatus == "none")
        #expect(info.auto.macros.proteinG == 140)
        #expect(info.auto.macros.programme?.name == "Sèche douce")
        #expect(info.auto.detail.activeKcal == 950)
    }

    @Test func decodesUnavailableTargetInfo() throws {
        let info = try JSONDecoder().decode(NutritionTargetInfo.self, from: unavailableTargetInfoJSON)
        #expect(info.auto.status == "unavailable")
        #expect(info.auto.missing == ["weightKg"])
        #expect(info.auto.targetKcal == nil)
        #expect(info.targets.kcal == 1800)
        #expect(info.source == "manual")
        #expect(info.auto.macros.programme == nil)
    }

    @Test func decodesWeekly() throws {
        let weekly = try JSONDecoder().decode(NutritionWeekly.self, from: weeklyJSON)
        #expect(weekly.loggedDays == 5)
        #expect(weekly.avgDeficitKcal == 420)
        #expect(weekly.alert == false)
        #expect(weekly.thresholdKcal == 600)
    }

    @Test func decodesTimingWithMeal() throws {
        let timing = try JSONDecoder().decode(NutritionTimingResponse.self, from: timingJSON)
        #expect(timing.meal?.lastMealTs == 1758620000)
        #expect(timing.meal?.avgStress == 24)
        #expect(timing.meal?.windowH == 2.8)
    }

    @Test func decodesTimingWithoutMeal() throws {
        let timing = try JSONDecoder().decode(NutritionTimingResponse.self, from: emptyTimingJSON)
        #expect(timing.meal == nil)
    }

    @Test func decodesSuggestions() throws {
        let response = try JSONDecoder().decode(NutritionSuggestionsResponse.self, from: suggestionsJSON)
        #expect(response.items.count == 2)
        #expect(response.remaining.kcal == 600)
        #expect(response.items.first?.name == "Fromage blanc")
        #expect(response.items.last?.units == 2)
        #expect(response.items.last?.unitGrams == 150)
        #expect(response.reason == nil)
    }

    @Test func decodesSuggestionsWithNoTargets() throws {
        let response = try JSONDecoder().decode(NutritionSuggestionsResponse.self, from: noTargetSuggestionsJSON)
        #expect(response.items.isEmpty)
        #expect(response.reason == "no-targets")
        #expect(response.remaining.kcal == nil)
    }

    @Test func decodesFrequentFoodsWithAndWithoutFoodId() throws {
        let foods = try JSONDecoder().decode([NutritionFrequentFood].self, from: frequentJSON)
        #expect(foods.count == 2)
        #expect(foods.first?.foodId == 3)
        #expect(foods.first?.id == "3")
        #expect(foods.last?.foodId == nil)
        #expect(foods.last?.id == "Salade maison")
        #expect(foods.last?.kcal == 45)
    }
}

// MARK: - Encodage du corps de log (sans réseau)

struct NutritionLogRequestEncodingTests {
    @Test func encodesGramsPortionRequest() throws {
        var body = NutritionLogRequest(date: "2026-09-23", name: "Test")
        body.foodId = 3
        body.grams = 125
        body.kcal = 60
        body.ts = 1758600000

        let data = try JSONEncoder().encode(body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["date"] as? String == "2026-09-23")
        #expect(object?["grams"] as? Double == 125)
        #expect(object?["foodId"] as? Int == 3)
        #expect(object?["units"] == nil || object?["units"] is NSNull)
    }

    @Test func encodesUnitsPortionRequest() throws {
        var body = NutritionLogRequest(date: "2026-09-23", name: "Pomme")
        body.foodId = 9
        body.units = 2
        body.unitLabel = "pièce"
        body.unitGrams = 150

        let data = try JSONEncoder().encode(body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["units"] as? Double == 2)
        #expect(object?["unitLabel"] as? String == "pièce")
        #expect(object?["grams"] == nil || object?["grams"] is NSNull)
    }
}
