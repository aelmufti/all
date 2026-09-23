# Session notes — Pulse natif iOS

## 2026-09-23 — Refonte UI 1-1 sur la maquette web + navigation

### Décisions actées
- **Navigation = barre 6 onglets custom** reproduisant 1-1 la nav mobile du
  front web (`custom-connect/web/src/app/app.component.ts`) : *Accueil ·
  Activités · Santé · Nutrition · Programme · Stats* (même ordre). iOS `TabView`
  plafonne à 5 onglets → barre maison (`PulseTabBar` dans `PulseShellView.swift`),
  onglets gardés vivants (lazy + `visited`), posée en `.safeAreaInset(.bottom)`.
- **Fin de l'onglet « Plus » fourre-tout.** Les fonctions secondaires/iPhone
  (Paramètres, Statut, Rapport SpO2, **Montre** = collecteur BLE) passent derrière
  la **roue crantée** en haut de l'Accueil → `SystemMenuView` (feuille). Chaque
  écran secondaire présenté en feuille a un bouton **« Terminé »** (`SheetCloseButton`
  dans `DesignSystem.swift` + `@Environment(\.dismiss)`) — plus aucun piège.
- **Le piège des Statistiques est réglé** : Dashboard n'est plus une feuille sans
  issue mais un vrai onglet.
- **Palette par métrique** ajoutée à `DesignSystem.swift` (traduction 1-1 du SCSS
  `--m-*`, `--p-*`, `--s-*`, `--heat-*`, `--danger-*`, `--empty/--absent/--sk-*`) :
  `pulseHR/Steps/Calories/Spo2/Sleep/Stress/Battery/Resp`, phases sommeil, zones
  stress, heatmap. **Règle : jamais une métrique en `pulseAccent` bleu générique.**

### Refonte écran par écran (agents Sonnet, build vérifié)
Tous les écrans repeints par métrique + collés au web : Accueil (sparkline FC,
« Depuis le réveil », « Nuit dernière », coucher moyen), Santé (toutes métriques),
Statistiques (`DashboardMetricColor` repointé sur la palette), Nutrition
(**+ ajout d'aliment** : FAB, recherche locale, Open Food Facts, fréquents, saisie
manuelle → `NutritionAddFoodSheet.swift`), Activités+détail, Programme (sommeil
`pulseSleep`, statut « sous cible » `pulseStress`), Paramètres/Statut/SpO2.
**Build d'intégration complet : `** BUILD SUCCEEDED **`** (jamais exécuté contre
le vrai serveur — validation par compilation seule, cf. règles immuables).

### Reste à faire (proposé, non fait)
- **Navigation inter-onglets** : les liens web « Voir le programme » (Accueil) ne
  sont pas cliquables — l'ossature n'expose pas d'API pour basculer d'onglet
  programmatiquement. Ajouter un routeur partagé (Environment/binding sur la
  sélection de `PulseShellView`) si on veut ces raccourcis.
- **Nutrition** : scan de code-barres (caméra, `nutrition/barcode/:code`) et
  **édition d'une entrée déjà journalisée** (`PUT nutrition/log/:id`) non repris.
- Vérif visuelle sur device/simulateur par l'utilisateur (non fait ici : lancer
  l'app touche réseau + données perso → autorisation requise d'abord).
- Rien n'est commité (tout en working tree, y compris des modifs pré-session sur
  `PulseAPIClient.swift` = diagnostics de décodage, `HealthModels/ViewModel`,
  `DashboardModels`).
