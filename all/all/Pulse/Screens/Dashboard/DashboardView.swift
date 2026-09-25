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
                    DashboardSegRow(
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
            // `.top .h1` + `.seg` côté Angular : titre et sélecteur de période
            // sur la même ligne — le `Picker` système (`.segmented`) est
            // remplacé par une piste maison (`DashboardPeriodTrack`) qui
            // reprend l'habillage réel de la maquette (piste grise, pilule
            // active en relief blanc) plutôt que le rendu natif iOS.
            HStack(alignment: .center, spacing: PulseSpacing.md) {
                Text("Statistiques")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.pulseTextPrimary)
                Spacer()
                DashboardPeriodTrack(selection: Binding(
                    get: { viewModel.period },
                    set: { viewModel.selectPeriod($0) }
                ))
            }

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

/// Rangée d'onglets défilable horizontalement — `nav.tabs`/`.tab` côté
/// Angular (pilule pleine largeur de contenu, capsule complète — cf. maquette
/// « Statistiques » 560-849 ; pas de survol sur iOS, un seul état actif).
struct DashboardChipRow<Value: Hashable>: View {
    let items: [(Value, String)]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { value, label in
                    Button {
                        onSelect(value)
                    } label: {
                        Text(label)
                            .font(.system(size: 13, weight: value == selection ? .medium : .regular))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .background(value == selection ? Color.pulseTextPrimary : Color.pulseSurface)
                            .foregroundStyle(value == selection ? Color.pulseBackground : Color.pulseTextSecondary)
                            .overlay(
                                Capsule().strokeBorder(value == selection ? Color.clear : Color.pulseBorder, lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Sélecteur de sous-vue — `<app-seg class="views">` côté Angular. Contrairement
/// à `DashboardChipRow` (onglets, capsule, défilante), la maquette la rend en
/// pleine largeur, sans défilement : pilules d'angle 9 pt de largeur égale.
struct DashboardSegRow<Value: Hashable>: View {
    let items: [(Value, String)]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.0) { value, label in
                Button {
                    onSelect(value)
                } label: {
                    Text(label)
                        .font(.system(size: 13, weight: value == selection ? .semibold : .regular))
                        .foregroundStyle(value == selection ? Color.pulseBackground : Color.pulseTextSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(value == selection ? Color.pulseTextPrimary : Color.pulseSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(value == selection ? Color.clear : Color.pulseBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Piste de période — `<app-seg variant="track">` côté Angular : fond gris
/// arrondi, pilule active en relief blanc/surface. Remplace le `Picker`
/// système (`.segmented`) dont l'habillage natif iOS n'a pas d'équivalent
/// dans la maquette.
private struct DashboardPeriodTrack: View {
    @Binding var selection: DashboardPeriod

    var body: some View {
        HStack(spacing: 3) {
            ForEach(DashboardPeriod.allCases) { period in
                Button {
                    selection = period
                } label: {
                    Text(period.shortLabel)
                        .font(.system(size: 11, weight: period == selection ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(period == selection ? Color.pulseTextPrimary : Color.pulseTextSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(period == selection ? Color.pulseSurface : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(period == selection ? Color.pulseBorder : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.pulseSurfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Rangée de figures façon `.figrow` côté Angular. Sur téléphone, Pulse (web
/// responsive) n'affiche que les 3 premières figures — les 3 suivantes ne
/// réapparaissent qu'à partir de 900 px (SCSS
/// `.figrow:not(.sk) .fig:nth-child(n+4){display:none}`, levé par
/// `@media(min-width:900px)`). L'app étant toujours "étroite", on reproduit
/// cette troncature plutôt que de tout montrer sur trois lignes de deux —
/// d'où une grille à 3 colonnes / 1 ligne plutôt que le `StatTile` 2 colonnes
/// du socle partagé (qui a par ailleurs une valeur bien plus grande que le
/// `.fig-n` 19 px de la maquette).
struct DashboardFigureRow: View {
    let tiles: [DashboardFigure]

    private var visibleTiles: [DashboardFigure] { Array(tiles.prefix(3)) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(visibleTiles) { tile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.label.uppercased())
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Color.pulseTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(tile.value)
                            .font(.system(size: 19, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tile.accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let unit = tile.unit {
                            Text(unit)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pulseSurface)
        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                .strokeBorder(Color.pulseBorder, lineWidth: 1)
        )
    }
}

struct DashboardFigure: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var unit: String?
    /// `.fig-n` côté Angular est en couleur de texte primaire par défaut —
    /// seuls `deltaPct` (entraînement) et `balance` (nutrition) se colorent
    /// (`.good`/`.bad`) via un `accent` explicite au site d'appel.
    var accent: Color = .pulseTextPrimary
}

/// En-tête de carte façon `.panel h2` côté Angular : légende mono, majuscule,
/// espacée, couleur atténuée — remplace `SectionHeader` du socle partagé
/// (`DesignSystem.swift`, hors périmètre) dont le rendu `.headline` système
/// ne correspond ni à ce style `h2` ni à `.insight h3` (celui-ci reste en
/// `.headline`, laissé tel quel dans les cartes de `DashboardSleepSection`).
struct DashboardCardHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(Color.pulseTextSecondary)
            Spacer()
            trailing
        }
    }
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
            DashboardCardHeader(tabLabel) {
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
            DashboardCardHeader("Carte")
            Text("La carte des sorties (tracés GPS) n'est pas encore portée nativement — c'est un écran à part, pas une simple carte de ce tableau de bord.")
                .font(PulseFont.body)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}
