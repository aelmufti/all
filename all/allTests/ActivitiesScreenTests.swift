//
//  ActivitiesScreenTests.swift
//  allTests
//
//  Tests de décodage de l'écran Activités — fixtures JSON en dur, calquées
//  sur la forme exacte renvoyée par `activities.controller.ts` (colonnes SQL
//  aliasées en camelCase + sortie de `FitParserService.parseDetail`).
//  **Aucun réseau** : pas de `PulseAPIClient`/`URLSession` ici, uniquement
//  `JSONDecoder().decode` sur des `Data` littérales, plus quelques vérifs des
//  helpers de format (`ActivityFormat`, `ActivitySport`, `ActivityDateFormatting`).
//

import Testing
import Foundation
@testable import all

// MARK: - Fixtures

private let listFixtureJSON = Data("""
{
  "total": 2,
  "items": [
    {
      "id": 42,
      "fileName": "42_ACTIVITY.fit",
      "sport": "running",
      "subSport": "trail",
      "startTime": "2026-09-22T07:15:00.000Z",
      "durationS": 3612.5,
      "distanceM": 10234.7,
      "calories": 612,
      "avgHr": 152,
      "maxHr": 178
    },
    {
      "id": 41,
      "fileName": "41_ACTIVITY.fit",
      "sport": "training",
      "subSport": "strengthTraining",
      "startTime": null,
      "durationS": null,
      "distanceM": null,
      "calories": null,
      "avgHr": null,
      "maxHr": null
    }
  ]
}
""".utf8)

/// Détail complet — fichier `.fit` toujours présent côté serveur.
private let detailFixtureJSON = Data("""
{
  "id": 42,
  "fileName": "42_ACTIVITY.fit",
  "sport": "running",
  "subSport": "trail",
  "startTime": "2026-09-22T07:15:00.000Z",
  "durationS": 3612.5,
  "distanceM": 10234.7,
  "calories": 612,
  "avgHr": 152,
  "maxHr": 178,
  "track": [[45.75, 4.85], [45.751, 4.851]],
  "streams": {
    "time": [0, 10, null, 30],
    "hr": [120, 130, null, 150],
    "speed": [2.5, 2.7, null, 3.0],
    "altitude": [200.0, 201.5, null, 205.0],
    "distance": [0, 25, null, 75]
  },
  "laps": [
    { "index": 1, "durationS": 600, "distanceM": 2000, "avgHr": 140, "maxHr": 160 },
    { "index": 2, "durationS": 620.4, "distanceM": 2100, "avgHr": 145, "maxHr": 165 }
  ],
  "sets": [
    { "index": 1, "durationS": 45, "category": "squat", "repetitions": 12 },
    { "index": 2, "durationS": 40, "category": null, "repetitions": null }
  ],
  "splits": [
    { "index": 1, "type": "climbActive", "durationS": 120, "ascentM": 15, "descentM": 0, "calories": 20, "avgVertSpeedMs": 0.12 },
    { "index": 2, "type": "climbRest", "durationS": 60, "ascentM": null, "descentM": null, "calories": null, "avgVertSpeedMs": null }
  ],
  "hrZones": [
    { "zone": 1, "seconds": 300, "fromBpm": 90, "toBpm": 120 },
    { "zone": 2, "seconds": 900, "fromBpm": 120, "toBpm": 150 },
    { "zone": 3, "seconds": 600, "fromBpm": 150, "toBpm": 170 }
  ]
}
""".utf8)

/// Détail "fichier absent" — branche `!fs.existsSync(filePath)` du contrôleur :
/// résumé seul, `streams` explicitement `null`, tout le reste vide.
private let detailEmptyFixtureJSON = Data("""
{
  "id": 7,
  "fileName": "7_ACTIVITY.fit",
  "sport": "cycling",
  "subSport": null,
  "startTime": "2026-08-01T12:00:00.000Z",
  "durationS": 1800,
  "distanceM": 15000,
  "calories": 300,
  "avgHr": null,
  "maxHr": null,
  "track": [],
  "streams": null,
  "laps": [],
  "sets": [],
  "splits": [],
  "hrZones": []
}
""".utf8)

// MARK: - Décodage : liste

@Suite
struct ActivityListDecodingTests {
    @Test func decodesListResponse() throws {
        let response = try PulseAPIClient.decoder.decode(ActivityListResponse.self, from: listFixtureJSON)
        #expect(response.total == 2)
        #expect(response.items.count == 2)
    }

    @Test func decodesFullActivity() throws {
        let response = try PulseAPIClient.decoder.decode(ActivityListResponse.self, from: listFixtureJSON)
        let first = response.items[0]
        #expect(first.id == 42)
        #expect(first.sport == "running")
        #expect(first.subSport == "trail")
        #expect(first.startTime == "2026-09-22T07:15:00.000Z")
        #expect(first.durationS == 3612.5)
        #expect(first.avgHr == 152)
    }

