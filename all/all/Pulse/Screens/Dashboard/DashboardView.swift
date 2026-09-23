//
//  DashboardView.swift
//  all (bridge-connect)
//
//  Vue racine de l'écran Dashboard (« Statistiques » côté Pulse) — en-tête
//  période + onglets, puis dispatch vers la section de l'onglet actif. Point
//  d'entrée exposé pour le hub « Plus ».
//

import SwiftUI

struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()

    var body: some View {
        Group {
            if viewModel.hasAnyData {
                loadedContent
            } else {
                switch viewModel.state {
                case .loading:
                    LoadingView(message: "Chargement des statistiques…")
                case .failed(let message):
                    ErrorView(message: message) { viewModel.retry() }
                case .loaded:
                    // Cas transitoire : données arrivées mais toutes vides,
                    // le contenu ci-dessous gère l'état "rien sur la période".
                    loadedContent
                }
            }
        }
        .background(Color.pulseBackground)
        .task { await viewModel.loadIfNeeded() }
    }

    private var loadedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                header

                if case .failed(let message) = viewModel.state {
                    DashboardInlineError(message: message) { viewModel.retry() }
                }

                if !dashboardSubViews(for: viewModel.tab).isEmpty {
                    DashboardChipRow(
                        items: dashboardSubViews(for: viewModel.tab).map { ($0, $0.label) },
                        selection: viewModel.subView
                    ) { viewModel.selectSubView($0) }
                }

                if viewModel.isCurrentTabEmpty {
                    DashboardEmptyTabCard(periodLabel: viewModel.period.label, tabLabel: viewModel.tab.label)
                } else {
                    tabBody
                }
            }
            .padding(PulseSpacing.lg)
        }
        .refreshable { await viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.md) {
            Text("Statistiques")
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(Color.pulseTextPrimary)

            Picker("Période", selection: Binding(
                get: { viewModel.period },
                set: { viewModel.selectPeriod($0) }
            )) {
                ForEach(DashboardPeriod.allCases) { period in
                    Text(period.shortLabel).tag(period)
                }
            }
            .pickerStyle(.segmented)

            DashboardChipRow(
                items: DashboardTab.allCases.map { ($0, $0.label) },
                selection: viewModel.tab
            ) { viewModel.selectTab($0) }
        }
    }

    @ViewBuilder
    private var tabBody: some View {
        switch viewModel.tab {
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

// MARK: - Composants partagés de l'écran

/// Rangée de "chips" défilable horizontalement — équivalent tactile de
/// `<app-seg>`/`.tabs` côté Angular (pas de survol sur iOS, un seul état actif).
struct DashboardChipRow<Value: Hashable>: View {
    let items: [(Value, String)]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PulseSpacing.sm) {
                ForEach(items, id: \.0) { value, label in
                    Button {
                        onSelect(value)
                    } label: {
                        Text(label)
                            .font(.system(.subheadline, weight: value == selection ? .semibold : .regular))
                            .padding(.horizontal, PulseSpacing.md)
                            .padding(.vertical, PulseSpacing.sm)
                            .background(value == selection ? Color.pulseTextPrimary : Color.pulseSurfaceAlt)
                            .foregroundStyle(value == selection ? Color.pulseBackground : Color.pulseTextSecondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Rangée de tuiles de figures façon `.figrow` — grille adaptative de
/// `StatTile`, réutilisée par les 3 onglets à en-tête chiffré.
struct DashboardFigureRow: View {
    let tiles: [DashboardFigure]

    var body: some View {
        PulseCard {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: PulseSpacing.lg) {
                ForEach(tiles) { tile in
                    StatTile(label: tile.label, value: tile.value, unit: tile.unit, accent: tile.accent)
                }
            }
        }
    }
}

struct DashboardFigure: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var unit: String?
    var accent: Color = .pulseAccent
}

/// Bannière d'erreur discrète affichée au-dessus d'un contenu déjà chargé
/// (rafraîchissement en échec) — `ErrorView` plein écran ne sert que quand on
/// n'a encore aucune donnée.
struct DashboardInlineError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: PulseSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.pulseDanger)
            Text(message)
                .font(PulseFont.body)
                .foregroundStyle(Color.pulseTextPrimary)
            Spacer()
            Button("Réessayer", action: retry)
                .font(.footnote)
        }
        .padding(PulseSpacing.md)
        .background(Color.pulseSurfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous))
    }
}

/// `@if (emptyTab())` côté Angular.
struct DashboardEmptyTabCard: View {
    let periodLabel: String
    let tabLabel: String

    var body: some View {
        PulseCard {
            SectionHeader(tabLabel) {
                Text("rien sur \(periodLabel)")
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Text("Aucune donnée sur \(periodLabel) : les valeurs restent au tiret plutôt que de descendre à zéro. Élargis la période, ou synchronise la montre.")
                .font(PulseFont.body)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

/// Onglet « Carte » — `<app-activity-map>` côté Angular est un composant de
/// carte GPS interactive à part entière (27 Ko de TS, tracés d'activités) :
/// hors périmètre d'un écran Dashboard, un écran natif dédié y ferait plus
/// justice. Ce placeholder évite un onglet muet.
struct DashboardMapPlaceholderCard: View {
    var body: some View {
        PulseCard {
            SectionHeader("Carte")
            Text("La carte des sorties (tracés GPS) n'est pas encore portée nativement — c'est un écran à part, pas une simple carte de ce tableau de bord.")
                .font(PulseFont.body)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}
