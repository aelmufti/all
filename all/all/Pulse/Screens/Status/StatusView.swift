//
//  StatusView.swift
//  all (bridge-connect)
//
//  Écran Statut — port natif de `custom-connect/web/src/app/pages/status/status.component.ts`
//  (+ `shared/sync-card.component.ts`, embarquée là-bas) : trois cartes —
//  lien BLE bridge ↔ montre, synchronisation automatique, état d'une synchro
//  manuelle/fraîcheur des données — plus une note d'action transitoire.
//  Trois états globaux : chargement (`LoadingView`), erreur (`ErrorView`),
//  données. Rafraîchissement par tirer-pour-rafraîchir (`.refreshable`),
//  cf. note de `StatusViewModel` sur l'absence de sondage périodique.
//
//  À brancher dans `PulseShellView` — pas de dépendance de navigation
//  externe : l'écran gère sa propre `NavigationStack`.
//

import SwiftUI

struct StatusView: View {
    @State private var viewModel = StatusViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Statut")
                .background(Color.pulseBackground)
        }
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingView(message: "Lecture du statut…")
        case .failed(let message):
            ErrorView(message: message) {
                Task { await viewModel.load() }
            }
        case .loaded:
            ScrollView {
                VStack(spacing: PulseSpacing.lg) {
                    StatusLinkCard(viewModel: viewModel)
                    StatusAutoSyncCard(viewModel: viewModel)
                    StatusSyncStatusCard(viewModel: viewModel)

                    if let note = viewModel.actionNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(Color.pulseTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(
                        "Page privée : ces informations disent qui est à la maison, elles ne " +
                            "sortent jamais sur la route publique api/health."
                    )
                    .font(.caption2)
                    .foregroundStyle(Color.pulseTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(PulseSpacing.lg)
            }
            .refreshable { await viewModel.load() }
        }
    }
}

// MARK: - Lien BLE

private struct StatusLinkCard: View {
    let viewModel: StatusViewModel

    var body: some View {
        PulseCard {
            HStack(spacing: PulseSpacing.sm) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                Text(viewModel.linkStateLabel)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(Color.pulseTextPrimary)
                Spacer()
                if viewModel.showConnectButton {
                    Button(viewModel.isConnecting ? "Connexion…" : "Connecter") {
                        Task { await viewModel.connect() }
                    }
                    .font(.footnote)
                    .disabled(viewModel.isConnecting)
                    .tint(Color.pulseAccent)
                }
            }

            VStack(alignment: .leading, spacing: PulseSpacing.md) {
                StatusFact(label: "Signal", value: viewModel.signalValue, note: viewModel.signalNote)
                StatusFact(
                    label: "Dernière vue", value: viewModel.lastSeenLabel, note: viewModel.lastSeenNote)
                if let retryValue = viewModel.retryValue {
                    StatusFact(
                        label: "Prochaine tentative", value: retryValue, note: viewModel.retryNote)
                }
            }

            if let message = viewModel.linkMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(viewModel.linkTone == .bad ? Color.pulseDanger : Color.pulseTextPrimary)
            }
            if let recovery = viewModel.recoveryMessage {
                Text(recovery)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseDanger)
            }
        }
    }

    private var dotColor: Color {
        switch viewModel.linkTone {
        case .ok: return .pulseSuccess
        case .bad: return .pulseDanger
        case .warn, .idle: return .pulseTextSecondary
        }
    }
}

/// Bloc libellé/valeur/note du lien BLE — miroir de `.fact` (SCSS) : libellé
/// mono discret en capitales, valeur en tabulaire, note discrète en dessous.
private struct StatusFact: View {
    let label: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
                .tracking(0.6)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.pulseTextPrimary)
            if !note.isEmpty {
                Text(note)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }
}

// MARK: - Synchronisation automatique

private struct StatusAutoSyncCard: View {
    let viewModel: StatusViewModel

    var body: some View {
        PulseCard {
            SectionHeader("Synchronisation automatique")

            StatusRow(label: "État") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(viewModel.autoSyncHeadline)
                        .font(.system(.subheadline))
                        .foregroundStyle(Color.pulseTextPrimary)
                    if let sub = viewModel.autoSyncStallNote {
                        Text(sub)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }
            }

            StatusRow(label: "Fichiers en attente") {
                Text("\(viewModel.autoSync?.pending ?? 0)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Color.pulseTextPrimary)
            }

            StatusRow(label: "Dernier sync réussi") {
                Text(viewModel.autoSyncLastSuccessLabel)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Color.pulseTextPrimary)
            }

            StatusRow(label: "Prochain passage") {
                VStack(alignment: .trailing, spacing: 2) {
                    if let next = viewModel.autoSyncNextAttemptLabel {
                        Text(next)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(Color.pulseTextPrimary)
                        if let countdown = viewModel.autoSyncCountdown {
                            Text("dans \(countdown)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                    } else {
                        Text("désactivé")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }
            }

            StatusRow(label: "Cadence") {
                Text(viewModel.autoSyncCadence)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Color.pulseTextPrimary)
            }
        }
    }
}

/// Ligne libellé/valeur des cartes "tableau" — miroir de `.row` (SCSS) :
/// libellé à gauche, valeur alignée à droite.
private struct StatusRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(.subheadline))
                .foregroundStyle(Color.pulseTextPrimary)
            Spacer()
            value
        }
    }
}

// MARK: - État de synchro manuelle + fraîcheur

private struct StatusSyncStatusCard: View {
    let viewModel: StatusViewModel

    var body: some View {
        PulseCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                    Text("Synchronisation montre")
                        .font(.system(.headline, weight: .semibold))
                        .foregroundStyle(Color.pulseTextPrimary)

                    if let fresh = viewModel.syncFreshLabel {
                        Text("Données à jour il y a \(fresh)")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Color.pulseTextPrimary)
                    } else {
                        Text("Aucune donnée de santé enregistrée")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }

                    if let lastSync = viewModel.syncLastSuccessLabel {
                        Text("Dernière synchro réussie : \(lastSync)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                    } else {
                        Text("Aucune synchro enregistrée")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }

                    if let running = viewModel.syncRunningLabel {
                        if let ratio = viewModel.syncProgressRatio {
                            ProgressView(value: ratio)
                                .tint(Color.pulseTextPrimary)
                        }
                        Text(running)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color.pulseSuccess)
                    } else if let waiting = viewModel.syncWaitingLabel {
                        Text(waiting)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }

                    if let message = viewModel.syncStatus?.message {
                        Text(message)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(
                                viewModel.syncStatus?.state == .error
                                    ? Color.pulseDanger : Color.pulseSuccess
                            )
                    }
                }
                Spacer()
                Button(viewModel.syncButtonLabel) {
                    Task { await viewModel.triggerSync() }
                }
                .font(.footnote)
                .disabled(viewModel.syncButtonDisabled)
                .tint(Color.pulseAccent)
            }
        }
    }
}

#Preview {
    StatusView()
}
