//
//  ProgrammeView.swift
//  all (bridge-connect)
//
//  Écran Programme natif, en deux niveaux : une carte résumé par domaine
//  (entraînement, alimentation, sommeil) → page de détail. Un domaine sans
//  programme actif n'est qu'une carte discrète qui ouvre sa bibliothèque ;
//  les fiches « À propos » (`ProgrammeAbout.swift`) portent objectif, source,
//  notes et l'arrêt du programme.
//
//  Toutes les déclarations top-level de ce dossier sont préfixées
//  `Programme*` — un seul module partagé avec les autres écrans
//  (`Screens/Home`, `Screens/Nutrition`…), cf. l'en-tête de
//  `ProgrammeModels.swift`.
//

import SwiftUI

struct ProgrammeView: View {
    @State fileprivate var viewModel = ProgrammeViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showBravo = false

    var body: some View {
        NavigationStack {
            content
                .background(Color.pulseBackground)
                // Programme est une feuille présentée depuis Paramètres :
                // titre système + bouton fermer, comme Statut/Montre.
                .navigationTitle("Programme")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    SheetCloseButton { dismiss() }
                }
        }
        .task {
            await viewModel.reload()
            presentBravoIfNeeded()
        }
        .programmeBravoCover(isPresented: $showBravo, viewModel: viewModel)
        .sheet(item: Binding(
            get: { viewModel.showObjectives ? .objectives : viewModel.libraryKind.map(ProgrammeSheet.library) },
            set: { sheet in
                if sheet == nil { viewModel.showObjectives = false; viewModel.closeLibrary() }
            }
        )) { sheet in
            switch sheet {
            case .objectives:
                ProgrammeObjectiveSheet(viewModel: viewModel) { viewModel.showObjectives = false }
            case .library:
                if let domain = viewModel.libraryDomain {
                    ProgrammeLibrarySheet(
                        domain: domain,
                        isBusy: viewModel.isBusy,
                        suggest: { viewModel.daySuggestion(perWeek: $0) },
                        loadHabits: { await viewModel.loadHabitsIfNeeded() },
                        onActivate: { id, days in
                            Task {
                                await viewModel.activate(programmeId: id, days: days)
                                viewModel.closeLibrary()
                            }
                        },
                        onStop: {
                            Task {
                                await viewModel.stop(domain.kind)
                                viewModel.closeLibrary()
                            }
                        }
                    )
                }
            }
        }
    }

    /// Bilan de fin de bloc : une seule fois par exécution du programme.
    private func presentBravoIfNeeded() {
        guard let training = viewModel.trainingDomain,
              programmeFinished(training),
              let active = training.active,
              !programmeBravoSeen(programmeId: active.programmeId, startedOn: active.startedOn)
        else { return }
        programmeBravoMarkSeen(programmeId: active.programmeId, startedOn: active.startedOn)
        showBravo = true
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingView(message: "Chargement du programme…")
        case .failed(let message):
            ErrorView(message: message) {
                Task { await viewModel.reload() }
            }
        case .loaded:
            loadedContent
        }
    }

    private var loadedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let message = viewModel.actionError {
                    DashboardInlineError(message: message) { Task { await viewModel.reload() } }
                }

                objectiveEntry

                ForEach(viewModel.domains) { domain in
                    // Sans objectif ni programme, la carte vide ferait doublon
                    // avec « Choisir un objectif » (sauf le sommeil).
                    if domain.kind == .sleep || domain.active != nil || hasAnyTrainingOrNutrition {
                        ProgrammeSummaryCard(domain: domain, viewModel: viewModel)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .pulseTabBarClearance()
    }
}

// MARK: - Entrée « objectif »

private enum ProgrammeSheet: Identifiable, Equatable {
    case objectives
    case library(ProgrammeKind)

    var id: String {
        switch self {
        case .objectives: "objectives"
        case .library(let kind): "library-\(kind.rawValue)"
        }
    }
}

