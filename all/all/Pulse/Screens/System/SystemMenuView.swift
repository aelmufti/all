//
//  SystemMenuView.swift
//  all (bridge-connect)
//
//  Feuille « Montre » : présente `SettingsWatchPage` dans sa propre pile de
//  navigation, avec une sortie explicite. Utilisée hors Paramètres (Accueil,
//  Onboarding) ; dans les Paramètres, la page est poussée directement.
//

import SwiftUI

struct WatchSectionView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsWatchPage()
                .toolbar { SheetCloseButton { dismiss() } }
        }
        .tint(Color.pulseAccent)
    }
}

#Preview {
    WatchSectionView()
}
