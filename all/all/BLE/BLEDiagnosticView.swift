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
    @State private var calendarSyncEnabled = PulseConfig.calendarSyncEnabled
    /// Masque le token d'ingestion Pulse et le pied de page diagnostic
    /// os.Logger en mode Téléphone (`StorageModeStore.current == .phone`) :
    /// sans cible de push Pulse, ces deux blocs n'ont aucun sens pour
    /// l'utilisateur final — demande directe (« le secret Pulse est là en
    /// mode Téléphone »). `@State` (pas `StorageModeStore.current`) pour que
    /// la vue se re-rende si le mode change pendant qu'elle est affichée —
    /// même idiome que `SettingsStorageSection`/`SettingsView`.
    @State private var storageMode = StorageModeStore.shared
    /// Santé de l'envoi vers Pulse (jeton refusé, mauvaise source, fichiers
    /// rejetés) — cf. `Sync/PulseUploadHealth.swift`.
    @State private var health = PulseUploadHealth.shared
    /// Par défaut, la liste de scan masque les périphériques sans nom (bruit
    /// BLE ambiant) — ce bouton, replié et désactivé par défaut, les
    /// redémasque pour un usage avancé. Cf. `visibleDevices(_:showAll:)`.
    @State private var showAllDevices = false

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
                if storageMode.mode != .phone {
                    Section("Sync Pulse") {
                        LabeledContent("URL Pulse", value: PulseConfig.baseURL?.absoluteString ?? "— (à définir dans l'onglet Pulse)")
                        SecureField("Token d'ingestion Pulse", text: $ingestToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Enregistrer le token") {
                            let trimmed = ingestToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            PulseConfig.ingestToken = trimmed.isEmpty ? nil : trimmed
                            health.clearConfigProblem()
                        }
                        Text("Le token doit correspondre à un INGEST_TOKENS du serveur Pulse, et la source de synchro doit être réglée sur « phone » côté Pulse.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .onAppear { ingestToken = PulseConfig.ingestToken ?? "" }
                }
                Section("Calendrier") {
                    Toggle("Synchroniser vers la montre", isOn: $calendarSyncEnabled)
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
                    Text("La montre récupère les événements à venir pendant qu'elle est connectée et l'app ouverte. Accès en lecture seule au calendrier iOS.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                        let visible = visibleDevices(ble.discovered, showAll: showAllDevices)
                        if visible.isEmpty {
                            Text(emptyDevicesMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(visible) { device in
                                Button {
                                    ble.connect(to: device.id)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: PulseSpacing.xs) {
                                                Text(device.name)
                                                if isLikelyGarminDevice(device.name) {
                                                    Text("Probable")
                                                        .font(.caption2.weight(.semibold))
                                                        .foregroundStyle(Color.pulseAccent)
                                                }
                                            }
                                            // UUID technique : tenu à l'écart, derrière
                                            // « Afficher tout » (demande utilisateur —
                                            // « trop d'options sans nom »).
                                            if showAllDevices {
                                                Text(device.id.uuidString)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1).truncationMode(.middle)
                                            }
                                        }
                                        Spacer()
                                        Text("\(device.rssi) dBm")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        // Repliée et désactivée par défaut — n'apparaît que pour un
                        // usage avancé (cf. commentaire de `showAllDevices`).
                        Toggle("Afficher tout", isOn: $showAllDevices)
                            .font(.footnote)
                    }
                }
                if let session = ble.garminSession {
                    GarminDirectorySection(session: session)
                }
                // Rien à oublier tant qu'aucun appareil n'est connu — le bouton ne
                // s'affiche que si un appareil a déjà été relié au moins une fois
                // ou est en cours de reconnexion (demande utilisateur : « toujours
                // présent alors qu'il n'y a rien à oublier »).
                if shouldShowForgetDeviceButton(peripheralName: ble.peripheralName, connectionState: ble.connectionState) {
                    Section {
                        Button("Oublier l'appareil", role: .destructive, action: ble.forgetDevice)
                    }
                }
                if storageMode.mode != .phone {
                    Section {
                        Text("Les 5 métriques (durée de fenêtre, notifications/fenêtre, latence de reconnexion, restauration d'état, supervision timeout) sont journalisées via os.Logger — Console.app, filtre subsystem « CleanYourRoom.all ».")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Diagnostic BLE")
            .refreshesPulseRejectedCount(health)
        }
    }

    private var emptyDevicesMessage: String {
        if ble.connectionState == .scanning { return "Recherche…" }
        if ble.discovered.isEmpty { return "Aucun périphérique. Lance un scan." }
        // Le scan a bien trouvé des périphériques, mais aucun avec un nom —
        // filtrés par défaut (cf. `visibleDevices`).
        return "Aucun périphérique nommé pour l'instant. Active « Afficher tout » pour voir les appareils sans nom."
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

/// Section GFDI V2 : état de la poignée de main, manifeste directory (métadonnées
/// — noms/index, type, taille, date), et déclencheur manuel de téléchargement du
/// contenu d'un fichier (tap sur une ligne → `GarminSession.downloadFile`).
/// `@ObservedObject` dédié : `BLEDiagnosticView` n'observe que `BLEManager`, et le
/// remplacement de `garminSession` (nouveau lien) ne republie pas les mutations
/// internes d'une session déjà en place (nouvelles entrées listées, changement
/// d'état) — il faut observer l'objet lui-même pour ça.
private struct GarminDirectorySection: View {
    @ObservedObject var session: GarminSession
    /// Fichiers dont l'ingestion locale a échoué (journal du spool). Rafraîchi à
    /// l'apparition et à chaque avancée de l'ingestion : la session ne publie pas
    /// ce compteur.
    @State private var failedIngests = 0

    var body: some View {
        Section("Synchronisation") {
            LabeledContent("Sync", value: syncStateLabel)
            LabeledContent("Fichiers", value: "\(session.acquiredFileIndexes.count) acquis · \(session.deliveredFileIndexes.count) livrés")
            if failedIngests > 0 {
                Text("\(failedIngests) fichier(s) non ingéré(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Filet de sécurité : la traversée se lance déjà toute seule à la
            // connexion (cf. `GarminSession.finishDownload()`, branche
            // `.directory`) — ce bouton sert pour un rattrapage manuel (ex.
            // fichier ajouté sur la montre après le dernier listing).
            Button("Tout synchroniser maintenant") {
                session.syncNewFiles()
            }
            .disabled(session.downloadingFileIndex != nil || isDownloading)
        }
        .onAppear { failedIngests = session.failedIngestCount() }
        .onReceive(NotificationCenter.default.publisher(for: .spoolIngestDidAdvance)) { _ in
            failedIngests = session.failedIngestCount()
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
