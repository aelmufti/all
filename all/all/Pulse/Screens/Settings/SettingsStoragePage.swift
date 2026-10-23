//
//  SettingsStoragePage.swift
//  all (bridge-connect)
//
//  Page « Stockage » : le mode (liste cochée), l'adresse de Pulse quand il en
//  dépend, puis ce qu'occupe l'app sur l'iPhone et ce que détient Pulse, enfin la
//  purge. Détail de ce qui est effacé, gardé et bloquant : Aide › Données & synchro.
//
//  Distinct de « Source » de la page Synchronisation (qui dit QUI COLLECTE sur la
//  montre, réglage serveur `api/sync/source`) : ce réglage-ci dit OÙ VIVENT LES
//  DONNÉES de l'app, purement local (`StorageModeStore`).
//

import SwiftUI

// MARK: - Jauge de stockage
//
// Même lecture que Réglages › Stockage d'iOS : le total, un tube découpé en
// segments de couleur proportionnels, puis la légende avec la taille de chacun.
// Le tube représente ce que l'app occupe (pas la capacité de l'appareil : sa
// part y serait invisible).

private struct SettingsStorageGauge: View {
    struct Segment: Identifiable {
        let name: String
        let bytes: Int64
        let color: Color
        var id: String { name }
    }

    let segments: [Segment]

