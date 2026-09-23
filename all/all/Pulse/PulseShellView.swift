//
//  PulseShellView.swift
//  all (bridge-connect)
//
//  Coquille de navigation post-login : Pulse devient la coquille de l'app
//  (cf. CLAUDE.md), les fonctions collecteur existantes (BLE diag + Temps
//  réel) passent en section secondaire « Montre ».
//
//  Point d'extension pour les agents d'écran suivants : chaque cas de
//  `PulseTab` a un commentaire `// TODO(écran …)` qui indique quoi brancher
//  et où. Remplacer le contenu du `case` correspondant dans le `switch` de
//  `PulseShellView.body` par le vrai écran — ne pas toucher aux autres cas,
//  ni à `PulseTab`, ni à `WatchSectionView` (section « Montre », déjà
//  branchée sur les vues collecteur existantes, ne pas la modifier).
//

import SwiftUI

/// Onglets de la coquille. `Hashable` pour servir de `selection` à `TabView`
/// (permet à un futur écran de forcer l'onglet actif, ex. après une action).
enum PulseTab: Hashable {
    case accueil
    case sante
    case activites
    case nutrition
    case plus
    /// Section secondaire — collecteur BLE existant, pas un écran Pulse.
    case montre
}

struct PulseShellView: View {
    @State private var selection: PulseTab = .accueil

    var body: some View {
        TabView(selection: $selection) {
            // Écran Accueil (page Angular `/`, entraînement + intensité du jour) —
            // `HomeView` est auto-suffisante (possède sa propre `NavigationStack`).
            HomeView()
                .tabItem { Label("Accueil", systemImage: "house.fill") }
                .tag(PulseTab.accueil)

            // Écran Santé (page `/health` — FC, stress, SpO2, sommeil,
            // intensité du jour, poids).
            HealthView()
                .tabItem { Label("Santé", systemImage: "heart.fill") }
                .tag(PulseTab.sante)

            // Écran Activités (liste `/activities` + détail `/activity/:id`) —
            // `ActivitiesView` possède sa propre `NavigationStack` et pousse
            // `ActivityDetailView`.
            ActivitiesView()
                .tabItem { Label("Activités", systemImage: "figure.run") }
                .tag(PulseTab.activites)

            // Écran Nutrition (page `/nutrition` — macros/objectif/journal du jour).
            NutritionView()
                .tabItem { Label("Nutrition", systemImage: "fork.knife") }
                .tag(PulseTab.nutrition)

            // TODO(écran Plus) : point d'entrée vers ce qui n'a pas (encore)
            // son propre onglet — `dashboard`, `programme`, `spo2-report`
            // (`/rapport-spo2`), `settings` (`/parametres`), `status`
            // (`/statut`). Probablement une `NavigationStack` + `List` de
            // liens, à construire par l'agent qui prend cet écran.
            ComingSoonView(title: "Plus", systemImage: "ellipsis.circle.fill")
                .tabItem { Label("Plus", systemImage: "ellipsis.circle.fill") }
                .tag(PulseTab.plus)

            // Section secondaire : collecteur BLE existant (ne pas modifier
            // `BLEDiagnosticView`/`RealtimeMetricsView`, définies dans
            // `all/BLE/`). Ne pas brancher de nouvel écran ici.
            WatchSectionView()
                .tabItem { Label("Montre", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(PulseTab.montre)
        }
        .tint(Color.pulseAccent)
    }
}

/// Section secondaire « Montre » : les deux vues collecteur existantes
/// (`BLEDiagnosticView`, `RealtimeMetricsView`) ont chacune déjà leur propre
/// `NavigationStack` interne — les re-wrapper dans une troisième (via
/// `NavigationLink` depuis un `NavigationStack` extérieur, ou un sous-`TabView`
/// qui empilerait une deuxième barre d'onglets) double les barres de
/// navigation. Un sélecteur segmenté au-dessus évite le problème sans toucher
/// aux deux vues.
private struct WatchSectionView: View {
    private enum Screen: String, CaseIterable, Identifiable {
        case diagnostic = "Diagnostic"
        case realtime = "Temps réel"
        var id: String { rawValue }
    }

    @State private var screen: Screen = .diagnostic

    var body: some View {
        VStack(spacing: 0) {
            Picker("Vue", selection: $screen) {
                ForEach(Screen.allCases) { screen in
                    Text(screen.rawValue).tag(screen)
                }
            }
            .pickerStyle(.segmented)
            .padding(PulseSpacing.md)

            Group {
                switch screen {
                case .diagnostic:
                    BLEDiagnosticView()
                case .realtime:
                    RealtimeMetricsView()
                }
            }
        }
        .background(Color.pulseBackground)
    }
}

/// Placeholder générique « à venir » — remplacé onglet par onglet à mesure
/// que les écrans réels sont branchés (voir TODO dans `PulseShellView.body`).
private struct ComingSoonView: View {
    let title: String
    let systemImage: String

    var body: some View {
        NavigationStack {
            VStack(spacing: PulseSpacing.lg) {
                PulseCard {
                    VStack(spacing: PulseSpacing.md) {
                        Image(systemName: systemImage)
                            .font(.system(size: 40))
                            .foregroundStyle(Color.pulseAccent)
                        Text("\(title) — à venir")
                            .font(PulseFont.sectionTitle)
                            .foregroundStyle(Color.pulseTextPrimary)
                        Text("Cet écran sera branché sur l'API Pulse dans un prochain incrément.")
                            .font(.footnote)
                            .foregroundStyle(Color.pulseTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(PulseSpacing.lg)
                Spacer()
            }
            .background(Color.pulseBackground)
            .navigationTitle(title)
        }
    }
}

#Preview {
    PulseShellView()
}
