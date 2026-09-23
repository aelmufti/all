//
//  LoginView.swift
//  all (bridge-connect)
//
//  Porte de login — affichée par `ContentView` tant que `AuthStore.username`
//  est `nil`. `POST /api/auth/login` (cookie de session, cf. `AuthStore`).
//
//  Inclut aussi le champ d'adresse de Pulse (`PulseConfig.baseURL`) : c'était
//  auparavant saisi dans le `setupForm` de l'ancien `ContentView` (flux
//  WebView), qui disparaît de la coquille (cf. `PulseShellView`). L'adresse
//  n'est toujours **pas codée en dur** — sans elle, `PulseAPIClient` ne peut
//  targeter aucune requête (`.notConfigured`), donc pas de login possible :
//  elle doit rester accessible avant même la première tentative.
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

                PulseCard {
                    SectionHeader("Serveur")
                    TextField("https://pulse.<tailnet>.ts.net", text: $serverURLString)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(persistServerURL)
                        .onChange(of: serverURLString) { _, _ in persistServerURL() }
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
                    }

                    Button(action: submit) {
                        if isSubmitting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Se connecter")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.pulseAccent)
                    .disabled(!canSubmit || isSubmitting)
                    .padding(.top, PulseSpacing.xs)
                }
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
            } catch let error as PulseAPIError {
                switch error {
                case .unauthorized:
                    errorMessage = "Identifiant ou mot de passe incorrect."
                default:
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    LoginView()
}
