//
//  SettingsView.swift
//  all (bridge-connect)
//
//  Écran Paramètres natif — équivalent SwiftUI (partiel) de la page Angular
//  `/parametres` (`custom-connect/web/src/app/pages/settings/
//  settings.component.ts`). Organisé autour du **mode de connectivité** : le
//  sélecteur de source est la colonne vertébrale et n'affiche que les contrôles
//  du mode retenu (bridge → adresse + « Statut du pont » ; iPhone BLE → token +
//  « Collecteur (Montre) » ; legacy → rien). Les sections neutres encadrent ce
//  bloc : Apparence (thème), État de la synchro (fraîcheur + inventaire, calculés
//  côté serveur, indépendants de la source), Profil (année de naissance / sexe /
//  taille — le poids reste en lecture seule, saisi sur la page Santé) et
//  Application (adresse de Pulse, compte, déconnexion). Les autres feuilles
//  Angular (Objectifs, Objectif calorique, Minutes d'intensité, Export,
//  Réanalyser) sont hors périmètre de cet écran.
//
//  `Form`/`Section` de style Réglages iOS plutôt que les cartes `PulseCard`
//  des autres écrans — un choix explicite pour cette page (le natif iOS a
//  déjà tout le vocabulaire visuel d'un écran de réglages).
//
//  Toutes les déclarations de ce fichier sont préfixées `Settings*` pour ne
//  rien exposer qui puisse entrer en collision avec les autres écrans
//  (`Screens/Home`, `Screens/Health`…) compilés dans la même cible.
//
//  Stockage (incrément L0, `docs/stockage-local.md`) : `SettingsStorageSection`
//  est la vraie colonne vertébrale de l'écran depuis cet incrément — en mode
//  Téléphone, tout ce qui dépend VRAIMENT d'un serveur (source de synchro
//  Pulse, statut, compte/déconnexion) n'a plus de sens et disparaît ;
//  Stockage, Apparence, l'accès à la Montre (diagnostic BLE local) et, depuis
//  L6, Profil (servi par `RealLocalPulseBackend`, `GET`/`PUT api/profile`)
//  restent joignables — cf. `SettingsWatchOnlySection`, `SettingsProfileSection`
//  et `SettingsViewModel.load()` (court-circuite UNIQUEMENT le chargement
//  source/statut/inventaire dans ce mode, jamais le profil, pour ne jamais
//  coincer l'utilisateur derrière un `ErrorView`). Programme a rejoint cette
//  liste depuis L7a (`GET api/programme` servi en lecture, cf.
//  `RealLocalPulseBackend`) : les actions d'écriture de l'écran (activer/
//  arrêter/cocher/envoyer) restent différées et lèvent une erreur si on les
//  déclenche en mode Téléphone.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    private let auth = AuthStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showStatus = false
    @State private var showWatch = false
    @State private var showProgramme = false
    @State private var storageMode = StorageModeStore.shared
    /// Mode serveur (Pulse / Les deux) demandé depuis le picker de stockage
    /// alors qu'aucune session n'est active — présente `PulseModeLoginSheet`.
    /// Tenu ICI (racine stable de l'écran) et non dans `SettingsStorageSection`
    /// : ancré sur une `Section`, le `.sheet` se refermait tout seul dès que le
    /// `Form` se re-diffait (le `@State` de la section était réinitialisé).
    @State private var pendingServerMode: StorageMode?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Paramètres")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { SheetCloseButton { dismiss() } }
        }
        .task {
            await viewModel.load()
        }
        // Basculer le mode de stockage change radicalement ce que cet écran a
        // de sens à charger (cf. `SettingsViewModel.load()`) — recharge à
        // chaque changement, pas seulement à l'ouverture de la feuille.
        .onChange(of: storageMode.mode) { _, _ in
            Task { await viewModel.load() }
        }
        .sheet(isPresented: $showStatus) { StatusView() }
        .sheet(isPresented: $showWatch) { WatchSectionView() }
        .sheet(isPresented: $showProgramme) { ProgrammeView() }
        // Ancré à la racine stable (pas sur une Section du Form) — cf. le
        // commentaire de `pendingServerMode`.
        .sheet(item: $pendingServerMode) { mode in
            PulseModeLoginSheet(targetMode: mode)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingView(message: "Chargement des paramètres…")
        case .failed(let message):
            ErrorView(message: message) {
                Task { await viewModel.retry() }
            }
        case .loaded:
            Form {
                SettingsStorageSection(onRequestServerLogin: { pendingServerMode = $0 })
                SettingsAppearanceSection()
                if storageMode.mode == .phone {
                    // Démasqué depuis l'incrément L7a (`docs/stockage-local.md`) :
                    // `GET api/programme` est désormais servi par
                    // `RealLocalPulseBackend` (lecture seule) — ouvrir
                    // `ProgrammeView` en mode Téléphone charge donc les trois
                    // domaines pour de vrai. Les actions d'écriture
                    // (activer/arrêter/cocher/envoyer) restent différées :
                    // elles lèvent `LocalPulseUnavailableError`, affichée
                    // comme n'importe quelle erreur par l'écran.
                    SettingsProgrammeSection(onOpen: { showProgramme = true })
                    SettingsWatchOnlySection(onWatch: { showWatch = true })
                    SettingsProfileSection(viewModel: viewModel)
                } else {
                    SettingsProgrammeSection(onOpen: { showProgramme = true })
                    SettingsSyncSourceSection(
                        viewModel: viewModel,
                        onStatus: { showStatus = true },
                        onWatch: { showWatch = true }
                    )
                    SettingsStatusSection(viewModel: viewModel)
                    SettingsProfileSection(viewModel: viewModel)
                    SettingsApplicationSection(viewModel: viewModel, username: auth.username)
                }
            }
        }
    }
}

