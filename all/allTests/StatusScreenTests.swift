//
//  StatusScreenTests.swift
//  allTests
//
//  Décodage des modèles de l'écran Statut (`Pulse/Screens/Status/StatusModels.swift`)
//  contre des fixtures JSON écrites à la main, dans la forme exacte renvoyée
//  par NestJS (`custom-connect/server/src/sync/sync.controller.ts`,
//  `sync/sync.types.ts`, `health.controller.ts`) — jamais de réseau réel
//  (règle immuable du dépôt) : on décode directement `PulseAPIClient.decoder`
//  sur des `Data` littérales, sans `URLSession` ni stub `URLProtocol`.
//

import Testing
import Foundation
@testable import all

struct StatusScreenTests {

    // MARK: - `GET api/sync/link` / `POST api/sync/link/connect`

    @Test func decodesLinkStateConnected() throws {
        let json = Data("""
        {
          "reachable": true,
          "detail": null,
          "link": {
            "connected": true,
            "lastSeenAt": "2026-09-23T10:14:58.120Z",
            "rssi": -58,
            "rssiAt": "2026-09-23T10:14:58.120Z",
            "failures": 0,
            "nextAttemptAt": null,
            "error": null,
            "recovery": null
          }
        }
        """.utf8)

        let state = try PulseAPIClient.decoder.decode(StatusLinkState.self, from: json)

        #expect(state.reachable == true)
        #expect(state.link.connected == true)
        #expect(state.link.rssi == -58)
        #expect(state.link.recovery == nil)
    }

    /// Source `legacy`/`phone` active : le lien BLE n'est pas piloté par
    /// l'app, `SyncController.readLink` renvoie `reachable: false` avec un
    /// `link` entièrement inconnu (`unknownLink()`).
    @Test func decodesLinkStateUnreachableWithUnknownLink() throws {
        let json = Data("""
        {
          "reachable": false,
          "detail": "Source legacy active : le lien BLE n'est pas piloté par l'application.",
          "link": {
            "connected": null,
            "lastSeenAt": null,
            "rssi": null,
            "rssiAt": null,
            "failures": null,
            "nextAttemptAt": null,
            "error": null,
            "recovery": null
          }
        }
        """.utf8)

        let state = try PulseAPIClient.decoder.decode(StatusLinkState.self, from: json)

        #expect(state.reachable == false)
        #expect(state.link.connected == nil)
        #expect(state.detail?.contains("legacy") == true)
    }

    /// Contrôleur Bluetooth bloqué : `recovery.inProgress` prime sur le reste.
    @Test func decodesLinkStateWithRecoveryInProgress() throws {
        let json = Data("""
        {
          "reachable": true,
          "detail": null,
          "link": {
            "connected": false,
            "lastSeenAt": "2026-09-23T09:00:00.000Z",
            "rssi": null,
            "rssiAt": null,
            "failures": 4,
            "nextAttemptAt": "2026-09-23T10:20:00.000Z",
            "error": "GATT timeout",
            "recovery": {"inProgress": true, "requestedAt": "2026-09-23T10:15:00.000Z", "outcome": null}
          }
        }
        """.utf8)

        let state = try PulseAPIClient.decoder.decode(StatusLinkState.self, from: json)

        #expect(state.link.recovery?.inProgress == true)
        #expect(state.link.failures == 4)
        #expect(state.link.error == "GATT timeout")
    }

    // MARK: - `GET api/health/detail`

    @Test func decodesHealthDetailBridgeSource() throws {
        let json = Data("""
        {
          "status": "ok",
          "sync": {
            "pending": 3,
            "stalled": false,
            "cycles": 0,
            "source": "bridge",
            "enabled": true,
            "since": null,
            "reason": null,
            "presence": "proche",
            "link": {
              "connected": true,
              "lastSeenAt": "2026-09-23T10:14:58.120Z",
              "rssi": -58,
              "rssiAt": "2026-09-23T10:14:58.120Z",
              "failures": 0,
              "nextAttemptAt": "2026-09-23T10:20:00.000Z",
              "error": null,
              "recovery": null
            },
            "lastSuccess": "2026-09-23T09:50:00.000Z",
            "nextAttemptAt": "2026-09-23T10:20:00.000Z",
            "intervalMs": 300000
          }
        }
        """.utf8)

        let detail = try PulseAPIClient.decoder.decode(StatusHealthDetail.self, from: json)

        #expect(detail.status == "ok")
        #expect(detail.sync.pending == 3)
        #expect(detail.sync.source == .bridge)
        #expect(detail.sync.presence == .proche)
        #expect(detail.sync.intervalMs == 300_000)
        #expect(detail.sync.link.connected == true)
    }

