//
//  SystemMenuView.swift
//  all (bridge-connect)
//
//  Vue « Montre » — section collecteur BLE iOS (Diagnostic + Temps réel),
//  propre à bridge-connect (sans équivalent web). Elle est présentée depuis
//  l'écran **Paramètres** (`SettingsView`) sous le mode « iPhone (BLE) »
//  uniquement (« Collecteur (Montre) ») : c'est le mode où cette app collecte.
//  L'ancien menu intermédiaire (`SystemMenuView`) et la section « Système »
//  fourre-tout (qui réunissait Statut + Montre) ont été retirés — chaque entrée
//  vit désormais sous son mode de connectivité (Statut du pont sous « bridge »).
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
