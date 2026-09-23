//
//  ProgrammeView.swift
//  all (bridge-connect)
//
//  Écran Programme natif — équivalent SwiftUI de la page Angular `/programme`
//  (`custom-connect/web/src/app/pages/programme/programme.component.ts`) :
//  les trois domaines (entraînement, alimentation, sommeil), chacun avec son
//  programme actif (si présent) et sa bibliothèque de choix.
//
//  Priorité à l'affichage fidèle (progression de la semaine, calendrier des
//  séances, jauges des cibles du jour, critères de sommeil). Actions câblées
//  de façon raisonnable : activer/arrêter un programme (avec sélection des
//  jours), cocher une séance, envoyer les séances à la montre — cf.
//  `ProgrammeViewModel` et `ProgrammeLibrarySheet` pour le détail de ce qui a
//  été simplifié (pas de rapprochement d'activités importées).
//
//  Toutes les déclarations top-level de ce dossier sont préfixées
//  `Programme*` — un seul module partagé avec les autres écrans
//  (`Screens/Home`, `Screens/Nutrition`…), cf. l'en-tête de
//  `ProgrammeModels.swift`.
//

import SwiftUI

struct ProgrammeView: View {
    @State private var viewModel = ProgrammeViewModel()

    var body: some View {
        NavigationStack {
            content
                .background(Color.pulseBackground)
                .navigationTitle("Programme")
                .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: Binding(
            get: { viewModel.libraryKind != nil },
            set: { presented in if !presented { viewModel.closeLibrary() } }
        )) {
            if let domain = viewModel.libraryDomain {
                ProgrammeLibrarySheet(
                    domain: domain,
                    isBusy: viewModel.isBusy,
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

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingView(message: "Chargement du programme…")
        case .failed(let message):
            ErrorView(message: message) {
                Task { await viewModel.load() }
            }
        case .loaded:
            loadedContent
        }
    }

    private var loadedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                header

                ForEach(viewModel.domains) { domain in
                    ProgrammeDomainSection(domain: domain, viewModel: viewModel)
                }

                ProgrammeLibraryCard(domains: viewModel.domains) { kind in
                    viewModel.openLibrary(for: kind)
                }
            }
            .padding(PulseSpacing.lg)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Programme").font(.largeTitle.bold())
            Spacer()
            Text(programmeActiveNote(viewModel.domains))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

/// Aiguille vers la carte du bon domaine — `nil` si aucun programme actif
/// (le domaine n'affiche alors que sa présence dans la bibliothèque).
private struct ProgrammeDomainSection: View {
    let domain: ProgrammeDomainView
    var viewModel: ProgrammeViewModel

    var body: some View {
        Group {
            if domain.active != nil, let detail = domain.detail {
                switch detail {
                case .training(let trainingDetail):
                    ProgrammeTrainingSection(domain: domain, detail: trainingDetail, viewModel: viewModel)
                case .nutrition(let nutritionDetail):
                    ProgrammeNutritionCard(domain: domain, detail: nutritionDetail)
                case .sleep(let sleepDetail):
                    ProgrammeSleepSection(domain: domain, detail: sleepDetail)
                }
            }
        }
    }
}

/// Carte « Bibliothèque » en bas d'écran — un programme catalogué compte
/// aussi les programmes de debug (`kind == training`, cf. `catalogue.ts`),
/// affichés tels quels comme côté Angular.
private struct ProgrammeLibraryCard: View {
    let domains: [ProgrammeDomainView]
    let onOpen: (ProgrammeKind) -> Void

    var body: some View {
        PulseCard {
            HStack {
                Text("Bibliothèque").font(PulseFont.sectionTitle)
                Spacer()
                Text("\(domains.reduce(0) { $0 + $1.choices.count }) programmes")
                    .font(.caption2)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(domains.enumerated()), id: \.element.id) { index, domain in
                    if index > 0 {
                        Divider()
                    }
                    Button {
                        onOpen(domain.kind)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(domain.label).font(.subheadline.weight(.semibold))
                                Text(programmeLibraryNote(domain))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.pulseTextSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Color.pulseTextSecondary)
                        }
                        .foregroundStyle(Color.pulseTextPrimary)
                        .padding(.vertical, PulseSpacing.sm)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#Preview {
    ProgrammeView()
}