    /// Source `phone` (bridge-connect pousse) ou `legacy` : `stalled`/`reason`
    /// peuvent être renseignés et `since` non nul.
    @Test func decodesHealthDetailStalled() throws {
        let json = Data("""
        {
          "status": "ok",
          "sync": {
            "pending": 12,
            "stalled": true,
            "cycles": 8,
            "source": "phone",
            "enabled": true,
            "since": "2026-09-23T09:00:00.000Z",
            "reason": "aucun watchFiles depuis 8 cycles",
            "presence": "absente",
            "link": {
              "connected": null, "lastSeenAt": null, "rssi": null, "rssiAt": null,
              "failures": null, "nextAttemptAt": null, "error": null, "recovery": null
            },
            "lastSuccess": null,
            "nextAttemptAt": "2026-09-23T10:30:00.000Z",
            "intervalMs": 900000
          }
        }
        """.utf8)

        let detail = try PulseAPIClient.decoder.decode(StatusHealthDetail.self, from: json)

        #expect(detail.sync.stalled == true)
        #expect(detail.sync.source == .phone)
        #expect(detail.sync.presence == .absente)
        #expect(detail.sync.reason == "aucun watchFiles depuis 8 cycles")
        #expect(detail.sync.lastSuccess == nil)
    }

    // MARK: - `GET api/sync/status`

    @Test func decodesSyncStatusViewRunning() throws {
        let json = Data("""
        {
          "state": "running",
          "at": "2026-09-23T10:15:00.000Z",
          "lastSuccess": "2026-09-23T09:50:00.000Z",
          "message": null,
          "progress": {"startedAt": "2026-09-23T10:15:00.000Z", "watchFiles": 20, "remainingOnWatch": 7},
          "freshness": {"at": "2026-09-23T09:50:00.000Z", "ageSec": 1500}
        }
        """.utf8)

        let status = try PulseAPIClient.decoder.decode(StatusSyncStatusView.self, from: json)

        #expect(status.state == .running)
        #expect(status.progress?.remainingOnWatch == 7)
        #expect(status.progress?.watchFiles == 20)
        #expect(status.freshness?.ageSec == 1500)
    }

    /// État `idle` sans progression ni fraîcheur connue (rien n'a encore été
    /// synchronisé) — `progress`/`freshness` restent décodables à `null`.
    @Test func decodesSyncStatusViewIdleWithoutData() throws {
        let json = Data("""
        {
          "state": "idle",
          "at": null,
          "lastSuccess": null,
          "message": null,
          "progress": null,
          "freshness": {"at": null, "ageSec": null}
        }
        """.utf8)

        let status = try PulseAPIClient.decoder.decode(StatusSyncStatusView.self, from: json)

        #expect(status.state == .idle)
        #expect(status.progress == nil)
        #expect(status.freshness?.ageSec == nil)
    }

    @Test func decodesSyncStatusViewError() throws {
        let json = Data("""
        {
          "state": "error",
          "at": "2026-09-23T10:15:00.000Z",
          "lastSuccess": "2026-09-22T20:00:00.000Z",
          "message": "La synchronisation a échoué côté hôte.",
          "progress": {"startedAt": null, "watchFiles": null, "remainingOnWatch": null},
          "freshness": {"at": "2026-09-22T20:00:00.000Z", "ageSec": 51000}
        }
        """.utf8)

        let status = try PulseAPIClient.decoder.decode(StatusSyncStatusView.self, from: json)

        #expect(status.state == .error)
        #expect(status.message == "La synchronisation a échoué côté hôte.")
    }

    // MARK: - `POST api/sync` (déclenchement)

    @Test func decodesTriggerResultPending() throws {
        let json = Data("""
        {"status": "pending"}
        """.utf8)

        let result = try PulseAPIClient.decoder.decode(StatusTriggerResult.self, from: json)

        #expect(result.status == .pending)
        #expect(result.already == nil)
    }

    @Test func decodesTriggerResultThrottled() throws {
        let json = Data("""
        {"status": "throttled", "retryInSec": 24}
        """.utf8)

        let result = try PulseAPIClient.decoder.decode(StatusTriggerResult.self, from: json)

        #expect(result.status == .throttled)
        #expect(result.retryInSec == 24)
    }

    @Test func decodesTriggerResultUnavailable() throws {
        let json = Data("""
        {"status": "unavailable", "message": "Dossier control inaccessible sur le serveur."}
        """.utf8)

        let result = try PulseAPIClient.decoder.decode(StatusTriggerResult.self, from: json)

        #expect(result.status == .unavailable)
        #expect(result.message == "Dossier control inaccessible sur le serveur.")
    }

    // MARK: - `StatusDateFormatting`

    @Test func spellsDurationsLikeAngular() {
        #expect(StatusDateFormatting.spell(42) == "42 s")
        #expect(StatusDateFormatting.spell(90) == "1 min")
        #expect(StatusDateFormatting.spell(3_660) == "1 h 1 min")
        #expect(StatusDateFormatting.spell(90_000) == "1 j 1 h")
    }

    @Test func parsesIsoStringsWithAndWithoutFractionalSeconds() {
        #expect(StatusDateFormatting.parse("2026-09-23T10:14:58.120Z") != nil)
        #expect(StatusDateFormatting.parse("2026-09-23T10:14:58Z") != nil)
        #expect(StatusDateFormatting.parse("pas une date") == nil)
    }
}
