//
//  HomeScreenTests.swift
//  allTests
//
//  Tests de décodage de l'écran Accueil (`Pulse/Screens/Home/`) — fixtures
//  JSON en dur, **aucun réseau**. Les fixtures reprennent la forme réelle des
//  réponses NestJS (avec des champs non modélisés, ex. `counterSeries`,
//  `bodyBatteryPivot`, `sleep` sur `HomeDayDetail`, ou les clés propres au
//  domaine `sleep` sur `HomeProgrammeDetail`) pour vérifier que les modèles
//  restreints du socle Accueil décodent bien un sous-ensemble sans échouer
//  sur les clés en trop.
//
//  Complète les tests de calcul purs (`HomeViewModel` — fonctions statiques
//  de date/format), eux aussi sans réseau ni instanciation du view-model.
//

import Testing
import Foundation
@testable import all

// MARK: - Fixtures

private let dayDetailJSON = Data(
    """
    {
      "date": "2026-09-23",
      "summary": {
        "restingHr": 52,
        "bmrKcal": 1650,
        "bodyBatteryHigh": 80,
        "bodyBatteryLow": 20,
        "steps": 4213,
        "activeCalories": 210,
        "distanceM": 3120,
        "sportCalories": 300
      },
      "counterSeries": [],
      "hr": [
        {"ts": 1758600000, "value": 61},
        {"ts": 1758600300, "value": 64.4}
      ],
      "stress": [{"ts": 1758600000, "value": 22}],
      "spo2": [{"ts": 1758600000, "value": 97}],
      "respiration": [{"ts": 1758600000, "value": 14.5}],
      "bodyBatteryPivot": [],
      "activities": [],
      "sleep": {"segments": [], "main": null, "stages": [], "score": null}
    }
    """.utf8)

private let emptyDayDetailJSON = Data(
    """
    {
      "date": "2026-09-23",
      "summary": {"restingHr": null},
      "counterSeries": [],
      "hr": [], "stress": [], "spo2": [], "respiration": [],
      "bodyBatteryPivot": [], "activities": [],
      "sleep": {"segments": [], "main": null, "stages": [], "score": null}
    }
    """.utf8)

private let activityListJSON = Data(
    """
    {
      "total": 2,
      "items": [
        {
          "id": 101, "fileName": "A.FIT", "sport": "running", "subSport": null,
          "startTime": "2026-09-22T07:15:00.000Z", "durationS": 1800,
          "distanceM": 5000, "calories": 320, "avgHr": 145, "maxHr": 168
        },
        {
          "id": 102, "fileName": "B.FIT", "sport": "cycling", "subSport": "road",
          "startTime": "2026-09-20T09:00:00Z", "durationS": 3600,
          "distanceM": 20000, "calories": 500, "avgHr": 130, "maxHr": 150
        }
      ]
    }
    """.utf8)

private let intensityReportJSON = Data(
    """
    {
      "today": {"date": "2026-09-23", "minutes": 12.5, "moderateMin": 10, "vigorousMin": 2.5, "cumulative": 40},
      "current": {
        "week": "2026-09-21", "minutes": 40, "moderateMin": 30, "vigorousMin": 10,
        "coverage": 0.92, "valid": true, "goal": 150, "light": false, "reason": "held",
        "manual": false, "pinned": false, "pace": 65,
        "days": [
          {"date": "2026-09-21", "minutes": 15, "moderateMin": 15, "vigorousMin": 0, "cumulative": 15},
          {"date": "2026-09-22", "minutes": 25, "moderateMin": 15, "vigorousMin": 10, "cumulative": 40}
        ]
      },
      "next": null,
      "history": [],
      "params": {}
    }
    """.utf8)