// MARK: - Stockage (où vivent les données — cf. `StorageModeStore`)
//
// Distinct de « Mode de connectivité » ci-dessous (`SettingsSyncSourceSection`,
// qui dit QUI COLLECTE sur la montre, réglage serveur `api/sync/source`) : ce
// réglage-ci dit OÙ VIVENT LES DONNÉES de l'app, purement local
// (`StorageModeStore`, aucun appel réseau pour le lire/l'écrire).

private struct SettingsStorageSection: View {
    @State private var store = StorageModeStore.shared
    /// Appelée quand l'utilisateur choisit un mode serveur (Pulse / Les deux)
    /// sans session active : on n'applique PAS le mode tout de suite — le
    /// parent (`SettingsView`) présente la connexion dans une feuille
    /// **annulable** (`PulseModeLoginSheet`), ancrée à sa racine stable. Le
    /// mode ne bascule qu'en cas de connexion réussie ; « Annuler » laisse le
    /// mode inchangé (Téléphone). Sans ça, basculer le picker sur Pulse virait
    /// `ContentView` sur un `LoginView` plein écran sans retour clair.
    let onRequestServerLogin: (StorageMode) -> Void

    var body: some View {
        Section {
            Picker("Stockage", selection: modeBinding) {
                ForEach(StorageMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Stockage")
        } footer: {
            Text(Self.footnote(for: store.mode))
        }
    }

    private var modeBinding: Binding<StorageMode> {
        Binding(
            get: { store.mode },
            set: { newMode in
                // Basculer vers un mode qui exige le serveur (Pulse / Les deux)
                // sans session active : passer par la feuille de connexion
                // (gérée par le parent) plutôt que d'appliquer le mode (ce qui
                // basculerait `ContentView` sur `LoginView` plein écran, sans
                // sortie claire). Vers Téléphone, ou si déjà connecté :
                // appliquer directement.
                if (newMode == .pulse || newMode == .both),
                   AuthStore.shared.username == nil {
                    onRequestServerLogin(newMode)
                } else {
                    store.mode = newMode
                }
            }
        )
    }

    private static func footnote(for mode: StorageMode) -> String {
        switch mode {
        case .pulse:
            return "Pulse : chaque synchro est envoyée au serveur — comportement historique."
        case .phone:
            return "Téléphone : rien n'est envoyé à Pulse, tout reste sur l'iPhone. La montre est archivée dès l'enregistrement local (pas d'attente d'un accusé serveur)."
        case .both:
            return "Les deux : envoyé à Pulse ET gardé sur l'iPhone. L'app lit Pulse et se replie automatiquement sur le téléphone si Pulse est injoignable."
        }
    }
}

// MARK: - Connexion Pulse depuis le picker de stockage
//
// Présentée par `SettingsStorageSection` quand l'utilisateur choisit
// « Pulse »/« Les deux » alors qu'aucune session n'est active (typiquement
// depuis Téléphone, sans compte). Réutilise `PulseCredentialsForm` /
// `PulseLoginErrorMapper` (extraits de `LoginView`) : MÊME saisie, MÊME mapping
// d'erreur. Le mode de stockage n'est appliqué qu'APRÈS une connexion réussie ;
// « Annuler » ferme sans rien changer (on reste sur Téléphone). Pas d'écran
// plein sans sortie.
private struct PulseModeLoginSheet: View {
    let targetMode: StorageMode

    @Environment(\.dismiss) private var dismiss
    @State private var serverURLString = PulseConfig.baseURL?.absoluteString ?? ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let auth = AuthStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: PulseSpacing.lg) {
                    PulseCredentialsForm(
                        serverURLString: $serverURLString,
                        username: $username,
                        password: $password,
                        isSubmitDisabled: !canSubmit || isSubmitting,
                        isSubmitting: isSubmitting,
                        errorMessage: errorMessage,
                        submitLabel: "Se connecter",
                        onSubmit: submit,
                        onServerURLChange: persistServerURL
                    )
                }
                .padding(PulseSpacing.lg)
            }
            .background(Color.pulseBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Connexion à Pulse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }

