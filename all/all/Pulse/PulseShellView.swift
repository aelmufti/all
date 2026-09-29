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

/// Les 6 onglets primaires. Écart assumé vs la barre web : l'onglet
/// « Programme » cède sa place à un onglet **Sommeil** dédié (l'écran Programme
/// est relégué dans Paramètres — c'est une fonction de configuration, pas un
/// suivi quotidien). Les cinq autres suivent l'ordre web.
enum PulseTab: String, CaseIterable, Identifiable {
    case accueil
    case activites
    case sante
    case nutrition
    case sommeil
    case statistiques

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accueil: return "Accueil"
        case .activites: return "Activités"
        case .sante: return "Santé"
        case .nutrition: return "Nutrition"
        case .sommeil: return "Sommeil"
        case .statistiques: return "Stats"
        }
    }

    /// SF Symbol au plus proche de l'icône Material du web
    /// (schedule · directions_run · favorite · restaurant · … · bar_chart) ;
    /// le Sommeil, propre à l'app, prend `bed.double.fill`.
    var icon: String {
        switch self {
        case .accueil: return "clock"
        case .activites: return "figure.run"
        case .sante: return "heart.fill"
        case .nutrition: return "fork.knife"
        case .sommeil: return "bed.double.fill"
        case .statistiques: return "chart.bar.fill"
        }
    }

    /// Onglets « hors montre » (incrément L0, `docs/stockage-local.md`) :
    /// masqués en mode Téléphone, portés dans des incréments ultérieurs
    /// (le backend local n'a rien à leur servir, cf. `PulseAPIClient`). Seule
    /// la Nutrition est un onglet primaire à ce jour — Programme/Poids sont
    /// respectivement dans Réglages et sur l'écran Santé (cf. `HealthView`).
    func isAvailable(in mode: StorageMode) -> Bool {
        guard self == .nutrition else { return true }
        return mode != .phone
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
    /// Observé pour masquer les onglets hors montre en mode Téléphone (cf.
    /// `PulseTab.isAvailable(in:)`) et pour re-rendre dès qu'il change.
    @State private var storageMode = StorageModeStore.shared

    /// Onglets réellement affichés dans la barre pour le mode courant — cf.
    /// `PulseTab.isAvailable(in:)`.
    private var visibleTabs: [PulseTab] {
        PulseTab.allCases.filter { $0.isAvailable(in: storageMode.mode) }
    }

    var body: some View {
        ZStack {
            ForEach(visibleTabs) { candidate in
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
            PulseTabBar(selection: $tab, tabs: visibleTabs)
        }
        // Indicateur global « synchronisation en cours » (cf. son commentaire
        // d'en-tête) : overlay commun à tous les onglets, au-dessus du contenu
        // ET de la barre d'onglets, purement informatif (ne capte aucun tap —
        // `SyncStatusBanner` se rend elle-même `allowsHitTesting(false)`).
        .overlay(alignment: .top) {
            SyncStatusBanner()
        }
        .onChange(of: tab) { _, newTab in
            visited.insert(newTab)
        }
        // Bascule de mode alors qu'un onglet désormais masqué est sélectionné
        // (ex. Nutrition puis passage en Téléphone depuis Réglages) : replie
        // sur Accueil, toujours disponible quel que soit le mode.
        .onChange(of: storageMode.mode) { _, _ in
            if !visibleTabs.contains(tab) { tab = .accueil }
        }
    }

    @ViewBuilder
    private func screen(for tab: PulseTab) -> some View {
        switch tab {
        case .accueil: HomeView()
        case .activites: ActivitiesView()
        case .sante: HealthView()
        case .nutrition: NutritionView(addTrigger: nutritionAddTrigger)
        case .sommeil: SommeilView()
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
    /// Onglets à afficher — `PulseTab.allCases` par défaut (comportement
    /// historique, cf. `#Preview` de ce fichier) ; `PulseShellView` passe
    /// `visibleTabs` (masque Nutrition en mode Téléphone, cf.
    /// `PulseTab.isAvailable(in:)`).
    var tabs: [PulseTab] = PulseTab.allCases

    /// Hauteur du bandeau de boutons (hors safe-area du bas, que le fond couvre
    /// via `ignoresSafeArea`). Exposée pour que chaque `ScrollView` d'écran
    /// puisse réserver cette hauteur — cf. `pulseTabBarClearance()`.
    static let barHeight: CGFloat = 54
    static let topPadding: CGFloat = 6
    static var contentHeight: CGFloat { barHeight + topPadding }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                TabBarButton(
                    tab: tab,
                    isSelected: selection == tab,
                    action: { selection = tab }
                )
            }
        }
        .frame(height: Self.barHeight)
        .padding(.top, Self.topPadding)
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

// MARK: - Dégagement de la barre d'onglets
//
// La barre d'onglets vit en `safeAreaInset(.bottom)` sur le ZStack de la
// coquille, **hors** des `NavigationStack` de chaque écran. Or un
// `NavigationStack` **ne relaie pas** à son `ScrollView` l'inset de safe-area
// ajouté par un ancêtre situé au-dessus de lui : le contenu défilé passe donc
// sous la barre en fin de course (vérifié au simulateur). On réserve la
// hauteur de la barre **à l'intérieur** de la pile, directement sur le
// `ScrollView`, où l'inset est bien pris en compte.
extension View {
    /// À poser sur le `ScrollView` racine d'un écran (dans son `NavigationStack`)
    /// pour que sa dernière ligne dégage la barre d'onglets de la coquille.
    func pulseTabBarClearance() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: PulseTabBar.contentHeight)
        }
    }
}

#Preview {
    PulseShellView()
}
