//
//  DashboardView.swift
//  all (bridge-connect)
//
//  Vue racine de l'écran Dashboard (« Statistiques » côté Pulse) — « aperçu
//  d'abord » : en-tête période + une carte de résumé par domaine (Sommeil,
//  Entraînement, Santé, Nutrition) + une ligne Carte, chacune poussant
//  `DashboardDomainDetailView` (contenu détaillé, section réutilisée telle
//  quelle). Remplace l'ancien empilement onglets+sous-vue+section unique :
//  fini l'onglet actif qui masque les 4 autres domaines, tout est visible
//  d'un coup d'œil, on ne pousse que celui qui nous intéresse. Point d'entrée
//  exposé pour le hub « Plus ».
//

import SwiftUI

struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.hasAnyData {
                    overview
                } else {
                    switch viewModel.state {
                    case .loading:
                        LoadingView(message: "Chargement des statistiques…")
                    case .failed(let message):
                        ErrorView(message: message) { viewModel.retry() }
                    case .loaded:
                        // Cas transitoire : données arrivées mais toutes vides,
                        // le contenu ci-dessous gère l'état "rien sur la période".
                        overview
                    }
                }
            }
            .background(Color.pulseBackground)
            .navigationDestination(for: DashboardTab.self) { tab in
                DashboardDomainDetailView(tab: tab, viewModel: viewModel)
            }
        }
        .task { await viewModel.loadIfNeeded() }
        // Synchro montre en mode Téléphone/Les deux pendant que l'écran est
        // ouvert (cf. `LocalIngestor.ingestIfNeeded`) : pas de notion de
        // « jour courant » ici (période glissante depuis aujourd'hui), donc
        // un rechargement inconditionnel comme `retry()`/`selectPeriod`.
        .reloadsOnLocalDataChange { await viewModel.load() }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                header

                if case .failed(let message) = viewModel.state {
                    DashboardInlineError(message: message) { viewModel.retry() }
                }

                // Une carte-domaine s'affiche même sans donnée sur la période
                // (tiret + pas de courbe, cf. `DashboardSummary.swift`) plutôt
                // que d'être masquée : les 4 domaines restent toujours visibles.
                NavigationLink(value: DashboardTab.sleep) {
                    DashboardSummaryCard(summary: viewModel.sleepSummary)
                }
                .buttonStyle(.plain)

                NavigationLink(value: DashboardTab.training) {
                    DashboardSummaryCard(summary: viewModel.trainingSummary)
                }
                .buttonStyle(.plain)

                NavigationLink(value: DashboardTab.health) {
                    DashboardSummaryCard(summary: viewModel.healthSummary)
                }
                .buttonStyle(.plain)

                NavigationLink(value: DashboardTab.nutrition) {
                    DashboardSummaryCard(summary: viewModel.nutritionSummary)
                }
                .buttonStyle(.plain)

                NavigationLink(value: DashboardTab.map) {
                    DashboardMapRow()
                }
                .buttonStyle(.plain)
            }
            .padding(PulseSpacing.lg)
        }
        .pulseTabBarClearance()
        .refreshable { await viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.md) {
            Text("Statistiques")
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(Color.pulseTextPrimary)

            // `.top .seg` côté Angular : le `Picker` système (`.segmented`) est
            // remplacé par une piste maison (`DashboardPeriodTrack`) qui
            // reprend l'habillage réel de la maquette (piste grise, pilule
            // active en relief blanc). Sur sa propre ligne, pleine largeur
            // (pilules à largeur égale) : à côté du titre 24pt il manquait de
            // place et « 1 an » repassait à la ligne, avec une moitié d'écran
            // vide.
            DashboardPeriodTrack(selection: Binding(
                get: { viewModel.period },
                set: { viewModel.selectPeriod($0) }
            ))
        }
    }
}

// MARK: - Composants partagés de l'écran

/// Ligne « Carte des sorties » — plus discrète que les 4 cartes de résumé
/// (pas de valeur clé ni de courbe, cf. maquette) : la carte GPS interactive
/// est un écran à part (`DashboardMapPlaceholderCard`), pas un domaine de
/// stats comme les autres.
private struct DashboardMapRow: View {
    var body: some View {
        HStack(spacing: PulseSpacing.md) {
            Image(systemName: "map.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.pulseTextSecondary)
                .frame(width: 26, height: 26)
                .background(Color.pulseTextSecondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("Carte des sorties")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.pulseTextPrimary)

            Spacer()

            // Pas de source de données pour un nombre de tracés GPS parmi les
            // endpoints déjà chargés (`DashboardTrainingTab.count` compte les
            // séances, pas les tracés) — note générique plutôt qu'un chiffre
            // inventé.
            Text("tracés GPS")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.pulseTextSecondary)
        }
        .padding(PulseSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pulseSurface)
        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                .strokeBorder(Color.pulseBorder, lineWidth: 1)
        )
    }
}

/// Sélecteur de sous-vue — `<app-seg class="views">` côté Angular. La
/// maquette la rend en pleine largeur, sans défilement (contrairement à une
/// rangée de capsules défilante) : pilules d'angle 9 pt de largeur égale.
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
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
    /// Survol d'un graphe associé : remplace la valeur des tuiles visées (par
    /// index dans les 3 premières, cf. `visibleTiles`) par la valeur du moment
    /// pointé — même principe que le survol des graphes de l'écran Santé, mais
    /// répercuté sur la figrow. Un dictionnaire (et non un seul index) pour les
    /// graphes multi-séries : « Apport vs dépense » met à jour deux tuiles d'un
    /// coup. Vide = figrow au repos, valeurs habituelles.
    var highlights: [Int: String] = [:]

    private var visibleTiles: [DashboardFigure] { Array(tiles.prefix(3)) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(visibleTiles.enumerated()), id: \.element.id) { index, tile in
                let overridden = highlights[index]
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.label.uppercased())
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Color.pulseTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(overridden ?? tile.value)
                            .font(.system(size: 19, weight: .semibold, design: .monospaced))
                            .foregroundStyle(overridden != nil ? Color.pulseTextPrimary : tile.accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .contentTransition(.numericText())
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