    private var canSubmit: Bool {
        PulseConfig.baseURL != nil && !username.isEmpty && !password.isEmpty
    }

    private func persistServerURL() {
        PulseConfig.setBaseURL(fromUserInput: serverURLString)
    }

    private func submit() {
        persistServerURL()
        guard canSubmit else { return }
        errorMessage = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await auth.login(username: username, password: password)
                // Connexion OK : seulement MAINTENANT on applique le mode voulu.
                StorageModeStore.shared.mode = targetMode
                dismiss()
            } catch {
                errorMessage = PulseLoginErrorMapper.message(for: error)
            }
        }
    }
}

// MARK: - Montre (accès direct en mode Téléphone)
//
// En mode Téléphone, `SettingsSyncSourceSection` (bloc « Mode de connectivité »,
// entièrement server-only : source de synchro, statut, token) n'a plus de
// sens — mais l'accès à « Collecteur (Montre) » (diagnostic BLE, temps réel),
// lui, ne dépend d'aucun serveur : on le garde seul, sans tout le reste du bloc.

private struct SettingsWatchOnlySection: View {
    let onWatch: () -> Void

    var body: some View {
        Section {
            Button(action: onWatch) {
                SettingsNavRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Collecteur (Montre)",
                    subtitle: "Diagnostic BLE, temps réel"
                )
            }
        } header: {
            Text("Montre")
        }
    }
}

// MARK: - Apparence (thème)
//
// Miroir de la feuille « Thème » Angular (`settings.component.ts`,
// `ThemeService` `auto|light|dark`). Le réglage est partagé avec le bouton
// cycle de l'en-tête Accueil via `ThemeStore.shared` (persisté `pulse-theme`,
// appliqué au root par `.preferredColorScheme`).