private let programmeResponseJSON = Data(
    """
    {
      "domains": [
        {
          "kind": "training",
          "choices": [],
          "active": {
            "programmeId": "p1", "startedOn": "2026-09-01", "name": "Base",
            "goal": "endurance", "source": "custom", "week": 3, "weeks": 8,
            "days": [1, 3, 5], "perWeek": 3, "notes": null
          },
          "detail": {
            "focus": [{"index": 3, "focus": "Endurance fondamentale"}],
            "sessions": [
              {
                "week": 3,
                "session": {
                  "name": "Sortie longue", "minMinutes": 60,
                  "items": [{"name": "Échauffement", "prescription": "10 min zone 2", "note": null}]
                },
                "plannedOn": "2026-09-23", "status": "today", "done": false,
                "date": null, "activityId": null
              }
            ],
            "done": 5, "total": 9, "missed": 1
          }
        },
        {
          "kind": "sleep",
          "choices": [],
          "active": {
            "programmeId": "p2", "startedOn": "2026-08-01", "name": "Régularité",
            "goal": "sleep", "source": "custom", "week": 4, "weeks": 12,
            "days": [], "perWeek": 7, "notes": null
          },
          "detail": {
            "nights": 12, "to": "2026-09-22", "staleDays": 0,
            "axis": {"onsetMean": 1350, "onsetSd": 20},
            "strip": [], "metrics": [], "hits": 8, "total": 10
          }
        }
      ]
    }
    """.utf8)

private let liveHeartRateJSON = Data(
    """
    {
      "reachable": true, "detail": null, "enabled": true, "broadcasting": true,
      "heartRate": 88, "measuredAt": "2026-09-23T10:15:00.000Z", "stale": false, "hint": null
    }
    """.utf8)

private let silentLiveHeartRateJSON = Data(
    """
    {"reachable": false, "detail": "Source « Téléphone » active", "enabled": false,
     "broadcasting": false, "heartRate": null, "measuredAt": null, "stale": false, "hint": null}
    """.utf8)

// MARK: - Tests de décodage

@Suite
struct HomeScreenDecodingTests {

    @Test func decodesDayDetailIgnoringUnmodeledFields() throws {
        let day = try JSONDecoder().decode(HomeDayDetail.self, from: dayDetailJSON)
        #expect(day.date == "2026-09-23")
        #expect(day.summary.restingHr == 52)
        #expect(day.hr.count == 2)
        #expect(day.hr.last?.value == 64.4)
        #expect(day.stress.first?.value == 22)
        #expect(day.spo2.first?.value == 97)
        #expect(day.respiration.first?.value == 14.5)
        #expect(day.hasData)
    }

    @Test func emptyDayDetailHasNoData() throws {
        let day = try JSONDecoder().decode(HomeDayDetail.self, from: emptyDayDetailJSON)
        #expect(!day.hasData)
        #expect(day.summary.restingHr == nil)
    }

    @Test func decodesActivityListResponse() throws {
        let response = try JSONDecoder().decode(HomeActivityListResponse.self, from: activityListJSON)
        #expect(response.total == 2)
        #expect(response.items.count == 2)
        #expect(response.items.first?.id == 101)
        #expect(response.items.first?.durationS == 1800)
        #expect(response.items.last?.startTime == "2026-09-20T09:00:00Z")
    }

    @Test func decodesIntensityReport() throws {
        let report = try JSONDecoder().decode(HomeIntensityReport.self, from: intensityReportJSON)
        #expect(report.today.cumulative == 40)
        #expect(report.current.goal == 150)
        #expect(report.current.reason == .held)
        #expect(report.current.days.count == 2)
        #expect(report.current.days.last?.cumulative == 40)
    }

    @Test func decodesProgrammeResponseKeepingOnlyModeledDetailFields() throws {
        let response = try JSONDecoder().decode(HomeProgrammeResponse.self, from: programmeResponseJSON)
        #expect(response.domains.count == 2)

        let training = response.domains.first { $0.kind == "training" }
        #expect(training?.active?.week == 3)
        #expect(training?.active?.weeks == 8)
        #expect(training?.detail?.sessions?.count == 1)
        #expect(training?.detail?.sessions?.first?.session.name == "Sortie longue")
        #expect(training?.detail?.done == 5)
        #expect(training?.detail?.total == 9)
        #expect(training?.detail?.missed == 1)

        // Le domaine `sleep` a une forme de `detail` totalement différente
        // (axis/strip/metrics) : tous les champs modélisés (training) restent
        // `nil` sans faire échouer le décodage.
        let sleep = response.domains.first { $0.kind == "sleep" }
        #expect(sleep?.detail?.sessions == nil)
        #expect(sleep?.detail?.focus == nil)
    }

