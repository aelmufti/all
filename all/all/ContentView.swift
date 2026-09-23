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
        .task {
            _ = await auth.check()
        }
    }
}

#Preview {
    ContentView()
}
