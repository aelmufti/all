//
//  SettingsWatchPage.swift
//  all (bridge-connect)
//
//  Page « Montre » des Paramètres : ne montre que l'utile — état du lien, appareils
//  à choisir tant qu'aucune montre n'est connectée, alerte d'envoi, synchro
//  manuelle, calendrier. Le technique (radio, GFDI, temps réel) vit dans la
//  sous-page « Diagnostic » (`BLEDiagnosticView`).
//
//  Poussée dans la pile de navigation des Paramètres, sans `NavigationStack`
//  propre. Hors Paramètres (Accueil, Onboarding) elle est présentée par
//  `WatchSectionView`, qui lui fournit sa pile.
//

import SwiftUI

struct SettingsWatchPage: View {
    @ObservedObject private var ble = BLEManager.shared
    @State private var calendarSyncEnabled = PulseConfig.calendarSyncEnabled
    @State private var storageMode = StorageModeStore.shared
    /// Santé de l'envoi vers Pulse (jeton refusé, mauvaise source, fichiers
    /// rejetés) — cf. `Sync/PulseUploadHealth.swift`.
    @State private var health = PulseUploadHealth.shared
    @State private var confirmForget = false

    var body: some View {
        Form {
            statusSection

            // Liste de scan masquée dès qu'un lien est établi ou en cours de
            // revalidation : une fois la montre connectée, la trentaine de
            // périphériques BLE alentour n'est que du bruit. Elle réapparaît à la
            // déconnexion (via « Oublier l'appareil ») pour choisir une cible.
            if ble.connectionState != .connected && ble.connectionState != .reconnecting {
                BLEDevicesSection()
            }

            // Une ligne d'alerte tant qu'un problème d'envoi est connu ; « Renvoyer »
            // seulement s'il y a des fichiers en quarantaine. Rien en mode
            // Téléphone (rien ne part vers Pulse).
            if storageMode.mode != .phone, let issue = health.issue {
                Section {
                    Label(issue.label, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.pulseDanger)
                    if health.rejectedCount > 0 {
                        Button("Renvoyer") { PulseBacklogPusher.resendRejected() }
                    }
                }
            }

            if let session = ble.garminSession {
                GarminSyncSection(session: session)
            }

            Section {
                Toggle("Calendrier sur la montre", isOn: $calendarSyncEnabled)
                    .onChange(of: calendarSyncEnabled) { _, isOn in
                        PulseConfig.calendarSyncEnabled = isOn
                        // Déclenche l'invite d'accès système à l'activation ;
                        // si l'utilisateur refuse, on remet le toggle à off.
                        if isOn {
                            EventKitCalendarSource.shared.requestAccess { granted in
                                DispatchQueue.main.async {
                                    if !granted {
                                        calendarSyncEnabled = false
                                        PulseConfig.calendarSyncEnabled = false
                                    }
                                }
                            }
                        }
                    }
            }

            Section {
                NavigationLink("Diagnostic") { BLEDiagnosticView() }
            }

            // Rien à oublier tant qu'aucun appareil n'est connu.
            if shouldShowForgetDeviceButton(peripheralName: ble.peripheralName, connectionState: ble.connectionState) {
                Section {
                    Button("Oublier l'appareil", role: .destructive) { confirmForget = true }
                }
            }
        }
        .navigationTitle("Montre")
        .navigationBarTitleDisplayMode(.inline)
        .refreshesPulseRejectedCount(health)
        .confirmationDialog("Oublier l'appareil ?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Oublier", role: .destructive, action: ble.forgetDevice)
        }
    }

    private var statusSection: some View {
        let label = SettingsWatchStatus.label(for: ble.connectionState)
        let name = ble.peripheralName ?? "Montre"
        return Section {
            HStack(spacing: PulseSpacing.sm) {
                Circle()
                    .fill(SettingsWatchStatus.color(for: ble.connectionState))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(name)
                Spacer(minLength: PulseSpacing.sm)
                Text(label)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(name), \(label)")
        }
    }
}
