//
//  SettingsView.swift
//  all (bridge-connect)
//
//  Écran Paramètres natif — deux niveaux, façon Réglages iOS.
//
//  Racine : uniquement des LIGNES (pastille, nom, valeur courante), en trois
//  groupes — moi (Profil, Réveil), données (Stockage, Synchronisation, Montre),
//  app (Apparence, Aide) — plus la déconnexion quand il y a un serveur. Aucun
//  contrôle ni texte d'explication à ce niveau. (Programme a son onglet.)
//
//  Second niveau : une page par réglage, chacune dans son fichier
//  (`SettingsProfilePage`, `SettingsWakePage`, `SettingsStoragePage`,
//  `SettingsSyncPage`, `SettingsWatchPage`), poussées dans la pile de navigation
//  de cet écran. Seule Aide reste une feuille. Les explications vivent dans
//  `HelpView`.
//
//  Mode Téléphone : pas de serveur, donc ni Synchronisation ni compte ;
//  `SettingsViewModel.load()` ne charge alors que le profil.
//
//  Toutes les déclarations de ce fichier sont préfixées `Settings*` pour ne
//  rien exposer qui puisse entrer en collision avec les autres écrans.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showStatus = false
    @State private var showHelp = false
    @State private var storageMode = StorageModeStore.shared
    @State private var theme = ThemeStore.shared
    @State private var wake = WakeScheduleStore.shared
    @ObservedObject private var ble = BLEManager.shared
    /// Mode serveur (Pulse / Les deux) demandé depuis le picker de stockage
    /// alors qu'aucune session n'est active — présente `PulseModeLoginSheet`.
    /// Tenu ICI (racine stable de l'écran) et non dans `SettingsStorageSection`
    /// : ancré sur une `Section`, le `.sheet` se refermait tout seul dès que le
    /// `Form` se re-diffait (le `@State` de la section était réinitialisé).
    @State private var pendingServerMode: StorageMode?
    /// Changement de mode en attente de confirmation (`StorageModeChange.swift`) :
    /// tenu ICI pour la même raison que `pendingServerMode` — l'alerte est ancrée à la
    /// racine stable, pas à une `Section` du `Form` de la page Stockage.
    @State private var modeChange = StorageModeChangeController()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Paramètres")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { SheetCloseButton { dismiss() } }
        }
        // Bouton retour des sous-pages à la couleur de l'app, pas au bleu système.
        .tint(Color.pulseAccent)
        // La bannière globale de synchro vit sur la coquille (`PulseShellView`),
        // que cette feuille recouvre : sans ce rappel, rien ne montrait l'activité
        // déclenchée d'ici même (changement de stockage, purge). En bas, pour ne
        // pas masquer le titre ni le bouton retour de la barre de navigation.
        .overlay(alignment: .bottom) {
            SyncStatusBanner()
                .padding(.bottom, PulseSpacing.md)
        }
        .task {
            await viewModel.reload()
        }
        // Basculer le mode de stockage change radicalement ce que cet écran a
        // de sens à charger (cf. `SettingsViewModel.load()`) — recharge à
        // chaque changement, pas seulement à l'ouverture de la feuille.
        .onChange(of: storageMode.mode) { _, _ in
            Task { await viewModel.reload() }
        }
        .sheet(isPresented: $showStatus) { StatusView() }
        .sheet(isPresented: $showHelp) { HelpView() }
        // Ancré à la racine stable (pas sur une Section du Form) — cf. le
        // commentaire de `pendingServerMode`.
        .sheet(item: $pendingServerMode) { mode in
            PulseModeLoginSheet(targetMode: mode)
        }
        // Tout changement de mode passe par une confirmation ; la connexion à Pulse,
        // si elle est nécessaire, vient APRÈS (`.needsLogin`).
        .alert(
            modeChange.pending?.changeConfirmationTitle ?? "",
            isPresented: Binding(get: { modeChange.pending != nil }, set: { if !$0 { modeChange.cancel() } }),
            presenting: modeChange.pending
        ) { _ in
            Button("Confirmer") {
                if case .needsLogin(let mode) = modeChange.confirm() { pendingServerMode = mode }
            }
            Button("Annuler", role: .cancel) { modeChange.cancel() }
        } message: { mode in
            Text(mode.changeConfirmation)
        }
    }

    // Deux niveaux. La racine ne porte que des LIGNES (icône, nom, valeur
    // courante) ; chaque réglage vit sur sa propre page. Aucun contrôle ni texte
    // d'explication ici : on lit l'état d'un coup d'œil, on entre pour changer.
    @ViewBuilder
    private var content: some View {
        if case .loading = viewModel.state {
            LoadingView(message: "Chargement des paramètres…")
        } else {
            Form {
                // Pulse injoignable : la racine reste utilisable (c'est d'ici
                // qu'on corrige l'adresse ou qu'on repasse en Téléphone) — avant,
                // tout l'écran était remplacé par une erreur sans issue.
                if case .failed(let message) = viewModel.state {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Color.pulseDanger)
                        Button("Réessayer") { Task { await viewModel.retry() } }
                    }
                }

                Section {
                    NavigationLink {
                        SettingsProfilePage(viewModel: viewModel)
                    } label: {
                        SettingsRow(icon: "person.fill", tint: .pulseAccent, title: "Profil")
                    }
                    NavigationLink {
                        SettingsWakePage()
                    } label: {
                        SettingsRow(icon: "alarm.fill", tint: .pulseSleep, title: "Réveil", value: wakeSummary)
                    }
                }

                Section {
                    NavigationLink {
                        SettingsStoragePage(viewModel: viewModel, onRequestModeChange: { modeChange.request($0) })
                    } label: {
                        SettingsRow(icon: "externaldrive.fill", tint: .pulseSpo2, title: "Stockage", value: storageMode.mode.label)
                    }
                    if storageMode.mode != .phone {
                        NavigationLink {
                            SettingsSyncPage(viewModel: viewModel, onStatus: { showStatus = true })
                        } label: {
                            SettingsRow(
                                icon: "arrow.triangle.2.circlepath", tint: .pulseStress,
                                title: "Synchronisation", value: syncSummary)
                        }
                    }
                    NavigationLink {
                        SettingsWatchPage()
                    } label: {
                        SettingsRow(
                            icon: "applewatch", tint: .pulseBattery, title: "Montre",
                            value: SettingsWatchStatus.label(for: ble.connectionState))
                    }
                }

                Section {
                    Picker(selection: themeBinding) {
                        Text("Automatique").tag(ThemeStore.Theme.auto)
                        Text("Clair").tag(ThemeStore.Theme.light)
                        Text("Sombre").tag(ThemeStore.Theme.dark)
                    } label: {
                        SettingsRow(icon: "circle.lefthalf.filled", tint: .pulseSleepDeep, title: "Apparence")
                    }
                    Button { showHelp = true } label: {
                        SettingsRow(icon: "questionmark", tint: .pulseTextSecondary, title: "Aide", opensSheet: true)
                    }
                }

                if storageMode.mode != .phone {
                    Section {
                        Button("Déconnexion", role: .destructive) {
                            Task { await AuthStore.shared.logout() }
                        }
                    }
                }
            }
        }
    }

    private var themeBinding: Binding<ThemeStore.Theme> {
        Binding(get: { theme.theme }, set: { theme.theme = $0 })
    }

    private var wakeSummary: String {
        let days = wake.minutesByWeekday.count
        guard days > 0 else { return "Désactivé" }
        let times = Set(wake.minutesByWeekday.values)
        if times.count == 1, let minutes = times.first {
            return days == 7 ? WakeScheduleStore.hhmm(minutes) : "\(WakeScheduleStore.hhmm(minutes)) · \(days) j"
        }
        return "\(days) jours"
    }

    private var syncSummary: String? {
        guard let raw = viewModel.source?.source else { return nil }
        return SettingsSyncSourceKind(rawValue: raw)?.label
    }
}

// MARK: - Ligne de la racine
//
// Pastille colorée + nom + valeur courante, comme les Réglages iOS. `opensSheet`
// : la ligne est un `Button` qui présente une feuille (Aide),
// il faut alors dessiner le chevron qu'un `NavigationLink` pose tout seul.

private struct SettingsRow: View {
    let icon: String
    let tint: Color
    let title: String
    var value: String?
    var opensSheet = false

    var body: some View {
        HStack(spacing: PulseSpacing.md) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(Color.pulseTextPrimary)
            Spacer(minLength: PulseSpacing.sm)
            if let value {
                Text(value)
                    .foregroundStyle(Color.pulseTextSecondary)
                    .lineLimit(1)
            }
            if opensSheet {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.pulseAbsent)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Connexion Pulse depuis la liste des modes de stockage
//
// Présentée par `SettingsView` quand l'utilisateur choisit
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

#Preview {
    SettingsView()
}
