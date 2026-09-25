//
//  ContentView.swift
//  all (bridge-connect)
//
//  Racine de l'app. Pulse devient la coquille (cf. CLAUDE.md) : ce fichier
//  ne fait plus que la porte de login (`AuthStore.username == nil` →
//  `LoginView`, sinon `PulseShellView`) — l'ancien flux WebView (saisie
//  d'adresse + `PulseWebView`) est retiré de la coquille. `PulseWebView.swift`
//  reste dans le dépôt (n'est plus référencé ici) au cas où un futur écran
//  en ait encore besoin (ex. une page sans équivalent natif).
//
//  Les écrans de données (Accueil/Santé/Activités/Nutrition/Plus) et la
//  section « Montre » sont dans `Pulse/PulseShellView.swift` — voir les
//  `// TODO(écran …)` là-bas pour le point de branchement de chaque agent
//  suivant.
//

import SwiftUI

struct ContentView: View {
    private let auth = AuthStore.shared
    /// Observé pour re-rendre au changement de thème (cycle déclenché depuis
    /// l'en-tête Accueil, cf. `HomeView.swift`) — `ThemeStore` est un
    /// singleton partagé, pas un état propre à cette vue.
    @State private var theme = ThemeStore.shared

    var body: some View {
        Group {
            if auth.username != nil {
                PulseShellView()
            } else if auth.isChecking {
                // Vérification de la session persistée (cookie déjà posé
                // d'un lancement précédent) avant de flasher la porte de
                // login à tort.
                LoadingView(message: "Connexion à Pulse…")
            } else {
                LoginView()
            }
        }
        // `nil` (auto) laisse le système décider ; `.light`/`.dark` force le
        // thème — propage à l'`UITraitCollection` de la fenêtre, donc les
        // `Color(light:dark:)` dynamiques de `DesignSystem.swift` se
        // résolvent correctement, cf. commentaire d'en-tête de `ThemeStore`.
        .preferredColorScheme(theme.colorScheme)
        .task {
            _ = await auth.check()
        }
    }
}

#Preview {
    ContentView()
}
