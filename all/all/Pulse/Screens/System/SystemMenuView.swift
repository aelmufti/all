//
//  SystemMenuView.swift
//  all (bridge-connect)
//
//  Menu « système » présenté en feuille depuis la roue crantée de l'Accueil.
//  Regroupe les fonctions **secondaires / propres à l'iPhone**, hors de la
//  barre d'onglets primaire (qui reproduit 1-1 la barre web à 6 destinations) :
//
//   • Paramètres      — écran `/parametres` (source de synchro, profil, compte)
//   • Statut          — écran `/statut` (lien BLE, synchro auto)
//   • Rapport SpO2    — écran `/rapport-spo2`
//   • Montre          — section collecteur BLE iOS (Diagnostic + Temps réel),
//                       propre à bridge-connect, sans équivalent web
//
//  Chaque destination est présentée en **feuille** (elle possède déjà sa propre
//  `NavigationStack`) avec une sortie explicite (`SheetCloseButton` / bouton
//  « Terminé ») — aucun écran ne doit pouvoir piéger l'utilisateur.
//

import SwiftUI

struct SystemMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var destination: Destination?

    private enum Destination: String, Identifiable, CaseIterable {
        case settings, status, spo2, watch
        var id: String { rawValue }

        var title: String {
            switch self {
            case .settings: return "Paramètres"
            case .status: return "Statut"
            case .spo2: return "Rapport SpO2"
            case .watch: return "Montre"
            }
        }

        var subtitle: String {
            switch self {
            case .settings: return "Source de synchro, profil, compte"
            case .status: return "Lien BLE, synchronisation automatique"
            case .spo2: return "Saturation nocturne, nuit par nuit"
            case .watch: return "Collecteur : diagnostic BLE, temps réel"
            }
        }

        var icon: String {
            switch self {
            case .settings: return "gearshape.fill"
            case .status: return "dot.radiowaves.up.forward"
            case .spo2: return "lungs.fill"
            case .watch: return "antenna.radiowaves.left.and.right"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Destination.allCases) { destination in
                    Button {
                        self.destination = destination
                    } label: {
                        HStack(spacing: PulseSpacing.md) {
                            Image(systemName: destination.icon)
                                .font(.system(size: 17))
                                .foregroundStyle(Color.pulseAccent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(destination.title)
                                    .font(.system(.body, weight: .medium))
                                    .foregroundStyle(Color.pulseTextPrimary)
                                Text(destination.subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(Color.pulseTextSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Système")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton { dismiss() } }
        }
        .sheet(item: $destination) { destination in
            switch destination {
            case .settings: SettingsView()
            case .status: StatusView()
            case .spo2: Spo2ReportView()
            case .watch: WatchSectionView()
            }
        }
    }
}

/// Section « Montre » : les deux vues collecteur existantes (`BLEDiagnosticView`,
/// `RealtimeMetricsView`, définies dans `all/BLE/`) ont chacune leur propre
/// `NavigationStack` — un sélecteur segmenté au-dessus évite d'empiler deux
/// barres de navigation sans toucher aux deux vues.
private struct WatchSectionView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Screen: String, CaseIterable, Identifiable {
        case diagnostic = "Diagnostic"
        case realtime = "Temps réel"
        var id: String { rawValue }
    }

    @State private var screen: Screen = .diagnostic

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Vue", selection: $screen) {
                    ForEach(Screen.allCases) { screen in
                        Text(screen.rawValue).tag(screen)
                    }
                }
                .pickerStyle(.segmented)
                .padding(PulseSpacing.md)

                Group {
                    switch screen {
                    case .diagnostic: BLEDiagnosticView()
                    case .realtime: RealtimeMetricsView()
                    }
                }
            }
            .background(Color.pulseBackground)
            .navigationTitle("Montre")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton { dismiss() } }
        }
    }
}

#Preview {
    SystemMenuView()
}
