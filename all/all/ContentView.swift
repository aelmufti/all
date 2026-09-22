//
//  ContentView.swift
//  all (bridge-connect)
//

import SwiftUI

struct ContentView: View {
    @State private var pulseURLString = PulseConfig.baseURL?.absoluteString ?? ""
    @State private var loadedURL: URL? = PulseConfig.baseURL

    // État de chargement de la WebView, pour diagnostiquer les pages blanches.
    private enum LoadState { case loading, loaded, failed }
    @State private var loadState: LoadState = .loading
    @State private var loadError: String?
    @State private var reloadToken = 0

    var body: some View {
        // Onglet « BLE » = diagnostic de l'incrément 1, à côté de la WebView
        // Pulse existante (ne remplace rien, s'ajoute — CADRAGE incrément 1).
        TabView {
            Group {
                if let url = loadedURL {
                    pulseTab(url: url)
                } else {
                    setupForm
                }
            }
            .tabItem { Label("Pulse", systemImage: "waveform.path.ecg") }

            BLEDiagnosticView()
                .tabItem { Label("BLE", systemImage: "antenna.radiowaves.left.and.right") }
        }
    }

    // WebView Pulse + bandeau d'état (chargement / erreur) et actions.
    private func pulseTab(url: URL) -> some View {
        PulseWebView(url: url, reloadToken: reloadToken) { event in
            switch event {
            case .started:
                loadState = .loading
                loadError = nil
            case .finished:
                loadState = .loaded
            case .failed(let message):
                loadState = .failed
                loadError = message
            case .httpStatus(let code):
                loadState = .failed
                loadError = "Réponse HTTP \(code)"
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .top) { statusBanner }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch loadState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Chargement de Pulse…").font(.footnote)
                Spacer()
                changeAddressButton
            }
            .padding(10)
            .background(.thinMaterial)
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Label("Impossible de charger Pulse", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).bold()
                    .foregroundStyle(.orange)
                if let loadError {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(loadedURL?.absoluteString ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack {
                    Button("Recharger") { reloadToken += 1 }
                        .buttonStyle(.borderedProminent)
                    changeAddressButton
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
        case .loaded:
            EmptyView()
        }
    }

    private var changeAddressButton: some View {
        Button("Changer l'adresse") {
            loadedURL = nil
            loadState = .loading
            loadError = nil
        }
        .font(.footnote)
    }

    // Incrément 0 : saisie de l'adresse de Pulse (rien n'est codé en dur).
    private var setupForm: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("bridge-connect")
                .font(.title2).bold()
            Text("Adresse de Pulse (Tailscale)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("https://pulse.<tailnet>.ts.net", text: $pulseURLString)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Ouvrir Pulse", action: openPulse)
                .buttonStyle(.borderedProminent)
                .disabled(!isValidURL(pulseURLString))
        }
        .padding()
    }

    private func isValidURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return URL(string: trimmed)?.scheme != nil
    }

    private func openPulse() {
        let trimmed = pulseURLString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme != nil else { return }
        PulseConfig.baseURL = url
        loadState = .loading
        loadError = nil
        reloadToken += 1
        loadedURL = url
    }
}

#Preview {
    ContentView()
}
