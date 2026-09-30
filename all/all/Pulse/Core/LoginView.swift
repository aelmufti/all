//
//  LoginView.swift
//  all (bridge-connect)
//
//  Porte de login — affichée par `ContentView` tant que `AuthStore.username`
//  est `nil` (une fois l'onboarding terminé). `POST /api/auth/login` (cookie
//  de session, cf. `AuthStore`).
//
//  Inclut aussi le champ d'adresse de Pulse (`PulseConfig.baseURL`) : c'était
//  auparavant saisi dans le `setupForm` de l'ancien `ContentView` (flux
//  WebView), qui disparaît de la coquille (cf. `PulseShellView`). L'adresse
//  n'est toujours **pas codée en dur** — sans elle, `PulseAPIClient` ne peut
//  targeter aucune requête (`.notConfigured`), donc pas de login possible :
//  elle doit rester accessible avant même la première tentative.
//
//  « Utiliser sans serveur » (incrément L0, `docs/stockage-local.md`) : un
//  utilisateur sans Pulse (pas d'adresse, pas de compte) doit pouvoir entrer
//  quand même — pose `StorageModeStore.shared.mode = .phone`, ce qui fait
//  disparaître cette porte au profit de la coquille (`ContentView` observe
//  `storageMode`, cf. son en-tête). Réversible depuis Réglages > Stockage.
//
//  `PulseCredentialsForm`/`PulseLoginErrorMapper` (ci-dessous) sont extraits
//  de cet écran pour être réutilisés tels quels par le sous-écran « Connexion
//  Pulse » de l'onboarding (`Pulse/Onboarding/OnboardingView.swift`,
//  `OnboardingPulseLoginStep`) — MÊME validation adresse/identifiants, MÊME
//  mapping d'erreur, sans dupliquer cette logique. `LoginView` continue de
//  fonctionner seule à l'identique (elle reste affichée post-onboarding si
//  Pulse est choisi mais la session a expiré).
//
import SwiftUI

struct LoginView: View {
    @State private var serverURLString = PulseConfig.baseURL?.absoluteString ?? ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let auth = AuthStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: PulseSpacing.lg) {
                VStack(spacing: PulseSpacing.xs) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.largeTitle)
                        .foregroundStyle(Color.pulseAccent)
                    Text("Pulse")
                        .font(.title2.bold())
                        .foregroundStyle(Color.pulseTextPrimary)
                }
                .padding(.top, PulseSpacing.xxl)

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

                Button("Utiliser sans serveur") {
                    StorageModeStore.shared.mode = .phone
                }
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
                .padding(.bottom, PulseSpacing.lg)
            }
            .padding(PulseSpacing.lg)
        }
        .background(Color.pulseBackground)
        .scrollDismissesKeyboard(.interactively)
    }

    private var canSubmit: Bool {
        PulseConfig.baseURL != nil && !username.isEmpty && !password.isEmpty
    }

    private func persistServerURL() {
        // Tolérant au schéma manquant, cf. `PulseConfig.setBaseURL`.
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
            } catch {
                errorMessage = PulseLoginErrorMapper.message(for: error)
            }
        }
    }
}

// MARK: - Formulaire réutilisable (adresse Pulse + identifiants)

/// Carte « Serveur » + carte « Connexion » — extrait de `LoginView` pour être
/// partagé avec `OnboardingPulseLoginStep` (cf. en-tête de fichier). Purement
/// visuel/de saisie : chaque appelant possède son propre `@State` et sa
/// propre logique de soumission (le succès n'a pas la même suite : `LoginView`
/// n'a rien à faire de plus, `ContentView` réagit déjà à `AuthStore.username`
/// ; l'onboarding doit en plus avancer à l'étape suivante).
struct PulseCredentialsForm: View {
    @Binding var serverURLString: String
    @Binding var username: String
    @Binding var password: String
    let isSubmitDisabled: Bool
    let isSubmitting: Bool
    let errorMessage: String?
    let submitLabel: String
    let onSubmit: () -> Void
    let onServerURLChange: () -> Void

    /// Ce qui manque pour activer « Se connecter », dans l'ordre des champs.
    /// `nil` = tout est rempli (le bouton est alors actif, sauf soumission en
    /// cours). Calculé depuis les bindings de ce formulaire, donc valable pour
    /// les trois appelants (login, onboarding, picker de stockage) sans param
    /// supplémentaire.
    private var disabledHint: String? {
        if serverURLString.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Renseignez l'adresse du serveur Pulse (https://…)."
        }
        if username.isEmpty { return "Renseignez votre identifiant." }
        if password.isEmpty { return "Renseignez votre mot de passe." }
        // Tous les champs remplis mais toujours désactivé : l'adresse n'a pas
        // pu être interprétée en URL (cf. `PulseConfig.setBaseURL`).
        return "Vérifiez l'adresse du serveur Pulse."
    }

    var body: some View {
        PulseCard {
            SectionHeader("Serveur")
            TextField("https://pulse.<tailnet>.ts.net", text: $serverURLString)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit(onServerURLChange)
                .onChange(of: serverURLString) { _, _ in onServerURLChange() }
        }

        PulseCard {
            SectionHeader("Connexion")
            TextField("Identifiant", text: $username)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Mot de passe", text: $password)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseDanger)
            } else if isSubmitDisabled, !isSubmitting, let disabledHint {
                // Pourquoi « Se connecter » est grisé — lève la confusion
                // (« je remplis tout et le bouton reste désactivé »).
                Text(disabledHint)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            Button(action: onSubmit) {
                if isSubmitting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(submitLabel)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.pulseAccent)
            .disabled(isSubmitDisabled)
            .padding(.top, PulseSpacing.xs)
        }
    }
}

/// Mapping d'erreur partagé — `.unauthorized` a un message dédié
/// (identifiants), tout le reste retombe sur `errorDescription`/
/// `localizedDescription`. Extrait de `LoginView.submit()` pour que
/// l'onboarding affiche exactement le même message pour la même erreur.
enum PulseLoginErrorMapper {
    static func message(for error: Error) -> String {
        if let apiError = error as? PulseAPIError {
            switch apiError {
            case .unauthorized:
                return "Identifiant ou mot de passe incorrect."
            default:
                return apiError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

#Preview {
    LoginView()
}
