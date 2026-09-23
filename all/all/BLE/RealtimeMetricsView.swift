//
//  RealtimeMetricsView.swift
//  all (bridge-connect)
//
//  Vue « Temps réel » (Live-2, seul onglet FC désormais — Live-1a/0x2A37
//  retiré) : valeurs live pour les métriques `REALTIME_*` au décodeur connu
//  (FC, pas, SpO2, respiration, VFC), **toujours actives** tant que l'app est
//  au premier plan et la montre connectée (`RealtimeSession.enableKnownMetrics`,
//  pilotée par `BLEManager.startRealtime`/`stopRealtime` — plus de toggle
//  manuel pour elles), et une section « Capture » pour les services au format
//  inconnu (stress, body battery, calories, intensité) — cf.
//  `all/docs/live2-realtime-design.md` §2 et `RealtimeSession.swift`. Aucun
//  réseau ici : affichage natif uniquement (le push Pulse de la FC est géré
//  séparément par `BLEManager.handleRealtimeHeartRate`).
//
//  La section Capture reste un mode DEBUG explicite à toggle manuel (jamais
//  actif par défaut) : activer « capturer » journalise les octets bruts du
//  service dans Console.app (subsystem "CleanYourRoom.all", catégorie
//  "gfdi-realtime") — aucune valeur n'est décodée ni affichée ici pour ces
//  quatre métriques, cf. `RealtimeSession.setCaptureEnabled`.
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

    /// Métriques connues affichées ici, **toujours actives** (cf.
    /// `RealtimeSession.enableKnownMetrics`, plus de toggle manuel pour
    /// elles) — FC en tête : elle remplace l'ancien onglet FC dédié (Live-1a,
    /// profil BLE standard 0x2A37, retiré — instable, la montre coupait sa
    /// diffusion d'elle-même). L'accéléromètre a aussi un décodeur
    /// (`hasKnownDecoder == true`) mais reste hors UI : 3 échantillons x/y/z
    /// par trame (~26 Hz) n'ont pas de représentation native pertinente à ce
    /// stade — décision produit différée, pas une limite technique.
    private let knownMetrics: [RealtimeMlService] = [.heartRate, .steps, .spo2, .respiration, .hrv]

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

    /// Plus de toggle : les métriques connues sont toujours actives (cf.
    /// commentaire de `knownMetrics`) — cette ligne se contente d'afficher le
    /// libellé et la dernière valeur reçue (ou « en attente… » tant
    /// qu'aucune trame n'est encore arrivée sur ce lien).
    @ViewBuilder
    private func knownRow(_ service: RealtimeMlService) -> some View {
        HStack {
            if service == .heartRate {
                Label(label(for: service), systemImage: "heart.fill")
                    .foregroundStyle(.red)
            } else {
                Text(label(for: service))
            }
            Spacer()
            Text(valueDescription(for: service))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
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

    private func captureBinding(for service: RealtimeMlService) -> Binding<Bool> {
        Binding(
            get: { session.captureEnabled.contains(service) },
            set: { session.setCaptureEnabled($0, for: service) }
        )
    }

    private func label(for service: RealtimeMlService) -> String {
        switch service {
        case .heartRate: return "Fréquence cardiaque"
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
        case .heartRate:
            guard let heartRate = session.heartRate, heartRate.isValid else { return "en attente…" }
            return "\(heartRate.heartRate) bpm"
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
