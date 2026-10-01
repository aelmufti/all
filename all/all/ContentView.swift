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
//  Onboarding (premier lancement, `Pulse/Onboarding/OnboardingView.swift`) :
//  porte gate EN PREMIER, avant même storageMode/auth — tant que
//  `OnboardingStore.shared.completed == false`, `OnboardingView` s'affiche à
//  la place de tout le reste (y compris la porte de login). C'est
//  `OnboardingView` qui pose `storageMode`/l'auth Pulse en cours de route ; le
//  `.task` ci-dessous reste actif pendant l'onboarding (harmless — cf. son
//  commentaire), il n'a juste aucun effet visible tant que l'onboarding gate.
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
    /// Observé pour re-rendre dès `OnboardingView.markCompleted()` — cf.
    /// en-tête de fichier.
    @State private var onboarding = OnboardingStore.shared

    var body: some View {
        Group {
            if !onboarding.completed {
                OnboardingView()
            } else if storageMode.mode == .phone || auth.username != nil {
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
        // Typo globale « premium doux » (choix produit 2026-10-01) : toute
        // l'app en SF Rounded plutôt que le monospace « labo » d'origine. Posé
        // une seule fois ici, à la racine, et hérité par toute la hiérarchie —
        // y compris les feuilles (`.sheet`) et les destinations de navigation,
        // qui héritent de l'environnement du présentateur. Les écrans qui
        // fixaient `design: .rounded` en dur ont été repassés en `.rounded`
        // pour ne pas court-circuiter cette cascade (un `design:` explicite
        // prime sur `.fontDesign`).
        .fontDesign(.rounded)
        // `.monospacedDigit()` global : chiffres à largeur fixe partout, donc
        // les colonnes de valeurs (grilles de métriques, tableaux) restent
        // alignées et ne « sautent » pas quand un chiffre change — l'alignement
        // qu'assurait le monospace, conservé sans le reste de son allure.
        .monospacedDigit()
        // `nil` (auto) laisse le système décider ; `.light`/`.dark` force le
        // thème — propage à l'`UITraitCollection` de la fenêtre, donc les
        // `Color(light:dark:)` dynamiques de `DesignSystem.swift` se
        // résolvent correctement, cf. commentaire d'en-tête de `ThemeStore`.
        .preferredColorScheme(theme.colorScheme)
        .task {
            // Repeuple la base locale « Pulse embarqué » au lancement, si le
            // mode Stockage en a l'usage (phone/both) — incrément L2, cf.
            // `docs/stockage-local.md`. `ingestIfNeeded` vérifie elle-même le
            // mode et ne fait rien en `pulse`. Fire-and-forget (hors main
            // actor dans son implémentation, cf. `LocalIngestor.swift`) : ne
            // bloque jamais l'affichage de la coquille.
            LocalIngestor.ingestIfNeeded()

            // Rattrapage Pulse (`Sync/PulseBacklogPusher.swift`) : pousse tout
            // fichier resté dans le Spool sans jamais avoir atteint Pulse
            // (typiquement collecté en mode Téléphone lors d'une session
            // antérieure, puis le mode a basculé — éventuellement hors ligne,
            // donc rattrapé ici au lancement plutôt qu'au seul changement de
            // mode). Se garde elle-même (mode, config Pulse) ; fire-and-forget.
            PulseBacklogPusher.pushIfNeeded()

            // Mode Téléphone : pas de session à vérifier, la coquille
            // s'affiche déjà (condition ci-dessus) — inutile d'appeler
            // `api/auth/me` (qui échouerait de toute façon sans `baseURL`).
            guard storageMode.mode != .phone else {
                auth.isChecking = false
                await WakeScheduleStore.shared.load()
                return
            }
            _ = await auth.check()
            await WakeScheduleStore.shared.load()
        }
        // Basculement du mode Stockage vers Pulse/Les deux : rattrape tout de
        // suite le retard éventuel (fichiers collectés en Téléphone, jamais
        // poussés) plutôt que d'attendre le prochain lancement de l'app.
        // `pushIfNeeded()` se re-garde lui-même (no-op en `.phone`, cf.
        // `PulseBacklogPusher.swift`) — appelé inconditionnellement ici pour
        // rester simple, pas de logique de mode dupliquée dans cette vue.
        .onChange(of: storageMode.mode) { _, _ in
            PulseBacklogPusher.pushIfNeeded()
            // Passage en Téléphone/Les deux : remonter tout de suite le spool
            // en base locale (self-guard : no-op en `.pulse`), pour que les
            // écrans qui viennent de basculer sur la source locale
            // (`.reloadsOnStorageModeChange`) y trouvent des données fraîches.
            // Si une insertion a lieu, `LocalIngestor` reposte lui-même
            // `.allLocalDataDidChange` → second rechargement, sans redémarrage.
            LocalIngestor.ingestIfNeeded()
            // Changement de mode Stockage : le planning de réveil vient d'une
            // source différente (serveur vs backend local) — re-fetch (cf.
            // `WakeScheduleStore.load()`).
            Task { await WakeScheduleStore.shared.load() }
        }
        // Connexion réussie (depuis `LoginView` ou `PulseModeLoginSheet`) : le
        // cookie de session vient d'être posé, le planning serveur est
        // désormais accessible — re-fetch. Ne se déclenche PAS au logout
        // (`newValue == nil`) : on garde le cache tel quel.
        .onChange(of: auth.username) { _, newValue in
            if newValue != nil {
                Task { await WakeScheduleStore.shared.load() }
            }
        }
    }
}

#Preview {
    ContentView()
}
