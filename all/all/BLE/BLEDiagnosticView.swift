//
//  BLEDiagnosticView.swift
//  all (bridge-connect)
//
//  Vue de diagnostic de l'incrément 1 : donne à voir en direct ce que le
//  harnais mesure (état radio, état de connexion, compteur de notifications).
//  Les 5 métriques elles-mêmes sont journalisées côté os.Logger — voir
//  BLEManager — et se lisent dans Console.app sur device réel, pas ici.
//

import CoreBluetooth
import SwiftUI

struct BLEDiagnosticView: View {
    @ObservedObject private var ble = BLEManager.shared
    @State private var ingestToken = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Radio") {
                    LabeledContent("CBManagerState", value: describe(ble.centralState))
                }
                Section("Connexion") {
                    LabeledContent("État", value: ble.connectionState.rawValue)
                    LabeledContent("Périphérique", value: ble.peripheralName ?? "—")
                    LabeledContent("Identifiant", value: ble.peripheralIdentifier ?? "—")
                    LabeledContent("Notifications (fenêtre courante)", value: "\(ble.notificationCount)")
                }
                Section("Sync Pulse") {
                    LabeledContent("URL Pulse", value: PulseConfig.baseURL?.absoluteString ?? "— (à définir dans l'onglet Pulse)")
                    SecureField("Token d'ingestion Pulse", text: $ingestToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Enregistrer le token") {
                        let trimmed = ingestToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        PulseConfig.ingestToken = trimmed.isEmpty ? nil : trimmed
                    }
                    Text("Le token doit correspondre à un INGEST_TOKENS du serveur Pulse, et la source de synchro doit être réglée sur « phone » côté Pulse.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .onAppear { ingestToken = PulseConfig.ingestToken ?? "" }
                // Liste de scan masquée dès qu'un lien est établi ou en cours de
                // revalidation : une fois la montre connectée, la trentaine de
                // périphériques BLE alentour n'est que du bruit (demande
                // utilisateur). Elle réapparaît à la déconnexion (via « Oublier
                // l'appareil ») pour pouvoir rescanner et choisir une cible.
                if ble.connectionState != .connected && ble.connectionState != .reconnecting {
                    Section("Périphériques") {
                        if ble.connectionState == .scanning {
                            Button("Arrêter le scan", action: ble.stopScan)
                        } else {
                            Button("Scanner", action: ble.scan)
                        }
                        if ble.discovered.isEmpty {
                            Text(ble.connectionState == .scanning ? "Recherche…" : "Aucun périphérique. Lance un scan.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(ble.discovered) { device in
                                Button {
                                    ble.connect(to: device.id)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(device.name)
                                            Text(device.id.uuidString)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        Text("\(device.rssi) dBm")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                if let session = ble.garminSession {
                    GarminDirectorySection(session: session)
                }
                Section {
                    Button("Oublier l'appareil", role: .destructive, action: ble.forgetDevice)
                }
                Section {
                    Text("Les 5 métriques (durée de fenêtre, notifications/fenêtre, latence de reconnexion, restauration d'état, supervision timeout) sont journalisées via os.Logger — Console.app, filtre subsystem « CleanYourRoom.all ».")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Diagnostic BLE")
        }
    }

    private func describe(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "?"
        }
    }
}

/// Section GFDI V2 : état de la poignée de main, manifeste directory (métadonnées
/// — noms/index, type, taille, date), et déclencheur manuel de téléchargement du
/// contenu d'un fichier (tap sur une ligne → `GarminSession.downloadFile`).
/// `@ObservedObject` dédié : `BLEDiagnosticView` n'observe que `BLEManager`, et le
/// remplacement de `garminSession` (nouveau lien) ne republie pas les mutations
/// internes d'une session déjà en place (nouvelles entrées listées, changement
/// d'état) — il faut observer l'objet lui-même pour ça.
private struct GarminDirectorySection: View {
    @ObservedObject var session: GarminSession

    var body: some View {
        Section("Synchronisation") {
            LabeledContent("Sync", value: syncStateLabel)
            LabeledContent("Fichiers", value: "\(session.acquiredFileIndexes.count) acquis · \(session.deliveredFileIndexes.count) livrés")
            // Filet de sécurité : la traversée se lance déjà toute seule à la
            // connexion (cf. `GarminSession.finishDownload()`, branche
            // `.directory`) — ce bouton sert pour un rattrapage manuel (ex.
            // fichier ajouté sur la montre après le dernier listing).
            Button("Tout synchroniser maintenant") {
                session.syncNewFiles()
            }
            .disabled(session.downloadingFileIndex != nil || isDownloading)
        }
        Section("GFDI (montre V2)") {
            LabeledContent("État", value: session.state.label)
            if let firmware = session.firmwareVersion {
                LabeledContent("Firmware", value: firmware)
            }
            if session.files.isEmpty {
                Text("Aucun fichier listé pour l'instant.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.files) { entry in
                    Button {
                        session.downloadFile(entry)
                    } label: {
                        fileRow(entry)
                    }
                    // Un seul téléchargement à la fois (`GarminSession.downloadFile`
                    // refuse déjà d'en démarrer un second — on l'évite ici aussi
                    // côté UI, en désactivant toutes les autres lignes pendant
                    // qu'une est en cours) ; jamais l'entrée DIRECTORY virtuelle.
                    .disabled(entry.isDirectory || (session.downloadingFileIndex != nil && session.downloadingFileIndex != entry.fileIndex))
                }
            }
        }
    }

    /// Une ligne de fichier listé — tappable (cf. `body`), déclencheur manuel du
    /// téléchargement. Style existant conservé (mêmes `Text`/captions) ; ajoute
    /// juste un indicateur facultatif « en cours » / « acquis ».
    @ViewBuilder
    private func fileRow(_ entry: GarminDirectoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.typeName)
                Spacer()
                if session.downloadingFileIndex == entry.fileIndex {
                    ProgressView()
                        .controlSize(.small)
                } else if session.deliveredFileIndexes.contains(entry.fileIndex) {
                    Image(systemName: "checkmark.icloud.fill")
                        .foregroundStyle(.blue)
                } else if session.acquiredFileIndexes.contains(entry.fileIndex) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text("#\(entry.fileIndex)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(byteCountFormatter.string(fromByteCount: Int64(entry.sizeBytes)))
                if let date = entry.date {
                    Text(date, style: .date)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var byteCountFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }

    /// Texte lisible de `GarminSyncState` — pas de `label` direct sur l'enum
    /// (contrairement à `GarminHandshakeState`), calculé ici pour rester local
    /// à l'usage diagnostic plutôt que dans `GarminSession.swift`.
    private var syncStateLabel: String {
        switch session.syncState {
        case .idle: return "inactif"
        case .downloading(let fileIndex): return "en cours (#\(fileIndex))"
        case .done: return "terminé"
        }
    }

    private var isDownloading: Bool {
        if case .downloading = session.syncState { return true }
        return false
    }
}

#Preview {
    BLEDiagnosticView()
}
