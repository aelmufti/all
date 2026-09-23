//
//  PlusView.swift
//  all (bridge-connect)
//
//  Hub « Plus » : point d'entrée vers les écrans Pulse qui n'ont pas leur
//  propre onglet primaire (Tableau de bord, Programme, Rapport SpO2,
//  Paramètres, Statut). Correspond au `case .plus` de `PulseShellView`.
//
//  Choix de présentation : chacun de ces écrans est **auto-suffisant** et
//  possède déjà sa propre `NavigationStack` (cf. `SettingsView`, `StatusView`,
//  `ProgrammeView`, `Spo2ReportView` ; `DashboardView` est une vue simple).
//  Les pousser via `NavigationLink` depuis un stack parent empilerait deux
//  barres de navigation. On les présente donc en **feuille** (`.sheet`,
//  pleine hauteur, fermeture par glissement) — motif iOS courant pour un menu
//  « Plus », et qui n'exige de modifier aucun de ces écrans.
//

import SwiftUI

struct PlusView: View {
    /// Destinations du hub. `Identifiable` pour piloter `.sheet(item:)`.
    private enum Destination: String, Identifiable, CaseIterable {
        case dashboard
        case programme
        case spo2
        case settings
        case status

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dashboard: return "Tableau de bord"
            case .programme: return "Programme"
            case .spo2: return "Rapport SpO2"
            case .settings: return "Paramètres"
            case .status: return "Statut"
            }
        }

        var systemImage: String {
            switch self {
            case .dashboard: return "chart.bar.xaxis"
            case .programme: return "calendar"
            case .spo2: return "lungs.fill"
            case .settings: return "gearshape.fill"
            case .status: return "dot.radiowaves.up.forward"
            }
        }
    }

    @State private var destination: Destination?

    var body: some View {
        NavigationStack {
            List {
                ForEach(Destination.allCases) { destination in
                    Button {
                        self.destination = destination
                    } label: {
                        Label(destination.title, systemImage: destination.systemImage)
                            .foregroundStyle(Color.pulseTextPrimary)
                    }
                }
            }
            .navigationTitle("Plus")
        }
        .sheet(item: $destination) { destination in
            switch destination {
            case .dashboard: DashboardView()
            case .programme: ProgrammeView()
            case .spo2: Spo2ReportView()
            case .settings: SettingsView()
            case .status: StatusView()
            }
        }
    }
}

#Preview {
    PlusView()
}
