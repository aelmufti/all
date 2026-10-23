//
//  SettingsSupportTests.swift
//  allTests
//
//  Logique pure des pages de second niveau des Paramètres : debounce, libellés
//  du lien BLE, comparaison des jetons, options des sélecteurs, heure par défaut
//  d'un réveil. Hors réseau.
//

import Testing
import Foundation
@testable import all

@MainActor
struct SettingsSupportTests {
    // MARK: - Debounce

    @Test func debouncerKeepsOnlyTheLastAction() async throws {
        let debouncer = SettingsDebouncer(delay: .milliseconds(40))
        var fired: [Int] = []
        debouncer.schedule { fired.append(1) }
        debouncer.schedule { fired.append(2) }
        debouncer.schedule { fired.append(3) }
        #expect(debouncer.isPending)
        try await Task.sleep(for: .milliseconds(250))
        #expect(fired == [3])
        #expect(!debouncer.isPending)
    }

    @Test func cancelPendingReportsAndDropsTheAction() async throws {
        let debouncer = SettingsDebouncer(delay: .milliseconds(40))
        var fired = false
        debouncer.schedule { fired = true }
        #expect(debouncer.cancelPending())
        #expect(!debouncer.cancelPending())
        try await Task.sleep(for: .milliseconds(150))
        #expect(!fired)
    }

    // MARK: - Libellés du lien

    @Test func watchStatusLabelsAreHumanFrench() {
        #expect(SettingsWatchStatus.label(for: .connected) == "Connectée")
        #expect(SettingsWatchStatus.label(for: .scanning) == "Recherche…")
        #expect(SettingsWatchStatus.label(for: .disconnected) == "Déconnectée")
        #expect(SettingsWatchStatus.label(for: .reconnecting) == "Reconnexion…")
        #expect(SettingsWatchStatus.label(for: .connecting) == "Connexion…")
    }

    @Test func emptyDevicesMessageDependsOnScanState() {
        #expect(devicesEmptyMessage(state: .scanning, discoveredCount: 0) == "Recherche…")
        #expect(devicesEmptyMessage(state: .disconnected, discoveredCount: 0).contains("scan"))
        #expect(devicesEmptyMessage(state: .disconnected, discoveredCount: 3).contains("nommé"))
    }

    // MARK: - Jetons

    @Test func tokenComparison() {
        #expect(SettingsIngestTokenStatus.compare(device: "abc", server: "abc") == .ok)
        #expect(SettingsIngestTokenStatus.compare(device: " abc\n", server: "abc") == .ok)
        #expect(SettingsIngestTokenStatus.compare(device: "xyz", server: "abc") == .needsUpdate)
        #expect(SettingsIngestTokenStatus.compare(device: nil, server: "abc") == .needsUpdate)
        #expect(SettingsIngestTokenStatus.compare(device: "abc", server: nil) == nil)
        #expect(SettingsIngestTokenStatus.compare(device: "abc", server: "") == nil)
    }

    // MARK: - Sélecteurs du profil

    @Test func birthYearsCoverTheRangeNewestFirst() {
        let years = SettingsProfileOptions.birthYears(currentYear: 2026, including: nil)
        #expect(years.first == 2016)
        #expect(years.last == 1926)
        #expect(years.count == 91)
    }

    @Test func pickersKeepAnOutOfRangeCurrentValue() {
        #expect(SettingsProfileOptions.birthYears(currentYear: 2026, including: 1900).last == 1900)
        let heights = SettingsProfileOptions.heights(including: 240)
        #expect(heights.first == 100)
        #expect(heights.last == 240)
        #expect(SettingsProfileOptions.heights(including: 175).count == 131)
    }

    @Test func heightParsingAcceptsCommaAndRejectsEmpty() {
        #expect(SettingsViewModel.parseHeight("175,5") == 175.5)
        #expect(SettingsViewModel.parseHeight(" 180 ") == 180)
        #expect(SettingsViewModel.parseHeight("") == nil)
        #expect(SettingsViewModel.parseHeight("0") == nil)
    }

    // MARK: - Réveil

    @Test func wakeDefaultMinutes() {
        let order = [2, 3, 4, 5, 6, 7, 1]
        #expect(SettingsWakeDefaults.minutes(lastSet: 400, schedule: [2: 500], order: order) == 400)
        #expect(SettingsWakeDefaults.minutes(lastSet: nil, schedule: [1: 600, 3: 480], order: order) == 480)
        #expect(SettingsWakeDefaults.minutes(lastSet: nil, schedule: [:], order: order) == 7 * 60)
    }
}