    private var shown: [Segment] { segments.filter { $0.bytes > 0 } }
    private var total: Int64 { shown.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.md) {
            Text(LocalStorageUsage.formatted(total))
                .font(.title.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(Color.pulseTextPrimary)

            GeometryReader { proxy in
                let gap: CGFloat = 2
                // Largeur minimale : un petit poste reste visible dans le tube.
                let minWidth: CGFloat = 4
                let available = max(0, proxy.size.width - gap * CGFloat(max(0, shown.count - 1)))
                HStack(spacing: gap) {
                    if shown.isEmpty {
                        Color.pulseEmpty
                    } else {
                        ForEach(shown) { segment in
                            segment.color
                                .frame(width: max(minWidth, available * CGFloat(segment.bytes) / CGFloat(total)))
                        }
                    }
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: 22)
            .accessibilityHidden(true)

            VStack(spacing: PulseSpacing.sm) {
                ForEach(shown) { segment in
                    HStack(spacing: PulseSpacing.sm) {
                        Circle().fill(segment.color).frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                        Text(segment.name)
                            .font(.subheadline)
                            .foregroundStyle(Color.pulseTextPrimary)
                        Spacer()
                        Text(LocalStorageUsage.formatted(segment.bytes))
                            .font(.subheadline)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, PulseSpacing.sm)
    }
}

struct SettingsStoragePage: View {
    @Bindable var viewModel: SettingsViewModel
    let onRequestModeChange: (StorageMode) -> Void
    @State private var storageMode = StorageModeStore.shared
    @State private var usage: LocalStorageUsage?
    @State private var purge = LocalPurgeModel.live()
    @State private var confirmPurge = false
    /// `completions` change à chaque fin d'ingestion, d'échange ou d'envoi : les tailles
    /// et totaux se remesurent alors (`.task(id:)` plus bas).
    @State private var work = SyncWork.shared

    /// Postes du tube côté iPhone : les `.fit` par type, puis la base.
    private static func phoneSegments(_ usage: LocalStorageUsage) -> [SettingsStorageGauge.Segment] {
        let known: [(folder: String, name: String, color: Color)] = [
            ("ACTIVITY", "Activités", .pulseCalories),
            ("MONITOR", "Suivi quotidien", .pulseSteps),
            ("SLEEP", "Sommeil", .pulseSleep),
        ]
        var segments = known.map {
            SettingsStorageGauge.Segment(name: $0.name, bytes: usage.watchFileBytesByType[$0.folder] ?? 0, color: $0.color)
        }
        let other = usage.watchFileBytesByType.filter { type, _ in !known.contains { $0.folder == type } }
            .values.reduce(0, +)
        segments.append(.init(name: "Autres fichiers", bytes: other, color: .pulseAbsent))
        segments.append(.init(name: "Base de données", bytes: usage.databaseBytes, color: .pulseSpo2))
        return segments
    }

    var body: some View {
        Form {
            SettingsStorageSection(onRequestModeChange: onRequestModeChange)
            if storageMode.mode != .phone {
                SettingsPulseAddressSection(viewModel: viewModel)
            }
            // Ce que l'app occupe sur l'iPhone — dans tous les modes : les `.fit`
            // de la montre y transitent même quand Pulse est la référence.
            Section("Sur cet iPhone") {
                if let usage {
                    SettingsStorageGauge(segments: Self.phoneSegments(usage))
                    if let counts = usage.counts {
                        LabeledContent("Activités", value: "\(counts.activities)")
                        LabeledContent("Nuits", value: "\(counts.nights)")
                        LabeledContent("Jours", value: "\(counts.days)")
                    }
                    LabeledContent("Fichiers de la montre", value: "\(usage.watchFileCount)")
                } else {
                    ProgressView()
                }
            }
            // Ce que le serveur détient (inventaire de Pulse). Les tailles
            // manquent tant que Pulse n'est pas redéployé : pas de jauge alors.
            if storageMode.mode != .phone, let inventory = viewModel.inventory {
                Section("Sur Pulse") {
                    if let filesBytes = inventory.filesBytes, filesBytes >= 0, let dbBytes = inventory.dbBytes {
                        SettingsStorageGauge(segments: [
                            .init(name: "Fichiers de la montre", bytes: filesBytes, color: .pulseSteps),
                            .init(name: "Base de données", bytes: dbBytes, color: .pulseSpo2),
                        ])
                    }
                    DisclosureGroup("Détail") {
                        LabeledContent("Activités", value: "\(inventory.activities)")
                        LabeledContent("Nuits", value: "\(inventory.nights)")
                        LabeledContent("Jours", value: "\(inventory.days)")
                        LabeledContent("Fichiers de la montre", value: "\(inventory.onDisk)")
                    }
                }
            }
            Section {
                Button(role: .destructive) { confirmPurge = true } label: {
                    HStack {
                        Text("Purger les données de l'iPhone")
                        if purge.isPurging { Spacer(); ProgressView() }
                    }
                }
                .disabled(!purge.canPurge)
            } footer: {
                if let reason = purge.blockedReason {
                    Text(reason)
                } else if purge.failed {
                    Text("Purge impossible.")
                }
            }
        }
        .navigationTitle("Stockage")
        .navigationBarTitleDisplayMode(.inline)
        // Adresse saisie mais pas validée au clavier : enregistrée en quittant la page.
        .onDisappear { viewModel.commitBaseURLIfChanged() }
        // Parcours du disque hors main ; remesuré à l'ouverture de la page ET à
        // chaque fin d'activité (`SyncWork.completions`) — `.task(id:)` annule la mesure
        // précédente, des fins rapprochées n'en empilent pas.
        .task(id: work.completions) {
            await measureUsage()
            await purge.refresh()
        }
        .confirmationDialog("Purger les données de l'iPhone ?", isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("Purger", role: .destructive) {
                Task {
                    if await purge.purge() { await measureUsage() }
                }
            }
        } message: {
            Text("Efface la base de l'iPhone et les fichiers déjà reçus par Pulse.")
        }
    }

    private func measureUsage() async {
        usage = await Task.detached(priority: .utility) { LocalStorageUsage.measure() }.value
    }
}

// MARK: - Mode (où vivent les données — cf. `StorageModeStore`)

private struct SettingsStorageSection: View {
    @State private var store = StorageModeStore.shared
    /// Appelée à CHAQUE tap sur un mode : rien n'est appliqué ici. Le parent
    /// (`SettingsView`) demande confirmation, puis applique le mode — ou, pour
    /// Pulse / Les deux sans session active, présente la connexion dans une feuille
    /// **annulable** (`PulseModeLoginSheet`) qui n'applique le mode qu'une fois
    /// connecté.
    let onRequestModeChange: (StorageMode) -> Void

    var body: some View {
        Section {
            ForEach(StorageMode.allCases) { mode in
                let isSelected = store.mode == mode
                Button { onRequestModeChange(mode) } label: {
                    HStack(spacing: PulseSpacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.label)
                                .foregroundStyle(Color.pulseTextPrimary)
                            Text(Self.subtitle(mode))
                                .font(.footnote)
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                        Spacer(minLength: PulseSpacing.sm)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.pulseAccent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    private static func subtitle(_ mode: StorageMode) -> String {
        switch mode {
        case .phone: return "Données sur l'iPhone"
        case .pulse: return "Données sur Pulse"
        case .both: return "iPhone et Pulse"
        }
    }
}

// MARK: - Adresse de Pulse
//
// Enregistrée à la validation du clavier et à la sortie de la page (pas de bouton).

private struct SettingsPulseAddressSection: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Section {
            TextField("https://pulse.<tailnet>.ts.net", text: $viewModel.baseURLText)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { viewModel.saveBaseURL() }
        } header: {
            Text("Adresse de Pulse")
        } footer: {
            if let baseURLError = viewModel.baseURLError {
                Text(baseURLError)
                    .foregroundStyle(Color.pulseDanger)
            }
        }
        .sensoryFeedback(.success, trigger: viewModel.baseURLSaveCount)
    }
}