private struct SettingsAppearanceSection: View {
    @State private var theme = ThemeStore.shared

    var body: some View {
        Section {
            Picker("Thème", selection: themeBinding) {
                Text("Automatique").tag(ThemeStore.Theme.auto)
                Text("Clair").tag(ThemeStore.Theme.light)
                Text("Sombre").tag(ThemeStore.Theme.dark)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Apparence")
        } footer: {
            Text("« Automatique » suit le réglage clair/sombre de l'iPhone.")
        }
    }

    private var themeBinding: Binding<ThemeStore.Theme> {
        Binding(get: { theme.theme }, set: { theme.theme = $0 })
    }
}

// MARK: - Programme
//
// Programme (entraînement / alimentation / sommeil) était un onglet primaire ;
// c'est une fonction de configuration (choix et suivi de plans), déplacée ici
// pour laisser sa place dans la barre à l'onglet Sommeil. Ouvre `ProgrammeView`
// en feuille, comme « Statut du pont » et « Collecteur (Montre) ».

private struct SettingsProgrammeSection: View {
    let onOpen: () -> Void

    var body: some View {
        Section {
            Button(action: onOpen) {
                SettingsNavRow(
                    icon: "calendar",
                    title: "Programme",
                    subtitle: "Plans entraînement, alimentation, sommeil"
                )
            }
        } header: {
            Text("Programme")
        }
    }
}

// MARK: - Mode de connectivité (source + contrôles propres au mode)
//
// Colonne vertébrale de l'écran : le sélecteur de source choisit *qui* collecte,
// et seuls les contrôles du mode retenu s'affichent en dessous. Chaque mode a sa
// propre histoire matérielle, donc son propre secondaire :
//   • bridge  → le pont du homelab parle en Bluetooth → accès « Statut du pont »
//               (lien BLE bridge↔montre, synchro auto ; `StatusView`).
//   • phone   → cette app est le collecteur → token d'ingestion + « Collecteur
//               (Montre) » (Diagnostic / Temps réel ; `WatchSectionView`).
//   • legacy  → adb depuis l'hôte, rien à régler ici.
// La fraîcheur/l'inventaire (indépendants de la source) restent en section neutre
// « État de la synchro » (`SettingsStatusSection`).

private struct SettingsSyncSourceSection: View {
    var viewModel: SettingsViewModel
    let onStatus: () -> Void
    let onWatch: () -> Void

