//
//  SettingsScreenTests.swift
//  allTests
//
//  Décodage des modèles de l'écran Paramètres
//  (`Pulse/Screens/Settings/SettingsModels.swift`) contre des fixtures JSON
//  écrites à la main, dans la forme exacte renvoyée par NestJS
//  (`custom-connect/server/src/sync/sync.controller.ts`,
//  `sync/sync.types.ts`, `profile/profile.controller.ts`) — jamais de réseau
//  réel (règle immuable du dépôt) : on décode directement
//  `PulseAPIClient.decoder` sur des `Data` littérales.
//

import Testing
import Foundation
@testable import all

// MARK: - Fixtures — `GET /api/sync/source`

private let legacySourceJSON = Data(
    """
    {
      "source": "legacy",
      "configured": "legacy",
      "overridden": false,
      "url": "http://garmin-bridge.local:8080",
      "reachable": null,
      "detail": null
    }
    """.utf8)

private let bridgeSourceReachableJSON = Data(
    """
    {
      "source": "bridge",
      "configured": "legacy",
      "overridden": true,
      "url": "http://garmin-bridge.local:8080",
      "reachable": true,
      "detail": null,
      "ingestToken": null
    }
    """.utf8)

private let bridgeSourceUnreachableJSON = Data(
    """
    {
      "source": "bridge",
      "configured": "bridge",
      "overridden": false,
      "url": "http://garmin-bridge.local:8080",
      "reachable": false,
      "detail": "connect ECONNREFUSED",
      "ingestToken": null
    }
    """.utf8)

private let phoneSourceJSON = Data(
    """
    {
      "source": "phone",
      "configured": "legacy",
      "overridden": true,
      "url": "http://garmin-bridge.local:8080",
      "reachable": null,
      "detail": null,
      "ingestToken": "8f3c1e2a9b7d4f0e"
    }
    """.utf8)

// MARK: - Fixtures — `GET /api/sync/status`

private let idleStatusJSON = Data(
    """
    {
      "state": "idle",
      "at": null,
      "lastSuccess": "2026-09-22T08:14:00.000Z",
      "message": null,
      "progress": null,
      "freshness": {"at": "2026-09-22T22:03:00.000Z", "ageSec": 41220}
    }
    """.utf8)

private let runningStatusWithProgressJSON = Data(
    """
    {
      "state": "running",
      "at": "2026-09-23T09:00:00.000Z",
      "lastSuccess": "2026-09-22T08:14:00.000Z",
      "message": null,
      "progress": {"startedAt": "2026-09-23T09:00:00.000Z", "watchFiles": 12, "remainingOnWatch": 5},
      "freshness": {"at": null, "ageSec": null}
    }
    """.utf8)

private let errorStatusJSON = Data(
    """
    {
      "state": "error",
      "at": "2026-09-23T09:05:00.000Z",
      "lastSuccess": null,
      "message": "garmin-bridge injoignable",
      "progress": null,
      "freshness": {"at": null, "ageSec": null}
    }
    """.utf8)

// MARK: - Fixtures — `GET /api/sync/inventory`

private let inventoryJSON = Data(
    """
    {
      "onDisk": 214,
      "activities": 180,
      "sleepFiles": 22,
      "wellnessFiles": 12,
      "unaccounted": 0,
      "nights": 22,
      "days": 30
    }
    """.utf8)

// MARK: - Fixtures — `GET /api/profile`

private let completeProfileJSON = Data(
    """
    {"birthYear": 1994, "sex": "male", "weightKg": 78.4, "heightCm": 181}
    """.utf8)

private let incompleteProfileJSON = Data(
    """
    {"birthYear": null, "sex": null, "weightKg": null, "heightCm": null}
    """.utf8)

// MARK: - Tests de décodage

struct SettingsScreenDecodingTests {
    @Test func decodesLegacySourceWithNullReachability() throws {
        let source = try PulseAPIClient.decoder.decode(SettingsSyncSource.self, from: legacySourceJSON)
        #expect(source.source == "legacy")
        #expect(source.configured == "legacy")
        #expect(source.overridden == false)
        #expect(source.reachable == nil)
        #expect(source.detail == nil)
        #expect(source.ingestToken == nil)
    }

