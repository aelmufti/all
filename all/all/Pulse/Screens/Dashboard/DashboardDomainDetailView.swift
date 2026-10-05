//
//  DashboardDomainDetailView.swift
//  all (bridge-connect)
//
//  Écran de détail d'un domaine — poussé depuis l'aperçu (`DashboardView`) via
//  `NavigationLink(value: DashboardTab...)`. Réutilise telles quelles les
//  sections existantes (Sommeil/Entraînement/Santé/Nutrition) + le
//  placeholder Carte : seule la coquille (sélecteur de sous-vue + en-tête) est
//  nouvelle ici, le contenu détaillé ne change pas.
//
//  Barre de navigation : laissée **visible** (titre inline = `tab.label`)
//  plutôt que masquée + bouton retour maison — c'est le geste de retour natif
//  du `NavigationStack` qui permet de quitter cet écran, on ne le sacrifie pas
//  pour un gain visuel marginal. Le titre 24pt de l'aperçu n'est donc pas
//  dupliqué ici.
//

import SwiftUI

struct DashboardDomainDetailView: View {
    let tab: DashboardTab
    let viewModel: DashboardViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                // Temporalité en clair, sous le titre — plutôt qu'une puce mono
                // dans le coin haut-droit de la barre de navigation.
                Text(periodPhrase)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if case .failed(let message) = viewModel.state {
                    DashboardInlineError(message: message) { viewModel.retry() }
                }

                if !dashboardSubViews(for: tab).isEmpty {
                    DashboardSegRow(
                        items: dashboardSubViews(for: tab).map { ($0, $0.label) },
                        selection: viewModel.subView
                    ) { viewModel.selectSubView($0) }
                }

                if viewModel.isCurrentTabEmpty {
                    DashboardEmptyTabCard(periodLabel: viewModel.period.label, tabLabel: tab.label)
                } else {
                    domainBody
                }
            }
            .padding(PulseSpacing.lg)
        }
        .background(Color.pulseBackground)
        .pulseTabBarClearance()
        .refreshable { await viewModel.reload() }
        .navigationTitle(tab.label)
        .navigationBarTitleDisplayMode(.inline)
        // Fixe le domaine actif (et réinitialise `subView` à la 1re sous-vue
        // valide) à chaque apparition — cf. `DashboardViewModel.selectTab`.
        // Sans ça, une `subView` laissée par un AUTRE domaine pourrait rester
        // sélectionnée dans le `DashboardSegRow` ci-dessus.
        .onAppear { viewModel.selectTab(tab) }
    }

    /// Période en langage naturel (remplace la puce « 3 mois »).
    private var periodPhrase: String {
        switch viewModel.period {
        case .oneMonth: return "Sur le dernier mois"
        case .threeMonths: return "Sur les 3 derniers mois"
        case .oneYear: return "Sur la dernière année"
        case .all: return "Depuis le début"
        }
    }

    @ViewBuilder
    private var domainBody: some View {
        switch tab {
        case .sleep:
            DashboardSleepSection(viewModel: viewModel)
        case .training:
            DashboardTrainingSection(viewModel: viewModel)
        case .health:
            DashboardHealthSection(viewModel: viewModel)
        case .nutrition:
            DashboardNutritionSection(viewModel: viewModel)
        case .map:
            DashboardMapPlaceholderCard()
        }
    }
}