    @Test func decodesActivityWithNullOptionalFields() throws {
        let response = try PulseAPIClient.decoder.decode(ActivityListResponse.self, from: listFixtureJSON)
        let second = response.items[1]
        #expect(second.id == 41)
        #expect(second.startTime == nil)
        #expect(second.durationS == nil)
        #expect(second.avgHr == nil)
    }
}

// MARK: - Décodage : détail

@Suite
struct ActivityDetailDecodingTests {
    @Test func decodesSummaryFields() throws {
        let detail = try PulseAPIClient.decoder.decode(ActivityDetail.self, from: detailFixtureJSON)
        #expect(detail.id == 42)
        #expect(detail.sport == "running")
        #expect(detail.distanceM == 10234.7)
    }

    @Test func decodesTrackAsCoordinatePairs() throws {
        let detail = try PulseAPIClient.decoder.decode(ActivityDetail.self, from: detailFixtureJSON)
        #expect(detail.track.count == 2)
        #expect(detail.track[0] == [45.75, 4.85])
    }

    @Test func decodesStreamsWithNullHoles() throws {
        let detail = try PulseAPIClient.decoder.decode(ActivityDetail.self, from: detailFixtureJSON)
        let streams = try #require(detail.streams)
        #expect(streams.hr.count == 4)
        #expect(streams.hr[2] == nil)
        #expect(streams.hr[1] == 130)
    }

    @Test func decodesLapsSetsSplitsAndZones() throws {
        let detail = try PulseAPIClient.decoder.decode(ActivityDetail.self, from: detailFixtureJSON)
        #expect(detail.laps.count == 2)
        #expect(detail.laps[1].durationS == 620.4)
        #expect(detail.sets.count == 2)
        #expect(detail.sets[0].category == "squat")
        #expect(detail.splits.filter { $0.type == "climbActive" }.count == 1)
        #expect(detail.hrZones.count == 3)
        #expect(detail.hrZones[1].fromBpm == 120)
    }

    @Test func decodesEmptyDetailFallback() throws {
        let detail = try PulseAPIClient.decoder.decode(ActivityDetail.self, from: detailEmptyFixtureJSON)
        #expect(detail.streams == nil)
        #expect(detail.track.isEmpty)
        #expect(detail.laps.isEmpty)
        #expect(detail.hrZones.isEmpty)
        #expect(detail.sport == "cycling")
    }
}

// MARK: - Helpers de format

@Suite
struct ActivityFormattingTests {
    @Test func durationSwitchesToHoursPastOneHour() {
        #expect(ActivityFormat.duration(725) == "12min05")
        #expect(ActivityFormat.duration(3900) == "1h05")
        #expect(ActivityFormat.duration(nil) == "—")
    }

    @Test func shortDurationStaysInMinutesUnderOneHour() {
        #expect(ActivityFormat.shortDuration(725) == "12 min")
        #expect(ActivityFormat.shortDuration(3900) == "1h05")
    }

    @Test func paceRequiresMeaningfulDistance() {
        #expect(ActivityFormat.pace(durationS: 1800, distanceM: 5000) == "6'00\"/km")
        #expect(ActivityFormat.pace(durationS: 1800, distanceM: 50) == "—")
        #expect(ActivityFormat.pace(durationS: nil, distanceM: 5000) == "—")
    }

    @Test func distanceKmUsesFrenchDecimalComma() {
        #expect(ActivityFormat.distanceKm(10234.7) == "10,23 km")
        #expect(ActivityFormat.distanceKm(0) == nil)
    }

    @Test func clockFormatsHoursOnlyWhenPresent() {
        #expect(ActivityFormat.clock(65) == "1:05")
        #expect(ActivityFormat.clock(3723) == "1:02:03")
    }

    @Test func sportLabelPrefersKnownSubSport() {
        #expect(ActivitySport.label(sport: "running", subSport: "trail") == "Trail")
        #expect(ActivitySport.label(sport: "running", subSport: "generic") == "Course à pied")
        #expect(ActivitySport.label(sport: "running", subSport: nil) == "Course à pied")
        #expect(ActivitySport.label(sport: nil, subSport: nil) == "Autre")
    }

    @Test func dateParsingHandlesFractionalAndPlainISO8601() {
        #expect(ActivityDateFormatting.date(from: "2026-09-22T07:15:00.000Z") != nil)
        #expect(ActivityDateFormatting.date(from: "2026-09-22T07:15:00Z") != nil)
        #expect(ActivityDateFormatting.date(from: nil) == nil)
        #expect(ActivityDateFormatting.date(from: "pas une date") == nil)
    }
}
