//
//  OnboardingView.swift
//  all (bridge-connect)
//
//  Parcours d'accueil au premier lancement (cf. `OnboardingStore.swift`) —
//  guide l'utilisateur au minimum d'efforts vers un état opérationnel.
//  `ContentView` affiche cet écran EN PREMIER, avant toute autre logique,
//  tant que `OnboardingStore.shared.completed == false`.
//
//  Quatre étapes, dans l'ordre :
//   1. Stockage (REQUISE, non passable) — « Tout sur mon téléphone » vs
//      « Utiliser mon serveur Pulse ». Le choix Pulse ouvre un sous-écran de
//      connexion (réutilise `PulseCredentialsForm`/`PulseLoginErrorMapper`,
//      extraits de `LoginView.swift`) : la connexion doit réussir pour
//      avancer, avec un retour possible vers le choix.
//   2. Profil (passable, « Plus tard ») — `PUT api/profile` via
//      `PulseAPIClient` (route déjà vers le backend local en mode Téléphone,
//      vers Pulse en mode Pulse — transparent ici, cf. `PulseAPIClient`).
//   3. Montre (passable) — explicatif + ouverture de `WatchSectionView`.
//   4. Thème (passable) — `ThemeStore.shared`.
//  Fin → `OnboardingStore.shared.markCompleted()` → `ContentView` bascule sur
//  la coquille normale (storageMode/auth), plus jamais réaffiché ensuite.
//

import SwiftUI

struct OnboardingView: View {
    private enum Step: Int, CaseIterable {
        case storage
        case profile
        case watch
        case theme
    }

    @State private var step: Step = .storage
    /// Sous-écran de l'étape Stockage, affiché uniquement après le choix
    /// « Utiliser mon serveur Pulse » — cf. en-tête de fichier. Reste `false`
    /// tant que le choix n'est pas fait, et si « Tout sur mon téléphone » est
    /// choisi (jamais montré dans ce cas).
    @State private var showPulseLogin = false

    var body: some View {
        ScrollView {
            VStack(spacing: PulseSpacing.xl) {
                OnboardingProgressIndicator(current: step.rawValue, total: Step.allCases.count)

                Group {
                    switch step {
                    case .storage:
                        if showPulseLogin {
                            OnboardingPulseLoginStep(
                                onSuccess: { step = .profile },
                                onBack: { showPulseLogin = false }
                            )
                        } else {
                            OnboardingStorageModeStep(
                                onChoosePhone: {
                                    StorageModeStore.shared.mode = .phone
                                    step = .profile
                                },
                                onChoosePulse: {
                                    StorageModeStore.shared.mode = .pulse
                                    showPulseLogin = true
                                }
                            )
                        }
                    case .profile:
                        OnboardingProfileStep(
                            onContinue: { step = .watch },
                            onSkip: { step = .watch }
                        )
                    case .watch:
                        OnboardingWatchStep(onSkip: { step = .theme })
                    case .theme:
                        OnboardingThemeStep(onFinish: { OnboardingStore.shared.markCompleted() })
                    }
                }
            }
            .padding(PulseSpacing.lg)
        }
        .background(Color.pulseBackground)
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - Indicateur d'étape

/// Quatre segments (une par étape principale, cf. `OnboardingView.Step`) — le
/// sous-écran de connexion Pulse ne compte pas comme une étape à part
/// entière (il reste rattaché au segment Stockage).
private struct OnboardingProgressIndicator: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: PulseSpacing.sm) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Color.pulseAccent : Color.pulseBorder)
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Étape \(current + 1) sur \(total)")
    }
}

// MARK: - En-tête / actions communs aux étapes 2-4

/// Titre + sous-titre alignés à gauche — commun aux étapes 2 à 4 (l'étape 1
/// a son propre en-tête centré avec icône, cf. `OnboardingStorageModeStep`).
private struct OnboardingStepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(Color.pulseTextPrimary)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bouton primaire « Continuer »/« Terminer » + bouton secondaire
/// « Plus tard » — commun aux étapes passables (2, 4 ; l'étape 3 a un bouton
/// supplémentaire propre, cf. `OnboardingWatchStep`, et compose son propre
/// « Plus tard » plutôt que ce composant).
private struct OnboardingStepActions: View {
    var continueLabel: String = "Continuer"
    var isBusy: Bool = false
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: PulseSpacing.sm) {
            Button(action: onContinue) {
                if isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(continueLabel)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.pulseAccent)
            .disabled(isBusy)

            OnboardingSkipButton(action: onSkip)
        }
    }
}

