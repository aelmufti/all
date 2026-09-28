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
//  Mode Téléphone (incrément L0, `docs/stockage-local.md`) : la porte de
//  login est **court-circuitée** — un utilisateur sans Pulse doit pouvoir
//  entrer sans jamais s'authentifier contre un serveur. `storageMode` est
//  observé en plus de `auth` : dès que le mode passe à `.phone` (Réglages, ou
//  le lien « Utiliser sans serveur » de `LoginView`), la coquille s'affiche
//  immédiatement, qu'`AuthStore` ait une session ou non.
//

import SwiftUI

struct ContentView: View {
    private let auth = AuthStore.shared
    /// Observé pour re-rendre au changement de thème (cycle déclenché depuis
    /// l'en-tête Accueil, cf. `HomeView.swift`) — `ThemeStore` est un
    /// singleton partagé, pas un état propre à cette vue.
    @State private var theme = ThemeStore.shared
    /// Observé pour re-rendre au changement de mode de stockage — cf.
    /// en-tête de fichier.
    @State private var storageMode = StorageModeStore.shared

    var body: some View {
        Group {
            if storageMode.mode == .phone || auth.username != nil {
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
            // Mode Téléphone : pas de session à vérifier, la coquille
            // s'affiche déjà (condition ci-dessus) — inutile d'appeler
            // `api/auth/me` (qui échouerait de toute façon sans `baseURL`).
            guard storageMode.mode != .phone else {
                auth.isChecking = false
                return
            }
            _ = await auth.check()
        }
    }
}

#Preview {
    ContentView()
}
