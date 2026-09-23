//
//  RealtimeMetricsView.swift
//  all (bridge-connect)
//
//  Vue « Temps réel » (Live-2) : toggles + valeurs live pour les métriques
//  `REALTIME_*` au décodeur connu (pas, SpO2, respiration, VFC), et une section
//  « Capture » pour les services au format inconnu (stress, body battery,
//  calories, intensité) — cf. `all/docs/live2-realtime-design.md` §2 et
//  `RealtimeSession.swift`. Aucun réseau ici : affichage natif uniquement,
//  comme `LiveHeartRateView` (Live-1a).
//
//  La section Capture est un mode DEBUG explicite (jamais actif par défaut) :
//  activer un toggle « capturer » journalise les octets bruts du service dans
//  Console.app (subsystem "CleanYourRoom.all", catégorie "gfdi-realtime") —
//  aucune valeur n'est décodée ni affichée ici pour ces quatre métriques, cf.
//  `RealtimeSession.setCaptureEnabled`.
//

import SwiftUI

struct RealtimeMetricsView: View {
    @ObservedObject private var ble = BLEManager.shared

    var body: some View {
        NavigationStack {
            Group {
                if let session = ble.realtimeSession {
                    RealtimeMetricsList(session: session)
                } else {
                    disconnectedCard
                }
            }
            .navigationTitle("Temps réel")
        }
    }

    private var disconnectedCard: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Montre déconnectée")
                .font(.headline)
            Text("Connecte la montre (protocole GFDI V2) depuis l'onglet BLE pour activer les métriques temps réel.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// `@ObservedObject` dédié (même raison que `GarminDirectorySection` dans
/// `BLEDiagnosticView.swift`) : `RealtimeMetricsView` n'observe que
/// `BLEManager`, et le remplacement de `realtimeSession` (nouveau lien) ne
/// republie pas les mutations internes d'une session déjà en place.
private struct RealtimeMetricsList: View {
    @ObservedObject var session: RealtimeSession

    /// Seules ces quatre métriques connues ont un toggle ici — cf. tâche Live-2
    /// (« toggles par métrique connue (pas, SpO2, respiration, VFC) »). La FC
    /// GFDI et l'accéléromètre ont aussi un décodeur (`hasKnownDecoder == true`,
    /// `RealtimeSession` sait les décoder), mais restent hors UI pour l'instant :
    /// la FC fait doublon avec Live-1a (profil BLE standard, déjà affiché dans
    /// l'onglet FC), et l'accéléromètre (3 échantillons x/y/z par trame, ~26 Hz)
    /// n'a pas de représentation native pertinente à ce stade — décision produit
    /// différée, pas une limite technique.
    private let knownMetrics: [RealtimeMlService] = [.steps, .spo2, .respiration, .hrv]

    /// Cf. doc §2.2 : aucun décodeur connu nulle part dans l'écosystème pour ces
    /// quatre — capture seule possible.
    private let opaqueMetrics: [RealtimeMlService] = [.stress, .bodyBattery, .calories, .intensity]

    var body: some View {
        List {
            Section("Métriques connues") {
                ForEach(knownMetrics, id: \.self) { service in
                    knownRow(service)
                }
            }
            Section {
                Label("Mode capture — debug", systemImage: "ladybug.fill")
                    .font(.subheadline).bold()
                    .foregroundStyle(.orange)
                Text("Format inconnu : ces services journalisent leurs octets bruts en local (Console.app, subsystem « CleanYourRoom.all », catégorie « gfdi-realtime ») tant que leur toggle est actif — aucun réseau, aucun décodage. Réservé à la rétro-ingénierie de leur format, matériel en main.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Capture (services opaques)") {
                ForEach(opaqueMetrics, id: \.self) { service in
                    captureRow(service)
                }
            }
        }
    }

    @ViewBuilder
    private func knownRow(_ service: RealtimeMlService) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(label(for: service), isOn: binding(for: service))
            if session.enabledServices.contains(service) {
                Text(valueDescription(for: service))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func captureRow(_ service: RealtimeMlService) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Capturer « \(label(for: service)) »", isOn: captureBinding(for: service))
            if session.captureEnabled.contains(service) {
                HStack(spacing: 4) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text("\(session.captureFrameCounts[service] ?? 0) trame(s) capturée(s) — voir Console.app")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func binding(for service: RealtimeMlService) -> Binding<Bool> {
        Binding(
            get: { session.enabledServices.contains(service) },
            set: { session.setEnabled($0, for: service) }
        )
    }

    private func captureBinding(for service: RealtimeMlService) -> Binding<Bool> {
        Binding(
            get: { session.captureEnabled.contains(service) },
            set: { session.setCaptureEnabled($0, for: service) }
        )
    }

    private func label(for service: RealtimeMlService) -> String {
        switch service {
        case .heartRate: return "Fréquence cardiaque (GFDI)"
        case .steps: return "Pas"
        case .calories: return "Calories"
        case .intensity: return "Intensité"
        case .hrv: return "VFC / RR"
        case .stress: return "Stress"
        case .accelerometer: return "Accéléromètre"
        case .spo2: return "SpO2"
        case .bodyBattery: return "Body Battery"
        case .respiration: return "Respiration"
        }
    }

    private func valueDescription(for service: RealtimeMlService) -> String {
        switch service {
        case .steps:
            guard let steps = session.steps else { return "en attente…" }
            let delta = session.stepsDelta.map { " (Δ \($0))" } ?? ""
            return "\(steps.steps) / \(steps.goal)\(delta)"
        case .spo2:
            guard let spo2 = session.spo2 else { return "en attente…" }
            return spo2.isValid ? "\(spo2.rawValue) %" : "valeur invalide"
        case .respiration:
            guard let respiration = session.respiration else { return "en attente…" }
            return "\(respiration.breathsPerMinute) /min"
        case .hrv:
            guard let hrv = session.hrv else { return "en attente…" }
            return "RR=\(hrv.rrIntervalRaw) unk=\(hrv.unknown)"
        default:
            return "—"
        }
    }
}

#Preview {
    RealtimeMetricsView()
}
