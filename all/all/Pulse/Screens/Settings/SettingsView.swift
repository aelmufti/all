//
//  SettingsView.swift
//  all (bridge-connect)
//
//  Écran Paramètres natif — deux niveaux, façon Réglages iOS.
//
//  Racine : uniquement des LIGNES (pastille, nom, valeur courante), en trois
//  groupes — moi (Profil, Réveil, Programme), données (Stockage,
//  Synchronisation, Montre), app (Apparence, Aide) — plus le compte serveur
//  quand il y en a un. Aucun contrôle ni texte d'explication à ce niveau.
//
//  Second niveau : une page par réglage (`SettingsProfilePage`,
//  `SettingsWakePage`, `SettingsStoragePage`, `SettingsSyncPage`). Programme,
//  Montre et Aide restent des feuilles (elles ont leur propre navigation).
//  Les explications vivent dans `HelpView`.
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
    private let auth = AuthStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showStatus = false
    @State private var showWatch = false
    @State private var showProgramme = false
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

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Paramètres")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { SheetCloseButton { dismiss() } }
        }
        // Bouton retour des sous-pages à la couleur de l'app, pas au bleu système.
        .tint(Color.pulseAccent)
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
        .sheet(isPresented: $showWatch) { WatchSectionView() }
        .sheet(isPresented: $showProgramme) { ProgrammeView() }
        .sheet(isPresented: $showHelp) { HelpView() }
        // Ancré à la racine stable (pas sur une Section du Form) — cf. le
        // commentaire de `pendingServerMode`.
        .sheet(item: $pendingServerMode) { mode in
            PulseModeLoginSheet(targetMode: mode)
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
                    Button { showProgramme = true } label: {
                        SettingsRow(icon: "calendar", tint: .pulseSteps, title: "Programme", opensSheet: true)
                    }
                }

                Section {
                    NavigationLink {
                        SettingsStoragePage(viewModel: viewModel, onRequestServerLogin: { pendingServerMode = $0 })
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
                    Button { showWatch = true } label: {
                        SettingsRow(
                            icon: "applewatch", tint: .pulseBattery, title: "Montre",
                            value: ble.connectionState == .connected ? "Connectée" : nil, opensSheet: true)
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
                        LabeledContent("Utilisateur", value: auth.username ?? "—")
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
// : la ligne est un `Button` qui présente une feuille (Programme, Montre, Aide),
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
    }
}

// MARK: - Pages de second niveau

/// Stockage : le choix, et juste dessous l'adresse de Pulse quand il en dépend.
private struct SettingsStoragePage: View {
    @Bindable var viewModel: SettingsViewModel
    let onRequestServerLogin: (StorageMode) -> Void
    @State private var storageMode = StorageModeStore.shared

    var body: some View {
        Form {
            SettingsStorageSection(onRequestServerLogin: onRequestServerLogin)
            if storageMode.mode != .phone {
                SettingsPulseAddressSection(viewModel: viewModel)
            }
        }
        .navigationTitle("Stockage")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsWakePage: View {
    var body: some View {
        Form {
            SettingsWakeSection()
        }
        .navigationTitle("Réveil")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Synchronisation (modes avec serveur) : qui collecte, puis l'état.
private struct SettingsSyncPage: View {
    var viewModel: SettingsViewModel
    let onStatus: () -> Void

    var body: some View {
        Form {
            SettingsSyncSourceSection(viewModel: viewModel, onStatus: onStatus)
            SettingsStatusSection(viewModel: viewModel)
        }
        .navigationTitle("Synchronisation")
        .navigationBarTitleDisplayMode(.inline)
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

// MARK: - Réveil (heure de lever, lié au profil)
//
// Déplacé depuis l'onglet Sommeil (où il n'avait pas sa place) vers les
// Paramètres. Réglage réglé DANS l'app — pas une alarme de l'app Horloge iOS
// (illisible et non pilotable depuis une app tierce). Double rôle : programme
// un rappel sonore (`WakeAlarmScheduler`) et pilote l'adaptation de la carte
// « Heure de coucher conseillée » de l'écran Sommeil : dès qu'un réveil est
// réglé pour le prochain lever, celle-ci se recalcule sur cette heure plutôt
// que sur l'heure de lever habituelle renvoyée par le serveur.
//
// Présenté dans TOUS les modes de stockage (lié au profil, pas à la source de
// synchro). Restylé en `Form`/`Section` pour cet écran — l'ancienne carte
// `PulseCard` de l'onglet Sommeil n'aurait pas le bon vocabulaire visuel ici.
//
// NOTE (incrément A) : la persistance reste pour l'instant le store global
// `WakeScheduleStore` (`UserDefaults`, device-wide). Le passage à un stockage
// lié au profil (serveur en mode Pulse/Les deux via `GET`/`PUT
// api/wake-schedule`, SQLite local en mode Téléphone) se fait dans les
// incréments suivants, sans changer l'API lue ici (`store.minutesByWeekday`,
// `set`, `clear`).

private struct SettingsWakeSection: View {
    private static let weekdays = [2, 3, 4, 5, 6, 7, 1] // Lun … Dim (Calendar weekday, 1 = dim.)
    private static let labels = ["Lun", "Mar", "Mer", "Jeu", "Ven", "Sam", "Dim"]

    @State private var time: Date = {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 7
        components.minute = 0
        return Calendar.current.date(from: components) ?? Date()
    }()
    @State private var selected: Set<Int> = []

    /// `WakeScheduleStore` étant `@Observable`, lire `minutesByWeekday` ici
    /// fait redessiner la section après chaque `set`/`clear`.
    @State private var store = WakeScheduleStore.shared

    /// Accès au lien BLE courant (état de connexion + `GarminSession` active)
    /// pour le bouton « Envoyer à la montre » — même point d'entrée que le
    /// reste de l'app (`BLEManager.shared`, ex. `WeightCard` dans
    /// `HealthSubviews.swift`, qui observe `ble.weightWriteState`).
    @ObservedObject private var ble = BLEManager.shared

    private var pickedMinutes: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (c.hour ?? 7) * 60 + (c.minute ?? 0)
    }

    var body: some View {
        Section {
            DatePicker("Heure", selection: $time, displayedComponents: .hourAndMinute)

            weekdayChips

            HStack(spacing: PulseSpacing.sm) {
                Button {
                    let minutes = pickedMinutes
                    let weekdays = selected
                    Task {
                        _ = await WakeAlarmScheduler.shared.requestAuthorizationIfNeeded()
                        WakeScheduleStore.shared.set(minutes: minutes, weekdays: weekdays)
                    }
                } label: {
                    Text("Régler à \(WakeScheduleStore.hhmm(pickedMinutes))")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.pulseOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous)
                                .fill(selected.isEmpty ? Color.pulseEmpty : Color.pulseAccent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty)

                Button {
                    WakeScheduleStore.shared.clear(weekdays: selected)
                } label: {
                    Text("Désactiver")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected.isEmpty ? Color.pulseAbsent : Color.pulseTextPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous)
                                .fill(Color.pulseSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous)
                                .strokeBorder(Color.pulseBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty)
            }
            .listRowInsets(EdgeInsets(top: PulseSpacing.xs, leading: PulseSpacing.md,
                                      bottom: PulseSpacing.xs, trailing: PulseSpacing.md))

            // Envoi manuel du planning courant vers la montre (alarme native,
            // `GarminSession.writeAlarms`) — jamais automatique. Déclenché
            // indépendamment du rappel téléphone ci-dessus (qui, lui, reste
            // inchangé).
            if let session = ble.garminSession {
                WatchAlarmUploadRow(
                    session: session,
                    schedule: store.minutesByWeekday,
                    isLinkActive: ble.connectionState == .connected
                )
            } else {
                WatchAlarmUploadRow.disconnectedPlaceholder
            }
        }
    }

    private var weekdayChips: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { index, weekday in
                let isSelected = selected.contains(weekday)
                Button {
                    if isSelected { selected.remove(weekday) } else { selected.insert(weekday) }
                } label: {
                    VStack(spacing: 3) {
                        Text(Self.labels[index])
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        if let minutes = store.minutes(for: weekday) {
                            Text(WakeScheduleStore.hhmm(minutes))
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(isSelected ? Color.pulseSurface.opacity(0.85) : Color.pulseSleep)
                        } else {
                            Text("—")
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(isSelected ? Color.pulseSurface.opacity(0.6) : Color.pulseAbsent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .foregroundStyle(isSelected ? Color.pulseSurface : Color.pulseTextSecondary)
                    .background(isSelected ? Color.pulseTextPrimary : Color.pulseSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isSelected ? Color.clear : Color.pulseBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .listRowInsets(EdgeInsets(top: PulseSpacing.xs, leading: PulseSpacing.md,
                                  bottom: PulseSpacing.xs, trailing: PulseSpacing.md))
    }
}

// MARK: - Envoi du planning d'alarmes vers la montre (upload FIT Settings)
//
// Bouton manuel (jamais automatique) qui pousse `store.minutesByWeekday` vers
// la montre via `GarminSession.writeAlarms` (canal d'upload partagé avec le
// poids, cf. `GarminSession.swift`). Observe directement la `GarminSession`
// active plutôt que `BLEManager` : contrairement au poids
// (`BLEManager.weightWriteState`, relayé par un abonnement existant côté
// `BLEManager`), rien ne relaie encore `GarminSession.$alarmWriteState`
// jusqu'à `BLEManager` — un `@Published` d'un `ObservableObject` ENFANT ne
// remonte pas automatiquement à l'`objectWillChange` du parent en
// SwiftUI/Combine (cf. le commentaire de
// `BLEManager.garminSessionChangeForwarder`). Ajouter ce relais appartient à
// `BLEManager.swift`, hors périmètre de cette tâche (lot parallélisé) : cette
// ligne s'abonne donc elle-même à la session, ce qui suffit à rester à jour
// sans y toucher.
private struct WatchAlarmUploadRow: View {
    @ObservedObject var session: GarminSession
    let schedule: [Int: Int]
    let isLinkActive: Bool

    /// Rendu quand aucune `GarminSession` n'est active (pas de lien BLE) —
    /// bouton désactivé, pas de session à observer.
    static var disconnectedPlaceholder: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
            sendButtonLabel(enabled: false)
            Text("aucun lien BLE actif")
                .font(.caption)
                .foregroundStyle(Color.pulseAbsent)
        }
        .listRowInsets(EdgeInsets(top: PulseSpacing.xs, leading: PulseSpacing.md,
                                  bottom: PulseSpacing.xs, trailing: PulseSpacing.md))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
            Button {
                session.writeAlarms(schedule: schedule)
            } label: {
                Self.sendButtonLabel(enabled: canSend)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)

            if session.alarmWriteState != .idle {
                HStack(spacing: PulseSpacing.xs) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 11))
                    Text("Montre : \(session.alarmWriteState.label)")
                        .font(.caption)
                }
                .foregroundStyle(statusColor)
            }
        }
        .listRowInsets(EdgeInsets(top: PulseSpacing.xs, leading: PulseSpacing.md,
                                  bottom: PulseSpacing.xs, trailing: PulseSpacing.md))
    }

    private var canSend: Bool {
        isLinkActive && session.alarmWriteState != .uploading
    }

    private static func sendButtonLabel(enabled: Bool) -> some View {
        Text("Envoyer à la montre")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(enabled ? Color.pulseOnAccent : Color.pulseTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous)
                    .fill(enabled ? Color.pulseAccent : Color.pulseEmpty)
            )
    }

    private var statusIcon: String {
        switch session.alarmWriteState {
        case .sent: return "checkmark.circle.fill"
        case .refused, .failed: return "exclamationmark.triangle.fill"
        case .uploading: return "arrow.up.circle"
        default: return "clock"
        }
    }

    private var statusColor: Color {
        switch session.alarmWriteState {
        case .sent: return Color.pulseSteps
        case .refused, .failed: return Color.pulseCalories
        default: return Color.pulseTextSecondary
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

    var body: some View {
        Section {
            Picker("Source", selection: sourceBinding) {
                ForEach(SettingsSyncSourceKind.selectable) { kind in
                    Text(kind.label).tag(kind.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isChangingSource)

            if let source = viewModel.source {
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
                        HStack {
                            Text("Statut du pont").foregroundStyle(Color.pulseTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.pulseAbsent)
                        }
                        .contentShape(Rectangle())
                    }
                }

                if source.source == "phone" {
                    SettingsIngestTokenRow(viewModel: viewModel, token: source.ingestToken)
                }

                if source.overridden {
                    Text("Réglé sur « \(source.configured == "bridge" ? "bridge" : "legacy") » dans l'environnement du conteneur, remplacé ici. Ce choix survit aux redémarrages.")
                        .font(.caption)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }

            // Source serveur sur la chaîne historique (masquée du sélecteur) :
            // Pulse refuse alors les envois de l'app — on le dit, sinon rien
            // n'indique pourquoi les données n'arrivent plus.
            if viewModel.source?.source == SettingsSyncSourceKind.legacy.rawValue {
                Text("Pulse est réglé sur l'ancienne chaîne par câble : il refuse les envois de cette app. Choisis « iPhone (BLE) » pour reprendre.")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseDanger)
            }

            if let sourceError = viewModel.sourceError {
                Text(sourceError)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseDanger)
            }
        } header: {
            Text("Source")
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
                // État / dernier succès / progression / message décrivent la
                // collecte faite PAR LE SERVEUR (pont, ou à défaut l'ancienne
                // chaîne par câble). Quand c'est l'iPhone qui collecte, le
                // serveur renvoie l'état figé de l'ancienne chaîne — un « Erreur »
                // permanent sans rapport avec la synchro réelle : on ne
                // l'affiche pas. La fraîcheur, elle, vient des données reçues.
                if viewModel.source?.source == SettingsSyncSourceKind.bridge.rawValue {
                    LabeledContent("État") {
                        Text(Self.stateLabel(status.state))
                            .foregroundStyle(Self.stateColor(status.state))
                    }
                    if let lastSuccess = status.lastSuccess {
                        LabeledContent("Dernier succès", value: lastSuccess)
                    }
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
                LabeledContent("Fraîcheur des données", value: Self.freshnessLabel(status.freshness))
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

/// Page « Profil », ouverte depuis la section Compte.
private struct SettingsProfilePage: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            SettingsProfileSection(viewModel: viewModel)
        }
        .navigationTitle("Profil")
        .navigationBarTitleDisplayMode(.inline)
    }
}

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
        }
    }
}

// MARK: - Adresse de Pulse

private struct SettingsPulseAddressSection: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
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
    }
}

#Preview {
    SettingsView()
}
