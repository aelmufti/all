//
//  BLEDiagnosticView.swift
//  all (bridge-connect)
//
//  Sous-page « Diagnostic » de Montre (`SettingsWatchPage`) : le technique —
//  état radio, connexion, listing GFDI, lien vers « Temps réel ». Poussée dans la
//  pile de navigation des Paramètres : pas de `NavigationStack` propre.
//
//  Diagnostic os.Logger : les 5 métriques du harnais BLE (durée de fenêtre,
//  notifications/fenêtre, latence de reconnexion, restauration d'état,
//  supervision timeout) sont journalisées côté os.Logger — voir `BLEManager` —
//  et se lisent dans Console.app (subsystem « CleanYourRoom.all ») sur device
//  réel, pas dans l'UI.
//
//  Ce fichier porte aussi les morceaux partagés avec la page Montre
//  (`BLEDevicesSection`, `GarminSyncSection`) et les fonctions pures testées.
//

import CoreBluetooth
import SwiftUI

struct BLEDiagnosticView: View {
    @ObservedObject private var ble = BLEManager.shared
    /// Même clé que `BLEDevicesSection` : « Afficher tout » vit ici, la liste de
    /// scan de la page Montre en tient compte.
    @AppStorage(BLEDevicesSection.showAllKey) private var showAllDevices = false

    var body: some View {
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
            if let session = ble.garminSession {
                GarminGFDISection(session: session)
            }
            Section {
                NavigationLink("Temps réel") { RealtimeMetricsView() }
                Toggle("Afficher tous les périphériques", isOn: $showAllDevices)
            }
        }
        .navigationTitle("Diagnostic")
        .navigationBarTitleDisplayMode(.inline)
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

// MARK: - Liste de scan (partagée avec la page Montre)

/// Section « Périphériques » : Scanner / Arrêter, appareils découverts, repère
/// « Probable ». Par défaut les périphériques sans nom (bruit BLE ambiant) sont
/// masqués ; « Afficher tous les périphériques » (page Diagnostic) les redémasque
/// et montre l'UUID technique. Cf. `visibleDevices(_:showAll:)`.
struct BLEDevicesSection: View {
    static let showAllKey = "ble-show-all-devices"

    @ObservedObject private var ble = BLEManager.shared
    @AppStorage(Self.showAllKey) private var showAllDevices = false

    var body: some View {
        Section("Périphériques") {
            if ble.connectionState == .scanning {
                Button("Arrêter le scan", action: ble.stopScan)
            } else {
                Button("Scanner", action: ble.scan)
            }
            let visible = visibleDevices(ble.discovered, showAll: showAllDevices)
            if visible.isEmpty {
                Text(devicesEmptyMessage(state: ble.connectionState, discoveredCount: ble.discovered.count))
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                ForEach(visible) { device in
                    Button {
                        ble.connect(to: device.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: PulseSpacing.xs) {
                                    Text(device.name)
                                        .foregroundStyle(Color.pulseTextPrimary)
                                    if isLikelyGarminDevice(device.name) {
                                        Text("Probable")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Color.pulseAccent)
                                    }
                                }
                                if showAllDevices {
                                    Text(device.id.uuidString)
                                        .font(.caption2)
                                        .foregroundStyle(Color.pulseTextSecondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            Spacer()
                            Text("\(device.rssi) dBm")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                    }
                }
            }
        }
    }
}

/// Message de la liste de scan quand il n'y a rien à montrer.
func devicesEmptyMessage(state: BLEConnectionState, discoveredCount: Int) -> String {
    if state == .scanning { return "Recherche…" }
    if discoveredCount == 0 { return "Aucun périphérique. Lance un scan." }
    // Le scan a bien trouvé des périphériques, mais aucun avec un nom —
    // filtrés par défaut (cf. `visibleDevices`).
    return "Aucun périphérique nommé. « Afficher tous » est dans Diagnostic."
}

// MARK: - Filtrage/tri de la liste de scan (fonctions pures, testées dans `allTests`)

/// Filtre par défaut les périphériques sans nom (bruit BLE ambiant — la
/// trentaine d'appareils qui traînent autour, casques, trackers, capteurs
/// domestiques… demande utilisateur : « trop d'options sans nom, écran
/// insupportable ») et fait remonter un nom ressemblant à une montre
/// Garmin/Venu en tête de liste. `showAll == true` désactive le filtrage
/// (utile pour du diagnostic avancé) mais garde le même tri.
///
/// Le nom « Sans nom » est celui posé par `BLEManager.centralManager(_:didDiscover:...)`
/// quand ni `peripheral.name` ni l'annonce locale ne donnent de nom — cf. son
/// commentaire.
func visibleDevices(_ devices: [DiscoveredPeripheral], showAll: Bool) -> [DiscoveredPeripheral] {
    let filtered = showAll ? devices : devices.filter { $0.name != "Sans nom" }
    return filtered.sorted { lhs, rhs in
        let lhsLikely = isLikelyGarminDevice(lhs.name)
        let rhsLikely = isLikelyGarminDevice(rhs.name)
        if lhsLikely != rhsLikely { return lhsLikely }
        return lhs.rssi > rhs.rssi // à égalité de pertinence, le plus proche en premier
    }
}

/// Heuristique par nom d'annonce — aucune garantie protocolaire (le CADRAGE
/// ne fixe pas de nom d'annonce pour la Venu 2), juste un indice affiché à
/// l'utilisateur pour repérer sa montre dans la liste.
func isLikelyGarminDevice(_ name: String) -> Bool {
    name.range(of: "garmin", options: .caseInsensitive) != nil
        || name.range(of: "venu", options: .caseInsensitive) != nil
}

/// « Oublier l'appareil » n'a de sens que s'il y a effectivement quelque
/// chose à oublier — demande utilisateur : « bouton oublier l'appareil
/// toujours présent alors qu'il n'y a rien à oublier ». Un appareil est
/// considéré connu dès qu'un nom a été retenu (connexion réussie au moins
/// une fois, cf. `BLEManager.peripheralName`) ou que l'état est `.connected`
/// / `.reconnecting` (lien restauré, nom pas encore republié).
func shouldShowForgetDeviceButton(peripheralName: String?, connectionState: BLEConnectionState) -> Bool {
    peripheralName != nil || connectionState == .connected || connectionState == .reconnecting
}

/// Ligne d'action « Tout synchroniser maintenant » + compteur de fichiers non
/// ingérés (journal du spool). `@ObservedObject` dédié : `BLEManager` ne republie
/// pas les mutations internes d'une `GarminSession` déjà en place.
struct GarminSyncSection: View {
    @ObservedObject var session: GarminSession
    /// Fichiers dont l'ingestion locale a échoué. Rafraîchi à l'apparition et à
    /// chaque avancée de l'ingestion : la session ne publie pas ce compteur.
    @State private var failedIngests = 0