extension ProgrammeView {
    fileprivate var hasAnyTrainingOrNutrition: Bool {
        viewModel.domains.contains { $0.kind != .sleep && $0.active != nil }
    }

    /// Bouton principal quand rien n'est actif ; sinon « Objectif » + nom + « Changer » (texte).
    @ViewBuilder
    fileprivate var objectiveEntry: some View {
        if !hasAnyTrainingOrNutrition {
            Button("Choisir un objectif") { viewModel.openObjectives() }
                .buttonStyle(.programmePrimary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    ProgrammeLabel("Objectif")
                    Text(objectiveName)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.pulseTextPrimary)
                }
                Spacer()
                Button("Changer") { viewModel.openObjectives() }
                    .buttonStyle(.programmeText)
            }
            .padding(.horizontal, 2)
        }
    }

    private var objectiveName: String {
        if let objective = programmeActiveObjective(domains: viewModel.domains) { return objective.name }
        return viewModel.domains
            .filter { $0.kind != .sleep }
            .compactMap { $0.active?.name }
            .joined(separator: " · ")
    }
}

// MARK: - Carte résumé d'un domaine

/// Programme actif → lien vers le détail ; sinon rangée « Choisir un
/// programme » qui ouvre la bibliothèque du domaine.
private struct ProgrammeSummaryCard: View {
    let domain: ProgrammeDomainView
    var viewModel: ProgrammeViewModel

    var body: some View {
        if domain.active != nil, domain.detail != nil {
            NavigationLink {
                destination
            } label: {
                ProgrammeCard(spacing: 14) {
                    HStack {
                        ProgrammeLabel(domain.label)
                        Spacer()
                        ProgrammeChevron()
                    }
                    summary
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                viewModel.openLibrary(for: domain.kind)
            } label: {
                ProgrammeCard {
                    HStack {
                        Text(domain.label)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.pulseTextPrimary)
                        Spacer()
                        Text("Choisir un programme")
                            .font(.programmeMono(11))
                            .foregroundStyle(Color.pulseTextSecondary)
                        ProgrammeChevron()
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch domain.kind {
        case .training: ProgrammeTrainingDetailView(viewModel: viewModel)
        case .nutrition: ProgrammeNutritionDetailView(viewModel: viewModel)
        case .sleep: ProgrammeSleepDetailView(viewModel: viewModel)
        }
    }

    private var name: String { domain.active?.name ?? domain.label }

    @ViewBuilder
    private var summary: some View {
        switch domain.detail {
        case .training(let detail):
            trainingSummary(detail)
        case .nutrition(let detail):
            titleLine(trailing: programmeNutritionSummary(detail.today))
        case .sleep(let detail):
            titleLine(trailing: "\(detail.hits)/\(detail.total) critères")
        case nil:
            EmptyView()
        }
    }

    private func titleLine(trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.pulseTextPrimary)
            Spacer()
            Text(trailing)
                .font(.programmeMono(13))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    private func trainingSummary(_ detail: ProgrammeTrainingDetail) -> some View {
        let active = domain.active
        let week = active?.week ?? 1
        let weekSessions = detail.sessions.filter { $0.week == week }
        let done = weekSessions.filter(\.done).count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.pulseTextPrimary)
                Spacer()
                if programmeFinished(domain) {
                    Text("Terminé")
                        .font(.programmeMono(11, weight: .semibold))
                        .foregroundStyle(Color.pulseTextPrimary)
                } else if let active, active.weeks > 0 {
                    Text("S\(active.week)/\(active.weeks)")
                        .font(.programmeMono(11))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            if !weekSessions.isEmpty {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    ProgrammeBigNumber(value: "\(done)", total: "\(weekSessions.count)")
                    Text("cette semaine")
                        .font(.programmeMono(11))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            if !programmeFinished(domain), let next = programmeNextSummary(detail: detail, week: week) {
                Text(next)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }
}

#Preview {
    ProgrammeView()
}