    @Test func decodesBridgeSourceReachable() throws {
        let source = try PulseAPIClient.decoder.decode(SettingsSyncSource.self, from: bridgeSourceReachableJSON)
        #expect(source.source == "bridge")
        #expect(source.overridden == true)
        #expect(source.reachable == true)
        #expect(source.url == "http://garmin-bridge.local:8080")
    }

    @Test func decodesBridgeSourceUnreachableWithDetail() throws {
        let source = try PulseAPIClient.decoder.decode(SettingsSyncSource.self, from: bridgeSourceUnreachableJSON)
        #expect(source.reachable == false)
        #expect(source.detail == "connect ECONNREFUSED")
        #expect(source.overridden == false)
    }

    @Test func decodesPhoneSourceWithIngestToken() throws {
        let source = try PulseAPIClient.decoder.decode(SettingsSyncSource.self, from: phoneSourceJSON)
        #expect(source.source == "phone")
        #expect(source.ingestToken == "8f3c1e2a9b7d4f0e")
        #expect(source.configured == "legacy")
        #expect(source.overridden == true)
    }

    @Test func decodesIdleStatusWithoutProgress() throws {
        let status = try PulseAPIClient.decoder.decode(SettingsSyncStatus.self, from: idleStatusJSON)
        #expect(status.state == "idle")
        #expect(status.progress == nil)
        #expect(status.lastSuccess == "2026-09-22T08:14:00.000Z")
        #expect(status.freshness.ageSec == 41220)
    }

    @Test func decodesRunningStatusWithProgress() throws {
        let status = try PulseAPIClient.decoder.decode(SettingsSyncStatus.self, from: runningStatusWithProgressJSON)
        #expect(status.state == "running")
        #expect(status.progress?.watchFiles == 12)
        #expect(status.progress?.remainingOnWatch == 5)
        #expect(status.freshness.at == nil)
        #expect(status.freshness.ageSec == nil)
    }

    @Test func decodesErrorStatusWithMessage() throws {
        let status = try PulseAPIClient.decoder.decode(SettingsSyncStatus.self, from: errorStatusJSON)
        #expect(status.state == "error")
        #expect(status.message == "garmin-bridge injoignable")
        #expect(status.lastSuccess == nil)
    }

    @Test func decodesInventory() throws {
        let inventory = try PulseAPIClient.decoder.decode(SettingsSyncInventory.self, from: inventoryJSON)
        #expect(inventory.onDisk == 214)
        #expect(inventory.activities == 180)
        #expect(inventory.nights == 22)
        #expect(inventory.days == 30)
    }

    @Test func decodesCompleteProfile() throws {
        let profile = try PulseAPIClient.decoder.decode(SettingsProfile.self, from: completeProfileJSON)
        #expect(profile.birthYear == 1994)
        #expect(profile.sex == "male")
        #expect(profile.weightKg == 78.4)
        #expect(profile.heightCm == 181)
    }

    @Test func decodesIncompleteProfileAsAllNil() throws {
        let profile = try PulseAPIClient.decoder.decode(SettingsProfile.self, from: incompleteProfileJSON)
        #expect(profile.birthYear == nil)
        #expect(profile.sex == nil)
        #expect(profile.weightKg == nil)
        #expect(profile.heightCm == nil)
    }
}

// MARK: - Tests d'encodage des corps de requête (sans réseau)

struct SettingsRequestEncodingTests {
    @Test func encodesSourceUpdateRequest() throws {
        let body = SettingsSyncSourceUpdateRequest(source: "phone")
        let data = try PulseAPIClient.encoder.encode(body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["source"] as? String == "phone")
        #expect(object?.count == 1)
    }

    @Test func encodesProfileUpdateOmittingNilHeight() throws {
        let body = SettingsProfileUpdateRequest(birthYear: 1994, sex: "male")
        let data = try PulseAPIClient.encoder.encode(body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["birthYear"] as? Int == 1994)
        #expect(object?["sex"] as? String == "male")
        #expect(object?["heightCm"] == nil)
    }

    @Test func encodesProfileUpdateWithHeight() throws {
        var body = SettingsProfileUpdateRequest(birthYear: 1994, sex: "female")
        body.heightCm = 168.5
        let data = try PulseAPIClient.encoder.encode(body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["heightCm"] as? Double == 168.5)
    }
}