    var body: some View {
        Section {
            // Filet de sécurité : la traversée se lance déjà toute seule à la
            // connexion (cf. `GarminSession.finishDownload()`, branche
            // `.directory`) — ce bouton sert pour un rattrapage manuel (ex.
            // fichier ajouté sur la montre après le dernier listing).
            Button("Tout synchroniser maintenant") {
                session.syncNewFiles()
            }
            .disabled(session.downloadingFileIndex != nil || isDownloading)
            if failedIngests > 0 {
                LabeledContent("Fichiers non ingérés", value: "\(failedIngests)")
            }
        }
        .onAppear { failedIngests = session.failedIngestCount() }
        .onReceive(NotificationCenter.default.publisher(for: .spoolIngestDidAdvance)) { _ in
            failedIngests = session.failedIngestCount()
        }
    }

    private var isDownloading: Bool {
        if case .downloading = session.syncState { return true }
        return false
    }
}

/// Section GFDI V2 : état de la poignée de main, avancement, manifeste directory
/// (métadonnées — noms/index, type, taille, date), et déclencheur manuel de
/// téléchargement du contenu d'un fichier (tap sur une ligne →
/// `GarminSession.downloadFile`).
private struct GarminGFDISection: View {
    @ObservedObject var session: GarminSession

    var body: some View {
        Section("GFDI (montre V2)") {
            LabeledContent("État", value: session.state.label)
            if let firmware = session.firmwareVersion {
                LabeledContent("Firmware", value: firmware)
            }
            LabeledContent("Sync", value: syncStateLabel)
            LabeledContent("Fichiers", value: "\(session.acquiredFileIndexes.count) acquis · \(session.deliveredFileIndexes.count) livrés")
            if session.files.isEmpty {
                Text("Aucun fichier listé pour l'instant.")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
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
                        .foregroundStyle(Color.pulseAccent)
                } else if session.acquiredFileIndexes.contains(entry.fileIndex) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.pulseSuccess)
                }
                Text("#\(entry.fileIndex)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            HStack {
                Text(byteCountFormatter.string(fromByteCount: Int64(entry.sizeBytes)))
                if let date = entry.date {
                    Text(date, style: .date)
                }
            }
            .font(.caption)
            .foregroundStyle(Color.pulseTextSecondary)
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
}

#Preview {
    NavigationStack { BLEDiagnosticView() }
}