    @Test func decodesLiveHeartRate() throws {
        let live = try JSONDecoder().decode(HomeLiveHeartRate.self, from: liveHeartRateJSON)
        #expect(live.reachable)
        #expect(live.enabled)
        #expect(live.heartRate == 88)
        #expect(!live.stale)
    }

    @Test func decodesSilentLiveHeartRateWhenSourceIsNotPhone() throws {
        let live = try JSONDecoder().decode(HomeLiveHeartRate.self, from: silentLiveHeartRateJSON)
        #expect(!live.reachable)
        #expect(!live.enabled)
        #expect(live.heartRate == nil)
        #expect(live.detail != nil)
    }
}

// MARK: - Tests des fonctions de calcul pures (`HomeViewModel`)

@Suite
@MainActor
struct HomeViewModelFormattingTests {

    @Test func spanLabelFormatsMinutesAndHours() {
        #expect(HomeViewModel.spanLabel(0) == "0 min")
        #expect(HomeViewModel.spanLabel(45) == "45 min")
        #expect(HomeViewModel.spanLabel(60) == "1 h")
        #expect(HomeViewModel.spanLabel(95) == "1 h 35")
    }

    @Test func shortDateExtractsDayAndMonth() {
        #expect(HomeViewModel.shortDate("2026-09-23") == "23/09")
    }

    @Test func whenLabelReturnsAujourdhuiForToday() {
        #expect(HomeViewModel.whenLabel("2026-09-23", today: "2026-09-23") == "aujourd'hui")
    }

    @Test func whenLabelReturnsDemainForTomorrow() {
        #expect(HomeViewModel.whenLabel("2026-09-24", today: "2026-09-23") == "demain")
    }

    @Test func whenLabelFlagsOverdueSessions() {
        #expect(HomeViewModel.whenLabel("2026-09-20", today: "2026-09-23") == "en retard depuis le 20/09")
    }

    @Test func whenLabelReturnsNilWhenNoDatePlanned() {
        #expect(HomeViewModel.whenLabel(nil, today: "2026-09-23") == nil)
    }

    @Test func sessionMetaJoinsWeekProgressAndMisses() {
        let detail = HomeProgrammeDetail(focus: nil, sessions: nil, done: 5, total: 9, missed: 2)
        let meta = HomeViewModel.sessionMeta(week: 3, weeks: 8, detail: detail)
        #expect(meta == "semaine 3 sur 8 · 5 séances sur 9 · 2 en retard")
    }

    @Test func sessionMetaWithoutWeeksOrMisses() {
        let detail = HomeProgrammeDetail(focus: nil, sessions: nil, done: 1, total: 0, missed: 0)
        let meta = HomeViewModel.sessionMeta(week: 1, weeks: 0, detail: detail)
        #expect(meta == "semaine 1")
    }

    @Test func startOfWeekAlignsOnMonday() {
        // Mercredi 23 septembre 2026 → lundi 21 septembre 2026.
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 23
        components.hour = 12
        let wednesday = Calendar.current.date(from: components)!
        let monday = HomeViewModel.startOfWeek(wednesday)
        let mondayComponents = Calendar.current.dateComponents([.year, .month, .day], from: monday)
        #expect(mondayComponents.day == 21)
        #expect(mondayComponents.month == 9)
    }

    @Test func goalReasonLabelsAreNonEmptyForEveryCase() {
        for reason: IntensityGoalReason in [.seed, .raised, .lowered, .light, .held, .pinned, .skipped] {
            #expect(!HomeViewModel.goalReasonLabel(reason).isEmpty)
        }
    }
}
