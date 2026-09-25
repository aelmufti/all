//
//  SystemMenuView.swift
//  all (bridge-connect)
//
//  Vue « Montre » — section collecteur BLE iOS (Diagnostic + Temps réel),
//  propre à bridge-connect (sans équivalent web). Elle est désormais présentée
//  depuis l'écran **Paramètres** (`SettingsView`, section « Système »), qui
//  regroupe tout le secondaire iPhone (Statut + Montre) : la roue crantée de
//  l'Accueil ouvre directement Paramètres. L'ancien menu intermédiaire
//  (`SystemMenuView`) et l'entrée « Rapport SpO2 » (qui reste accessible depuis
//  l'écran Santé) ont été retirés.
//

import SwiftUI

/// Section « Montre » : les deux vues collecteur existantes (`BLEDiagnosticView`,
/// `RealtimeMetricsView`, définies dans `all/BLE/`) ont chacune leur propre
/// `NavigationStack` — un sélecteur segmenté au-dessus évite d'empiler deux
/// barres de navigation sans toucher aux deux vues.
struct WatchSectionView: View {
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
    WatchSectionView()
}
