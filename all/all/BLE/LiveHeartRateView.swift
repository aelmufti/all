//
//  LiveHeartRateView.swift
//  all (bridge-connect)
//
//  Vue « FC en direct » (incrément Live-1a) : affiche la fréquence cardiaque
//  telle que publiée par `BLEManager.liveHeartRate`, sans aucun réseau — un
//  affichage natif du profil Bluetooth standard, indépendant de la WebView
//  Pulse et du protocole GFDI.
//
//  L'abonnement BLE ne vit que tant que cette vue est à l'écran : `onAppear`
//  démarre (`startLiveHeartRate`), `onDisappear` arrête
//  (`stopLiveHeartRate`) — le capteur optique de la montre ne doit pas
//  tourner pour un onglet qu'on ne regarde pas.
//

import SwiftUI

struct LiveHeartRateView: View {
    @ObservedObject private var ble = BLEManager.shared
    @State private var isPulsing = false

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                content
                Spacer()
            }
            .padding()
            .navigationTitle("FC en direct")
        }
        // La mesure + le push ne sont plus pilotés ici (onAppear/onDisappear) mais
        // par le cycle de vie de l'app (`allApp.swift`, scenePhase) : quitter cet
        // onglet pour regarder « Maintenant » dans Pulse ne doit PAS couper le flux.
        // Cette vue ne fait qu'afficher l'état publié par `BLEManager.liveHeartRate`.
    }

    @ViewBuilder
    private var content: some View {
        if ble.connectionState != .connected && ble.connectionState != .reconnecting {
            statusCard(
                icon: "antenna.radiowaves.left.and.right.slash",
                tint: .secondary,
                title: "Montre déconnectée",
                message: "Connecte la montre depuis l'onglet BLE pour voir la fréquence cardiaque en direct."
            )
        } else {
            let reading = ble.liveHeartRate
            if reading.stale {
                // Périmé : le souci n'est pas dans les menus de la montre,
                // donc pas de conseil ici (cf. LiveHeartRate.Engine.reading).
                statusCard(
                    icon: "wifi.slash",
                    tint: .orange,
                    title: "Lien silencieux",
                    message: "Aucune trame reçue depuis un moment. Vérifie que la montre est toujours à portée."
                )
            } else if reading.broadcasting, let bpm = reading.heartRate {
                bpmCard(bpm)
            } else if let hint = reading.hint {
                statusCard(
                    icon: "heart.slash",
                    tint: .orange,
                    title: "Diffusion FC désactivée",
                    message: hint
                )
            } else {
                statusCard(
                    icon: "heart",
                    tint: .secondary,
                    title: "En attente de la montre…",
                    message: "Abonnement actif, première trame pas encore reçue."
                )
            }
        }
    }

    private func bpmCard(_ bpm: Int) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "heart.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
                .scaleEffect(isPulsing ? 1.15 : 1.0)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }
                .onDisappear { isPulsing = false }
            Text("\(bpm)")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("battements / minute")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func statusCard(icon: String, tint: Color, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

#Preview {
    LiveHeartRateView()
}
