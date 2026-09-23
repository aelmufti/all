//
//  SettingsView.swift
//  all (bridge-connect)
//
//  Écran Paramètres natif — équivalent SwiftUI (partiel) de la page Angular
//  `/parametres` (`custom-connect/web/src/app/pages/settings/
//  settings.component.ts`), restreint à trois sections : Synchronisation
//  (source + statut — le cœur du contrat bridge-connect/Pulse), Profil
//  (année de naissance / sexe / taille — affichage + édition simple, le
//  poids reste en lecture seule, saisi sur la page Santé), et Application
//  (adresse de Pulse, compte, déconnexion). Les autres feuilles Angular
//  (Objectifs, Objectif calorique, Minutes d'intensité, Thème, Export,
//  Réanalyser) sont hors périmètre de cet écran.
//
//  `Form`/`Section` de style Réglages iOS plutôt que les cartes `PulseCard`
//  des autres écrans — un choix explicite pour cette page (le natif iOS a
//  déjà tout le vocabulaire visuel d'un écran de réglages).
//
//  Toutes les déclarations de ce fichier sont préfixées `Settings*` pour ne
//  rien exposer qui puisse entrer en collision avec les autres écrans
//  (`Screens/Home`, `Screens/Health`…) compilés dans la même cible.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    private let auth = AuthStore.shared

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Paramètres")
                .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingView(message: "Chargement des paramètres…")
        case .failed(let message):
            ErrorView(message: message) {
                Task { await viewModel.retry() }
            }
        case .loaded:
            Form {
                SettingsSyncSourceSection(viewModel: viewModel)
                SettingsStatusSection(viewModel: viewModel)
                SettingsProfileSection(viewModel: viewModel)
                SettingsApplicationSection(viewModel: viewModel, username: auth.username)
            }
        }
    }
}

// MARK: - Synchronisation > Source

private struct SettingsSyncSourceSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        Section {
            Picker("Source", selection: sourceBinding) {
                ForEach(SettingsSyncSourceKind.allCases) { kind in
                    Text(kind.label).tag(kind.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isChangingSource)

            if let source = viewModel.source {
                Text(Self.subLabel(for: source))
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)

                if source.source == "bridge" {
                    LabeledContent("Adresse", value: source.url)
                    HStack(spacing: PulseSpacing.xs) {
                        Circle()
                            .fill(source.reachable == true ? Color.pulseSuccess : Color.pulseDanger)
                            .frame(width: 8, height: 8)
                        Text(source.reachable == true ? "garmin-bridge répond" : "garmin-bridge ne répond pas")
                            .font(.footnote)
                    }
                    if source.reachable != true, let detail = source.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }

                if source.source == "phone" {
                    SettingsIngestTokenRow(viewModel: viewModel, token: source.ingestToken)
                }

                if source.overridden {
                    Text("Réglé sur « \(source.configured == "bridge" ? "bridge" : "legacy") » dans l'environnement du conteneur, remplacé ici. Ce choix survit aux redémarrages.")
                        .font(.caption)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }

            if let sourceError = viewModel.sourceError {
                Text(sourceError)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseDanger)
            }
        } header: {
            Text("Synchronisation")
        } footer: {
            Text("« Téléphone » est la chaîne historique (adb depuis l'hôte). « garmin-bridge » parle en Bluetooth depuis le serveur. « iPhone (BLE) » : cette app pousse les .fit en HTTP. Basculer ne fait rien perdre — la déduplication par empreinte évite les doublons.")
        }
    }

    /// Sélection à deux voies : le `Picker` change la source côté vue-modèle
    /// dès que l'utilisateur touche un segment, `PUT api/sync/source` part
    /// depuis `SettingsViewModel.setSource`.
    private var sourceBinding: Binding<String> {
        Binding(
            get: { viewModel.source?.source ?? SettingsSyncSourceKind.legacy.rawValue },
            set: { next in Task { await viewModel.setSource(next) } }
        )
    }

    private static func subLabel(for source: SettingsSyncSource) -> String {
        switch source.source {
        case "phone": return "l'iPhone pousse les .fit en HTTP (bridge-connect)"
        case "bridge": return "bluetooth depuis le serveur, sans téléphone"
        default: return "adb depuis l'hôte, dépôt dans data/inbox"
        }
    }
}