    var body: some View {
        Section {
            Picker("Source", selection: sourceBinding) {
                ForEach(SettingsSyncSourceKind.allCases) { kind in
                    Text(kind.label).tag(kind.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isChangingSource)

            if let source = viewModel.source {
                Text(Self.subLabel(for: source))
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)

                if source.source == "bridge" {
                    LabeledContent("Adresse", value: source.url)
                    HStack(spacing: PulseSpacing.xs) {
                        Circle()
                            .fill(source.reachable == true ? Color.pulseSuccess : Color.pulseDanger)
                            .frame(width: 8, height: 8)
                        Text(source.reachable == true ? "garmin-bridge répond" : "garmin-bridge ne répond pas")
                            .font(.footnote)
                    }
                    if source.reachable != true, let detail = source.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    Button(action: onStatus) {
                        SettingsNavRow(
                            icon: "dot.radiowaves.up.forward",
                            title: "Statut du pont",
                            subtitle: "Lien BLE bridge↔montre, synchro automatique"
                        )
                    }
                }

                if source.source == "phone" {
                    SettingsIngestTokenRow(viewModel: viewModel, token: source.ingestToken)
                    Button(action: onWatch) {
                        SettingsNavRow(
                            icon: "antenna.radiowaves.left.and.right",
                            title: "Collecteur (Montre)",
                            subtitle: "Diagnostic BLE, temps réel"
                        )
                    }
                }

                if source.overridden {
                    Text("Réglé sur « \(source.configured == "bridge" ? "bridge" : "legacy") » dans l'environnement du conteneur, remplacé ici. Ce choix survit aux redémarrages.")
                        .font(.caption)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }

            if let sourceError = viewModel.sourceError {
                Text(sourceError)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseDanger)
            }
        } header: {
            Text("Mode de connectivité")
        } footer: {
            Text("« Téléphone » est la chaîne historique (adb depuis l'hôte). « garmin-bridge » parle en Bluetooth depuis le serveur. « iPhone (BLE) » : cette app pousse les .fit en HTTP. Basculer ne fait rien perdre — la déduplication par empreinte évite les doublons.")
        }
    }

    /// Sélection à deux voies : le `Picker` change la source côté vue-modèle
    /// dès que l'utilisateur touche un segment, `PUT api/sync/source` part
    /// depuis `SettingsViewModel.setSource`.
    private var sourceBinding: Binding<String> {
        Binding(
            get: { viewModel.source?.source ?? SettingsSyncSourceKind.legacy.rawValue },
            set: { next in Task { await viewModel.setSource(next) } }
        )
    }

    private static func subLabel(for source: SettingsSyncSource) -> String {
        switch source.source {
        case "phone": return "l'iPhone pousse les .fit en HTTP (bridge-connect)"
        case "bridge": return "bluetooth depuis le serveur, sans téléphone"
        default: return "adb depuis l'hôte, dépôt dans data/inbox"
        }
    }
}

/// Bloc token d'ingestion — affiché uniquement pour la source `"phone"`
/// (miroir du `<div class="token-block">` Angular). Copie locale vers le
/// presse-papiers, aucune transmission réseau propre à ce geste.
private struct SettingsIngestTokenRow: View {
    var viewModel: SettingsViewModel
    let token: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.sm) {
            Text("Token d'ingestion")
                .font(.caption)
                .foregroundStyle(Color.pulseTextSecondary)
            Text(token ?? "—")
                .font(.system(.footnote, design: .rounded))
                .textSelection(.enabled)
            HStack(spacing: PulseSpacing.sm) {
                Button("Copier") {
                    guard let token else { return }
                    UIPasteboard.general.string = token
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .disabled(token == nil)

                Button("Régénérer") {
                    Task { await viewModel.regenerateIngestToken() }
                }
                .disabled(viewModel.isRegeneratingToken)

                if viewModel.isRegeneratingToken {
                    ProgressView()
                } else if copied {
                    Text("copié")
                        .font(.caption)
                        .foregroundStyle(Color.pulseSuccess)
                }
            }
            Text("Colle ce token dans l'app iPhone : réglages > Synchronisation. Régénérer invalide l'ancien.")
                .font(.caption2)
                .foregroundStyle(Color.pulseTextSecondary)
        }
        .padding(.vertical, PulseSpacing.xs)
    }
}

// MARK: - Synchronisation > État

private struct SettingsStatusSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        Section("État de la synchro") {
            if let status = viewModel.status {
                LabeledContent("État") {
                    Text(Self.stateLabel(status.state))
                        .foregroundStyle(Self.stateColor(status.state))
                }
                if let lastSuccess = status.lastSuccess {
                    LabeledContent("Dernier succès", value: lastSuccess)
                }
                LabeledContent("Fraîcheur des données", value: Self.freshnessLabel(status.freshness))
                if let progress = status.progress, let watchFiles = progress.watchFiles {
                    LabeledContent(
                        "Fichiers sur la montre",
                        value: "\(progress.remainingOnWatch ?? watchFiles) / \(watchFiles)"
                    )
                }
                if let message = status.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            if let inventory = viewModel.inventory {
                LabeledContent("Fichiers sur disque", value: "\(inventory.onDisk)")
                LabeledContent("Activités importées", value: "\(inventory.activities)")
                LabeledContent("Nuits", value: "\(inventory.nights)")
                LabeledContent("Jours", value: "\(inventory.days)")
            }
        }
    }

