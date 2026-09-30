//
//  BLEDiagnosticViewTests.swift
//  allTests
//
//  Fonctions pures extraites de `BLEDiagnosticView` (UX écran Montre/BLE,
//  cf. son en-tête) : filtrage/tri de la liste de scan et condition
//  d'affichage du bouton « Oublier l'appareil ». Rien de réseau/BLE réel ici
//  — juste des `DiscoveredPeripheral`/`BLEConnectionState` en dur.
//

import Testing
import Foundation
@testable import all

struct BLEDiagnosticViewTests {
    // MARK: - visibleDevices

    @Test func hidesUnnamedDevicesByDefault() {
        let devices = [
            DiscoveredPeripheral(id: UUID(), name: "Sans nom", rssi: -40),
            DiscoveredPeripheral(id: UUID(), name: "Montre de Ali", rssi: -60),
        ]

        let visible = visibleDevices(devices, showAll: false)

        #expect(visible.map(\.name) == ["Montre de Ali"])
    }

    @Test func showAllRedisplaysUnnamedDevices() {
        let devices = [
            DiscoveredPeripheral(id: UUID(), name: "Sans nom", rssi: -40),
            DiscoveredPeripheral(id: UUID(), name: "Montre de Ali", rssi: -60),
        ]

        let visible = visibleDevices(devices, showAll: true)

        #expect(visible.count == 2)
    }

    @Test func likelyGarminDeviceIsSurfacedFirstEvenWithWeakerSignal() {
        let devices = [
            DiscoveredPeripheral(id: UUID(), name: "Casque Bluetooth", rssi: -30),
            DiscoveredPeripheral(id: UUID(), name: "Venu 2", rssi: -80),
        ]

        let visible = visibleDevices(devices, showAll: false)

        #expect(visible.first?.name == "Venu 2", "un nom Garmin/Venu passe devant même avec un signal plus faible")
    }

    @Test func withinTheSameRelevanceTierSortsByStrongestSignalFirst() {
        let devices = [
            DiscoveredPeripheral(id: UUID(), name: "Casque Bluetooth", rssi: -80),
            DiscoveredPeripheral(id: UUID(), name: "Traqueur", rssi: -30),
        ]

        let visible = visibleDevices(devices, showAll: false)

        #expect(visible.map(\.name) == ["Traqueur", "Casque Bluetooth"])
    }

    // MARK: - isLikelyGarminDevice

    @Test func detectsGarminOrVenuCaseInsensitively() {
        #expect(isLikelyGarminDevice("Garmin Venu 2"))
        #expect(isLikelyGarminDevice("venu 2 plus"))
        #expect(isLikelyGarminDevice("GARMIN"))
        #expect(!isLikelyGarminDevice("Casque Bluetooth"))
    }

    // MARK: - shouldShowForgetDeviceButton

    @Test func hiddenWhenNothingIsKnownOrConnected() {
        #expect(!shouldShowForgetDeviceButton(peripheralName: nil, connectionState: .disconnected))
        #expect(!shouldShowForgetDeviceButton(peripheralName: nil, connectionState: .scanning))
        #expect(!shouldShowForgetDeviceButton(peripheralName: nil, connectionState: .connecting))
    }

    @Test func shownWhenAPeripheralNameIsKnown() {
        #expect(shouldShowForgetDeviceButton(peripheralName: "Venu 2", connectionState: .disconnected))
    }

    @Test func shownWhenConnectedOrReconnectingEvenWithoutAName() {
        #expect(shouldShowForgetDeviceButton(peripheralName: nil, connectionState: .connected))
        #expect(shouldShowForgetDeviceButton(peripheralName: nil, connectionState: .reconnecting))
    }
}
