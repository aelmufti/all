//
//  PulseShellView.swift
//  all (bridge-connect)
//
//  Coquille de navigation post-login. Reproduit **1-1** la barre de navigation
//  mobile du front Pulse (`custom-connect/web/src/app/app.component.ts`) : une
//  barre d'onglets plate en bas à **6 destinations**, dans le même ordre —
//  Accueil · Activités · Santé · Nutrition · Programme · Statistiques.
//
//  iOS `TabView` ne montre que 5 onglets avant de replier le 6ᵉ dans un « More »
//  système (le fouillis qu'on veut éviter). On construit donc une **barre
//  d'onglets maison** (`PulseTabBar`) posée en `safeAreaInset` sous le contenu,
//  stylée comme le web (fond `--surface`, bord haut `--border`, actif `--accent`).
//
//  Les fonctions **secondaires / propres à l'iPhone** (Paramètres, Statut,
//  Rapport SpO2, et la section collecteur « Montre » = BLE) ne sont PAS dans la
//  barre — comme sur le web où Paramètres est hors barre mobile. Elles vivent
//  derrière la **roue crantée** en haut de l'Accueil (`SystemMenuView`), en
//  feuille, chacune avec une sortie explicite (`SheetCloseButton`).
//
//  Chaque écran d'onglet possède déjà sa propre `NavigationStack` — on les
//  garde vivants (lazy : instanciés au premier passage puis conservés) pour ne
//  pas recharger les données à chaque bascule d'onglet.
//

import SwiftUI

/// Les 6 onglets primaires, dans l'ordre exact de la barre web.
enum PulseTab: String, CaseIterable, Identifiable {
    case accueil
    case activites
    case sante
    case nutrition
    case programme
    case statistiques

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accueil: return "Accueil"
        case .activites: return "Activités"
        case .sante: return "Santé"
        case .nutrition: return "Nutrition"
        case .programme: return "Programme"
        case .statistiques: return "Stats"
        }
    }

    /// SF Symbol au plus proche de l'icône Material du web
    /// (schedule · directions_run · favorite · restaurant · calendar_month · bar_chart).
    var icon: String {
        switch self {
        case .accueil: return "clock"
        case .activites: return "figure.run"
        case .sante: return "heart.fill"
        case .nutrition: return "fork.knife"
        case .programme: return "calendar"
        case .statistiques: return "chart.bar.fill"
        }
    }
}

struct PulseShellView: View {
    @State private var tab: PulseTab = .accueil
    /// Onglets déjà visités — instanciés une fois puis conservés (état + scroll
    /// préservés, pas de rechargement réseau à chaque bascule).
    @State private var visited: Set<PulseTab> = [.accueil]
    /// Incrémenté à chaque appui sur le FAB « + » (onglet Nutrition) — poussé à
    /// `NutritionView` qui ouvre alors sa feuille d'ajout.
    @State private var nutritionAddTrigger = 0

    var body: some View {
        ZStack {
            ForEach(PulseTab.allCases) { candidate in
                if visited.contains(candidate) {
                    screen(for: candidate)
                        .opacity(candidate == tab ? 1 : 0)
                        .allowsHitTesting(candidate == tab)
                        .zIndex(candidate == tab ? 1 : 0)
                }
            }
        }
        // FAB « + » de la Nutrition : posé AVANT le `safeAreaInset` de la barre
        // pour être inséré dans la zone AU-DESSUS d'elle (il flotte, comme le
        // `.fab` web en `position:fixed; z-index:90`). En overlay du
        // `ScrollView` de l'écran il passait derrière la barre — intouchable.
        .overlay(alignment: .bottomTrailing) {
            if tab == .nutrition {
                NutritionFab { nutritionAddTrigger &+= 1 }
                    .padding(.trailing, 18) // web `.fab { right:18px }`
                    .padding(.bottom, PulseSpacing.lg)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PulseTabBar(selection: $tab)
        }
        .onChange(of: tab) { _, newTab in
            visited.insert(newTab)
        }
    }

    @ViewBuilder
    private func screen(for tab: PulseTab) -> some View {
        switch tab {
        case .accueil: HomeView()
        case .activites: ActivitiesView()
        case .sante: HealthView()
        case .nutrition: NutritionView(addTrigger: nutritionAddTrigger)
        case .programme: ProgrammeView()
        case .statistiques: DashboardView()
        }
    }
}

/// Bouton flottant « + » qui ouvre l'ajout d'aliment — miroir de `.fab`
/// (web, `position:fixed; right:18px; bottom:calc(80px + var(--sab)); z-index:90`).
/// Vit dans la coquille (et non dans `NutritionView`) pour flotter au-dessus
/// de la barre d'onglets, cf. l'overlay ci-dessus.
private struct NutritionFab: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.pulseSurface)
                .frame(width: 56, height: 56)
                .background(Color.pulseTextPrimary)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
        }
        .accessibilityLabel("Ajouter un aliment")
    }
}

/// Barre d'onglets maison — reproduction de `.nav` (mobile) du front Pulse :
/// fond `--surface`, filet haut `--border`, item actif `--accent`, inactif
/// `--text-dim`, léger « scale » à l'appui.
struct PulseTabBar: View {
    @Binding var selection: PulseTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PulseTab.allCases) { tab in
                TabBarButton(
                    tab: tab,
                    isSelected: selection == tab,
                    action: { selection = tab }
                )
            }
        }
        .frame(height: 54)
        .padding(.top, 6)
        .background(
            Color.pulseSurface
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.pulseBorder)
                        .frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private struct TabBarButton: View {
        let tab: PulseTab
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(spacing: 3) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 21, weight: isSelected ? .semibold : .regular))
                    Text(tab.label)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(isSelected ? Color.pulseAccent : Color.pulseTextSecondary)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(TabBarButtonStyle())
        }
    }

    /// Enfonce l'icône (scale 0.88) à l'appui — écho de `.nav a:active .ms` du web.
    private struct TabBarButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

#Preview {
    PulseShellView()
}
