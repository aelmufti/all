//
//  SettingsSyncPage.swift
//  all (bridge-connect)
//
//  Page « Synchronisation » (modes avec serveur) : qui collecte, puis l'état.
//
//  Le sélecteur de source choisit *qui* collecte, et seuls les contrôles du mode
//  retenu s'affichent en dessous :
//    • bridge  → le pont du homelab parle en Bluetooth → accès « Statut du pont »
//                (lien BLE bridge↔montre, synchro auto ; `StatusView`).
//    • phone   → cette app est le collecteur → « Jeton d'envoi » (sous-page où
//                vivent, ensemble, le jeton de l'iPhone et celui du serveur).
//    • legacy  → adb depuis l'hôte, rien à régler ici.
//  La fraîcheur/l'inventaire (indépendants de la source) restent dans la section
//  « État de la synchro ».
//

import SwiftUI
import UIKit

struct SettingsSyncPage: View {
    var viewModel: SettingsViewModel
    let onStatus: () -> Void

    var body: some View {
        Form {
            SettingsSyncSourceSection(viewModel: viewModel, onStatus: onStatus)
            SettingsStatusSection(viewModel: viewModel)
        }
        .navigationTitle("Synchronisation")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Source

private struct SettingsSyncSourceSection: View {
    var viewModel: SettingsViewModel
    let onStatus: () -> Void
    /// Jeton enregistré sur l'iPhone, relu à chaque retour sur la page (la
    /// sous-page peut l'avoir changé) pour la valeur de la ligne « Jeton d'envoi ».
    @State private var deviceToken = PulseConfig.ingestToken

    var body: some View {
        Section {
            Picker("Source", selection: sourceBinding) {
                ForEach(SettingsSyncSourceKind.selectable) { kind in
                    Text(kind.label).tag(kind.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isChangingSource)

            if let source = viewModel.source {
                if source.source == "bridge" {
                    LabeledContent("Adresse", value: source.url)
                    HStack(spacing: PulseSpacing.xs) {
                        Circle()
                            .fill(source.reachable == true ? Color.pulseSuccess : Color.pulseDanger)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(source.reachable == true ? "garmin-bridge répond" : "garmin-bridge ne répond pas")
                            .font(.footnote)
                    }
                    .accessibilityElement(children: .combine)
                    if source.reachable != true, let detail = source.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    Button(action: onStatus) {
                        HStack {
                            Text("Statut du pont").foregroundStyle(Color.pulseTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.pulseAbsent)
                        }
                        .contentShape(Rectangle())
                    }
                }

                if source.source == "phone" {
                    NavigationLink {
                        SettingsIngestTokenPage(viewModel: viewModel)
                    } label: {
                        HStack {
                            Text("Jeton d'envoi")
                            Spacer(minLength: PulseSpacing.sm)
                            switch SettingsIngestTokenStatus.compare(device: deviceToken, server: source.ingestToken) {
                            case .ok:
                                Text("OK").foregroundStyle(Color.pulseTextSecondary)
                            case .needsUpdate:
                                Text("À mettre à jour").foregroundStyle(Color.pulseDanger)
                            case nil:
                                EmptyView()
                            }
                        }
                    }
                }
            }
        } footer: {
            footer
        }
        .onAppear { deviceToken = PulseConfig.ingestToken }
    }

    /// Pied très court : réglage imposé par le conteneur, source refusée, erreur.
    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
            if let source = viewModel.source, source.overridden {
                Text("Imposé par le conteneur (\(source.configured == "bridge" ? "bridge" : "legacy")), remplacé ici.")
            }
            // Source serveur sur la chaîne historique (masquée du sélecteur) :
            // Pulse refuse alors les envois de l'app — on le dit, sinon rien
            // n'indique pourquoi les données n'arrivent plus.
            if viewModel.source?.source == SettingsSyncSourceKind.legacy.rawValue {
                Text("Pulse refuse les envois de l'app (source « legacy »).")
                    .foregroundStyle(Color.pulseDanger)
            }
            if let sourceError = viewModel.sourceError {
                Text(sourceError)
                    .foregroundStyle(Color.pulseDanger)
            }
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
}

// MARK: - Jeton d'envoi (un seul endroit)
//
// Deux jetons doivent coïncider : celui que l'iPhone présente
// (`PulseConfig.ingestToken`) et celui que le serveur accepte
// (`SettingsSyncSource.ingestToken`). Copie locale vers le presse-papiers :
// aucune transmission réseau propre à ce geste ; seule la régénération appelle
// le serveur (`SettingsViewModel.regenerateIngestToken`).

private struct SettingsIngestTokenPage: View {
    var viewModel: SettingsViewModel
    @State private var health = PulseUploadHealth.shared
    @State private var deviceToken = PulseConfig.ingestToken ?? ""
    @State private var copied = false
    @State private var confirmRegenerate = false

    private var serverToken: String? { viewModel.source?.ingestToken }

    var body: some View {
        Form {
            Section("Sur cet iPhone") {
                SecureField("Jeton", text: $deviceToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .submitLabel(.done)
                    .onSubmit(saveDeviceToken)
                if SettingsIngestTokenStatus.compare(device: deviceToken, server: serverToken) == .needsUpdate,
                   let serverToken {
                    Button("Utiliser le jeton du serveur sur cet iPhone") {
                        deviceToken = serverToken
                        saveDeviceToken()
                    }
                }
            }

            Section {
                Text(serverToken ?? "—")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    guard let serverToken else { return }
                    UIPasteboard.general.string = serverToken
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    HStack {
                        Text("Copier")
                        Spacer()
                        if copied { Text("Copié").foregroundStyle(Color.pulseSuccess) }
                    }
                }
                .disabled(serverToken == nil)

                Button(role: .destructive) { confirmRegenerate = true } label: {
                    HStack {
                        Text("Régénérer")
                        if viewModel.isRegeneratingToken { Spacer(); ProgressView() }
                    }
                }
                .disabled(viewModel.isRegeneratingToken)
            } header: {
                Text("Sur le serveur")
            } footer: {
                if let sourceError = viewModel.sourceError {
                    Text(sourceError).foregroundStyle(Color.pulseDanger)
                }
            }
        }
        .navigationTitle("Jeton d'envoi")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: saveDeviceToken)
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .confirmationDialog("Régénérer le jeton du serveur ?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Régénérer", role: .destructive) {
                Task { await viewModel.regenerateIngestToken() }
            }
        } message: {
            Text("L'ancien jeton cesse de fonctionner.")
        }
    }

    /// Enregistre le jeton de l'iPhone (vide = effacé) et lève l'alerte « jeton
    /// refusé » : le prochain envoi dira si le nouveau convient.
    private func saveDeviceToken() {
        let trimmed = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? nil : trimmed
        guard next != PulseConfig.ingestToken else { return }
        PulseConfig.ingestToken = next
        health.clearConfigProblem()
    }
}

// MARK: - Synchronisation > État

private struct SettingsStatusSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        Section("État de la synchro") {
            if let status = viewModel.status {
                // État / dernier succès / progression / message décrivent la
                // collecte faite PAR LE SERVEUR (pont, ou à défaut l'ancienne
                // chaîne par câble). Quand c'est l'iPhone qui collecte, le
                // serveur renvoie l'état figé de l'ancienne chaîne — un « Erreur »
                // permanent sans rapport avec la synchro réelle : on ne
                // l'affiche pas. La fraîcheur, elle, vient des données reçues.
                if viewModel.source?.source == SettingsSyncSourceKind.bridge.rawValue {
                    LabeledContent("État") {
                        Text(Self.stateLabel(status.state))
                            .foregroundStyle(Self.stateColor(status.state))
                    }
                    if let lastSuccess = status.lastSuccess {
                        LabeledContent("Dernier succès", value: lastSuccess)
                    }
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
                LabeledContent("Fraîcheur des données", value: Self.freshnessLabel(status.freshness))
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
        // État neutre ("idle") — même jeton que le point du lien BLE côté
        // écran Statut (`--absent`, distinct de `--text-dim`).
        default: return .pulseAbsent
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