private struct OnboardingSkipButton: View {
    let action: () -> Void

    var body: some View {
        Button("Plus tard", action: action)
            .font(.footnote)
            .foregroundStyle(Color.pulseTextSecondary)
    }
}

// MARK: - Étape 1 — Stockage (requise)

private struct OnboardingStorageModeStep: View {
    let onChoosePhone: () -> Void
    let onChoosePulse: () -> Void

    var body: some View {
        VStack(spacing: PulseSpacing.xl) {
            VStack(spacing: PulseSpacing.sm) {
                Image(systemName: "waveform.path.ecg")
                    .font(.largeTitle)
                    .foregroundStyle(Color.pulseAccent)
                Text("Bienvenue sur All")
                    .font(.title2.bold())
                    .foregroundStyle(Color.pulseTextPrimary)
                Text("Choisis où vivent tes données. Modifiable ensuite dans Paramètres > Stockage.")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, PulseSpacing.xl)

            VStack(spacing: PulseSpacing.md) {
                Button(action: onChoosePhone) {
                    OnboardingChoiceCard(
                        icon: "iphone",
                        title: "Tout sur mon téléphone",
                        subtitle: "Autonome, aucun compte — les données restent sur cet iPhone."
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tout sur mon téléphone. Autonome, aucun compte, les données restent sur cet iPhone.")

                Button(action: onChoosePulse) {
                    OnboardingChoiceCard(
                        icon: "server.rack",
                        title: "Utiliser mon serveur Pulse",
                        subtitle: "Connecte-toi à ton serveur Pulse personnel."
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Utiliser mon serveur Pulse. Connecte-toi à ton serveur Pulse personnel.")
            }
        }
    }
}

private struct OnboardingChoiceCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        PulseCard {
            HStack(spacing: PulseSpacing.md) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Color.pulseAccent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                    Text(title)
                        .font(PulseFont.sectionTitle)
                        .foregroundStyle(Color.pulseTextPrimary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                Spacer(minLength: PulseSpacing.sm)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Étape 1b — Connexion Pulse (sous-écran, si « Pulse » choisi)

private struct OnboardingPulseLoginStep: View {
    let onSuccess: () -> Void
    let onBack: () -> Void

    @State private var serverURLString = PulseConfig.baseURL?.absoluteString ?? ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let auth = AuthStore.shared

    var body: some View {
        VStack(spacing: PulseSpacing.lg) {
            HStack {
                Button(action: onBack) {
                    Label("Retour", systemImage: "chevron.left")
                        .font(.footnote)
                }
                .foregroundStyle(Color.pulseTextSecondary)
                Spacer()
            }

            OnboardingStepHeader(
                title: "Connexion à Pulse",
                subtitle: "Renseigne l'adresse de ton serveur Pulse puis connecte-toi avec ton compte."
            )

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
    }

    private var canSubmit: Bool {
        PulseConfig.baseURL != nil && !username.isEmpty && !password.isEmpty
    }

    private func persistServerURL() {
        let trimmed = serverURLString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme != nil else { return }
        PulseConfig.baseURL = url
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
                onSuccess()
            } catch {
                errorMessage = PulseLoginErrorMapper.message(for: error)
            }
        }
    }
}

// MARK: - Étape 2 — Profil (passable)

private struct OnboardingProfileStep: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var birthYearText = ""
    @State private var heightCmText = ""
    @State private var weightKgText = ""
    @State private var sex: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let client = PulseAPIClient.shared

    var body: some View {
        VStack(spacing: PulseSpacing.lg) {
            OnboardingStepHeader(
                title: "Ton profil",
                subtitle: "Sert au métabolisme de base et à l'objectif calorique. Complétable plus tard dans Paramètres."
            )

            PulseCard {
                LabeledContent("Année de naissance") {
                    TextField("AAAA", text: $birthYearText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Taille") {
                    HStack(spacing: PulseSpacing.xs) {
                        TextField("cm", text: $heightCmText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("cm")
                            .font(.footnote)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }
                LabeledContent("Poids") {
                    HStack(spacing: PulseSpacing.xs) {
                        TextField("kg", text: $weightKgText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("kg")
                            .font(.footnote)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }
                Picker("Sexe", selection: $sex) {
                    Text("Homme").tag(Optional("male"))
                    Text("Femme").tag(Optional("female"))
                }
                .pickerStyle(.segmented)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.pulseDanger)
                }
            }

            OnboardingStepActions(
                isBusy: isSaving,
                onContinue: save,
                onSkip: onSkip
            )
        }
    }

    /// Enregistre uniquement les champs renseignés (mêmes bornes que
    /// `ProfileController.update`/`RealLocalPulseBackend.encodeProfileUpdate`
    /// côté serveur — validées là-bas, pas dupliquées ici : un champ hors
    /// bornes revient simplement en erreur réseau, affichée sans jamais
    /// bloquer, cf. en-tête de fichier). Rien de renseigné → avance sans
    /// appel réseau superflu.
    private func save() {
        errorMessage = nil
        guard !isSaving else { return }

        var body = SettingsProfileUpdateRequest()
        if let year = Int(birthYearText.trimmingCharacters(in: .whitespaces)) {
            body.birthYear = year
        }
        body.sex = sex
        let trimmedHeight = heightCmText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if let height = Double(trimmedHeight), height > 0 {
            body.heightCm = height
        }
        let trimmedWeight = weightKgText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if let weight = Double(trimmedWeight), weight > 0 {
            body.weightKg = weight
        }

        guard body.birthYear != nil || body.sex != nil || body.heightCm != nil || body.weightKg != nil else {
            onContinue()
            return
        }

        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let _: SettingsProfile = try await client.put("api/profile", body: body)
                onContinue()
            } catch {
                // Ne bloque JAMAIS (cf. en-tête de fichier) : message affiché,
                // mais « Plus tard » reste disponible pour avancer quand même.
                errorMessage = (error as? PulseAPIError)?.errorDescription
                    ?? "Enregistrement refusé — vérifie les valeurs, ou passe cette étape."
            }
        }
    }
}

// MARK: - Étape 3 — Montre (passable)

private struct OnboardingWatchStep: View {
    let onSkip: () -> Void

    @State private var showWatch = false

    var body: some View {
        VStack(spacing: PulseSpacing.lg) {
            OnboardingStepHeader(
                title: "Ta montre",
                subtitle: "Ouvre l'app près de ta Venu 2 pour rapatrier tes données. Possible aussi plus tard, depuis Paramètres > Montre."
            )

            PulseCard {
                HStack(spacing: PulseSpacing.md) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundStyle(Color.pulseAccent)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                        Text("Collecteur Bluetooth")
                            .font(PulseFont.sectionTitle)
                            .foregroundStyle(Color.pulseTextPrimary)
                        Text("Diagnostic BLE, synchronisation en temps réel.")
                            .font(.footnote)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }
            }

            Button("Ouvrir le collecteur") { showWatch = true }
                .buttonStyle(.borderedProminent)
                .tint(Color.pulseAccent)
                .frame(maxWidth: .infinity)

            OnboardingSkipButton(action: onSkip)
        }
        .sheet(isPresented: $showWatch) {
            WatchSectionView()
        }
    }
}

// MARK: - Étape 4 — Thème (passable)

private struct OnboardingThemeStep: View {
    let onFinish: () -> Void

    @State private var theme = ThemeStore.shared

    var body: some View {
        VStack(spacing: PulseSpacing.lg) {
            OnboardingStepHeader(
                title: "Apparence",
                subtitle: "Modifiable à tout moment dans Paramètres."
            )

            PulseCard {
                Picker("Thème", selection: themeBinding) {
                    Text("Clair").tag(ThemeStore.Theme.light)
                    Text("Sombre").tag(ThemeStore.Theme.dark)
                    Text("Auto").tag(ThemeStore.Theme.auto)
                }
                .pickerStyle(.segmented)
            }

            OnboardingStepActions(
                continueLabel: "Terminer",
                onContinue: onFinish,
                onSkip: onFinish
            )
        }
    }

    private var themeBinding: Binding<ThemeStore.Theme> {
        Binding(get: { theme.theme }, set: { theme.theme = $0 })
    }
}

#Preview {
    OnboardingView()
}