    private static func stateLabel(_ state: String) -> String {
        switch state {
        case "running": return "Synchronisation en cours…"
        case "ok": return "À jour"
        case "error": return "Erreur"
        default: return "Inactif"
        }
    }

    private static func stateColor(_ state: String) -> Color {
        switch state {
        case "running": return .pulseAccent
        case "ok": return .pulseSuccess
        case "error": return .pulseDanger
        // État neutre ("idle") — même jeton que le point du lien BLE côté
        // écran Statut (`--absent`, distinct de `--text-dim`).
        default: return .pulseAbsent
        }
    }

    private static func freshnessLabel(_ freshness: SettingsSyncFreshness) -> String {
        guard let age = freshness.ageSec else { return "aucune donnée" }
        if age < 60 { return "à l'instant" }
        if age < 3_600 { return "il y a \(age / 60) min" }
        if age < 86_400 { return "il y a \(age / 3_600) h" }
        return "il y a \(age / 86_400) j"
    }
}

// MARK: - Profil

private struct SettingsProfileSection: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Section {
            LabeledContent("Année de naissance") {
                TextField("AAAA", text: $viewModel.birthYearText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Taille") {
                HStack(spacing: PulseSpacing.xs) {
                    TextField("cm", text: $viewModel.heightCmText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("cm")
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            Picker("Sexe", selection: $viewModel.sex) {
                Text("Homme").tag(Optional("male"))
                Text("Femme").tag(Optional("female"))
            }
            .pickerStyle(.segmented)

            LabeledContent("Poids retenu", value: viewModel.profileWeightLabel)

            Button {
                Task { await viewModel.saveProfile() }
            } label: {
                if viewModel.isSavingProfile {
                    ProgressView()
                } else {
                    Text("Enregistrer")
                }
            }
            .disabled(viewModel.isSavingProfile)

            if viewModel.profileSaved {
                Text("enregistré")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseSuccess)
            }
            if let profileError = viewModel.profileError {
                Text(profileError)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseDanger)
            }
        } header: {
            Text("Profil")
        } footer: {
            Text("Sert au métabolisme de base, à l'âge physiologique et à l'objectif calorique dynamique. Le poids se saisit jour par jour sur la page Santé.")
        }
    }
}

// MARK: - Ligne de navigation (secondaire propre à un mode)
//
// Utilisée dans le bloc « Mode de connectivité » pour ouvrir le secondaire
// d'un mode donné : « Statut du pont » (bridge) et « Collecteur (Montre) »
// (iPhone BLE). Le secondaire n'est plus regroupé dans une section « Système »
// commune — chaque entrée vit sous le mode auquel elle appartient.

private struct SettingsNavRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: PulseSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(Color.pulseAccent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.pulseTextPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.pulseTextSecondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Application

private struct SettingsApplicationSection: View {
    @Bindable var viewModel: SettingsViewModel
    let username: String?

    var body: some View {
        Section("Compte") {
            LabeledContent("Utilisateur", value: username ?? "—")
            Text("Serveur personnel · rien ne sort d'ici")
                .font(.caption)
                .foregroundStyle(Color.pulseTextSecondary)
        }

        Section {
            TextField("https://pulse.<tailnet>.ts.net", text: $viewModel.baseURLText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Enregistrer l'adresse") {
                viewModel.saveBaseURL()
            }

            if viewModel.baseURLSaved {
                Text("enregistré")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseSuccess)
            }
            if let baseURLError = viewModel.baseURLError {
                Text(baseURLError)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseDanger)
            }
        } header: {
            Text("Adresse de Pulse")
        }

        Section {
            Button("Déconnexion", role: .destructive) {
                Task { await AuthStore.shared.logout() }
            }
        }
    }
}

#Preview {
    SettingsView()
}