/// Bloc token d'ingestion — affiché uniquement pour la source `"phone"`
/// (miroir du `<div class="token-block">` Angular). Copie locale vers le
/// presse-papiers, aucune transmission réseau propre à ce geste.
private struct SettingsIngestTokenRow: View {
    var viewModel: SettingsViewModel
    let token: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.sm) {
            Text("Token d'ingestion")
                .font(.caption)
                .foregroundStyle(Color.pulseTextSecondary)
            Text(token ?? "—")
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            HStack(spacing: PulseSpacing.sm) {
                Button("Copier") {
                    guard let token else { return }
                    UIPasteboard.general.string = token
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .disabled(token == nil)

                Button("Régénérer") {
                    Task { await viewModel.regenerateIngestToken() }
                }
                .disabled(viewModel.isRegeneratingToken)

                if viewModel.isRegeneratingToken {
                    ProgressView()
                } else if copied {
                    Text("copié")
                        .font(.caption)
                        .foregroundStyle(Color.pulseSuccess)
                }
            }
            Text("Colle ce token dans l'app iPhone : réglages > Synchronisation. Régénérer invalide l'ancien.")
                .font(.caption2)
                .foregroundStyle(Color.pulseTextSecondary)
        }
        .padding(.vertical, PulseSpacing.xs)
    }
}

// MARK: - Synchronisation > État

private struct SettingsStatusSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        Section("État de la synchro") {
            if let status = viewModel.status {
                LabeledContent("État") {
                    Text(Self.stateLabel(status.state))
                        .foregroundStyle(Self.stateColor(status.state))
                }
                if let lastSuccess = status.lastSuccess {
                    LabeledContent("Dernier succès", value: lastSuccess)
                }
                LabeledContent("Fraîcheur des données", value: Self.freshnessLabel(status.freshness))
                if let progress = status.progress, let watchFiles = progress.watchFiles {
                    LabeledContent(
                        "Fichiers sur la montre",
                        value: "\(progress.remainingOnWatch ?? watchFiles) / \(watchFiles)"
                    )
                }
                if let message = status.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            if let inventory = viewModel.inventory {
                LabeledContent("Fichiers sur disque", value: "\(inventory.onDisk)")
                LabeledContent("Activités importées", value: "\(inventory.activities)")
                LabeledContent("Nuits", value: "\(inventory.nights)")
                LabeledContent("Jours", value: "\(inventory.days)")
            }
        }
    }

    private static func stateLabel(_ state: String) -> String {
        switch state {
        case "running": return "Synchronisation en cours…"
        case "ok": return "À jour"
        case "error": return "Erreur"
        default: return "Inactif"
        }
    }

    private static func stateColor(_ state: String) -> Color {
        switch state {
        case "running": return .pulseAccent
        case "ok": return .pulseSuccess
        case "error": return .pulseDanger
        default: return .pulseTextSecondary
        }
    }

    private static func freshnessLabel(_ freshness: SettingsSyncFreshness) -> String {
        guard let age = freshness.ageSec else { return "aucune donnée" }
        if age < 60 { return "à l'instant" }
        if age < 3_600 { return "il y a \(age / 60) min" }
        if age < 86_400 { return "il y a \(age / 3_600) h" }
        return "il y a \(age / 86_400) j"
    }
}

// MARK: - Profil

private struct SettingsProfileSection: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Section {
            LabeledContent("Année de naissance") {
                TextField("AAAA", text: $viewModel.birthYearText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Taille") {
                HStack(spacing: PulseSpacing.xs) {
                    TextField("cm", text: $viewModel.heightCmText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("cm")
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            Picker("Sexe", selection: $viewModel.sex) {
                Text("Homme").tag(Optional("male"))
                Text("Femme").tag(Optional("female"))
            }
            .pickerStyle(.segmented)

            LabeledContent("Poids retenu", value: viewModel.profileWeightLabel)

            Button {
                Task { await viewModel.saveProfile() }
            } label: {
                if viewModel.isSavingProfile {
                    ProgressView()
                } else {
                    Text("Enregistrer")
                }
            }
            .disabled(viewModel.isSavingProfile)

            if viewModel.profileSaved {
                Text("enregistré")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseSuccess)
            }
            if let profileError = viewModel.profileError {
                Text(profileError)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseDanger)
            }
        } header: {
            Text("Profil")
        } footer: {
            Text("Sert au métabolisme de base, à l'âge physiologique et à l'objectif calorique dynamique. Le poids se saisit jour par jour sur la page Santé.")
        }
    }
}

// MARK: - Application

private struct SettingsApplicationSection: View {
    @Bindable var viewModel: SettingsViewModel
    let username: String?

    var body: some View {
        Section("Compte") {
            LabeledContent("Utilisateur", value: username ?? "—")
            Text("Serveur personnel · rien ne sort d'ici")
                .font(.caption)
                .foregroundStyle(Color.pulseTextSecondary)
        }

        Section {
            TextField("https://pulse.<tailnet>.ts.net", text: $viewModel.baseURLText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Enregistrer l'adresse") {
                viewModel.saveBaseURL()
            }

            if viewModel.baseURLSaved {
                Text("enregistré")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseSuccess)
            }
            if let baseURLError = viewModel.baseURLError {
                Text(baseURLError)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseDanger)
            }
        } header: {
            Text("Adresse de Pulse")
        }

        Section {
            Button("Déconnexion", role: .destructive) {
                Task { await AuthStore.shared.logout() }
            }
        }
    }
}

#Preview {
    SettingsView()
}
