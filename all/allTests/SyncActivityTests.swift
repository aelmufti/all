//
//  SyncActivityTests.swift
//  allTests
//
//  Mapping pur `SyncActivity.from` (`Pulse/SyncActivity.swift`) — résumé
//  synchro affiché par la bannière globale (`SyncStatusBanner`). Testé sans
//  CoreBluetooth ni `BLEManager`/`GarminSession` réels (le seam existe
//  précisément pour ça) : juste les enums publiés en entrée.
//

import Testing
@testable import all

struct SyncActivityTests {

    // MARK: - `.downloading` — priorité sur tout le reste

    @Test func downloadingReflectsDeliveredCount() {
        let activity = SyncActivity.from(
            connection: .connected,
            handshake: .listed,
            sync: .downloading(fileIndex: 7),
            deliveredCount: 3
        )
        #expect(activity == .downloading(done: 3))
    }

    @Test func downloadingWinsEvenIfHandshakeStillReportsListing() {
        // Cas normalement disjoint dans le déroulé réel de `GarminSession`
        // (cf. commentaire de `SyncActivity`), mais l'ordre de priorité doit
        // rester correct si ça se chevauchait un jour.
        let activity = SyncActivity.from(
            connection: .connected,
            handshake: .listingDirectory,
            sync: .downloading(fileIndex: 0),
            deliveredCount: 0
        )
        #expect(activity == .downloading(done: 0))
    }

    // MARK: - `.listing`

    @Test func listingWhenHandshakeIsListingDirectory() {
        let activity = SyncActivity.from(
            connection: .connected,
            handshake: .listingDirectory,
            sync: .idle,
            deliveredCount: 0
        )
        #expect(activity == .listing)
    }

    // MARK: - `.connecting`

    @Test func connectingWhenHandshakeChannelOpen() {
        let activity = SyncActivity.from(
            connection: .connected,
            handshake: .gfdiChannelOpen,
            sync: nil,
            deliveredCount: 0
        )
        #expect(activity == .connecting)
    }

    @Test func connectingWhenHandshakeInitialized() {
        let activity = SyncActivity.from(
            connection: .connected,
            handshake: .initialized,
            sync: .idle,
            deliveredCount: 0
        )
        #expect(activity == .connecting)
    }

    @Test func connectingWhenBleIsScanningAndNoSessionYet() {
        let activity = SyncActivity.from(
            connection: .scanning,
            handshake: nil,
            sync: nil,
            deliveredCount: 0
        )
        #expect(activity == .connecting)
    }

    @Test func connectingWhenBleIsConnectingAndNoSessionYet() {
        let activity = SyncActivity.from(
            connection: .connecting,
            handshake: nil,
            sync: nil,
            deliveredCount: 0
        )
        #expect(activity == .connecting)
    }

    @Test func connectingWhenBleIsRevalidatingAPresumedLink() {
        let activity = SyncActivity.from(
            connection: .reconnecting,
            handshake: nil,
            sync: nil,
            deliveredCount: 0
        )
        #expect(activity == .connecting)
    }

    // MARK: - `.idle`

    @Test func idleWhenSyncIsDone() {
        let activity = SyncActivity.from(
            connection: .connected,
            handshake: .listed,
            sync: .done,
            deliveredCount: 5
        )
        #expect(activity == .idle)
    }

    @Test func idleWhenListedWithNoActiveDownload() {
        let activity = SyncActivity.from(
            connection: .connected,
            handshake: .listed,
            sync: .idle,
            deliveredCount: 0
        )
        #expect(activity == .idle)
    }

    @Test func idleWhenDisconnected() {
        let activity = SyncActivity.from(
            connection: .disconnected,
            handshake: nil,
            sync: nil,
            deliveredCount: 0
        )
        #expect(activity == .idle)
    }

    @Test func idleWhenHandshakeFailed() {
        let activity = SyncActivity.from(
            connection: .connected,
            handshake: .failed("test"),
            sync: .idle,
            deliveredCount: 0
        )
        #expect(activity == .idle)
    }
}
