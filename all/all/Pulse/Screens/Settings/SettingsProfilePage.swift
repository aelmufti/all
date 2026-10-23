//
//  SettingsProfilePage.swift
//  all (bridge-connect)
//
//  Page « Profil » : année de naissance et taille par sélecteurs, sexe en
//  segmenté. Pas de bouton « Enregistrer » — chaque changement s'enregistre seul
//  (~0,6 s après le dernier, cf. `SettingsViewModel.scheduleProfileSave`) et à la
//  sortie de la page. Retour haptique à la réussite ; l'erreur reste en pied.
//

import SwiftUI

struct SettingsProfilePage: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            SettingsProfileSection(viewModel: viewModel)
        }
        .navigationTitle("Profil")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { Task { await viewModel.flushProfileSave() } }
    }
}

private struct SettingsProfileSection: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Section {
            Picker("Année de naissance", selection: $viewModel.birthYear) {
                if viewModel.birthYear == nil { Text("—").tag(Int?.none) }
                ForEach(SettingsProfileOptions.birthYears(
                    currentYear: Calendar.current.component(.year, from: Date()),
                    including: viewModel.birthYear), id: \.self) { year in
                    Text(String(year)).tag(Int?.some(year))
                }
            }
            Picker("Taille", selection: $viewModel.heightCm) {
                if viewModel.heightCm == nil { Text("—").tag(Int?.none) }
                ForEach(SettingsProfileOptions.heights(including: viewModel.heightCm), id: \.self) { cm in
                    Text("\(cm) cm").tag(Int?.some(cm))
                }
            }
            Picker("Sexe", selection: Binding(get: { viewModel.sex }, set: { viewModel.setSex($0) })) {
                Text("Homme").tag(Optional("male"))
                Text("Femme").tag(Optional("female"))
            }
            .pickerStyle(.segmented)

            LabeledContent("Poids retenu", value: viewModel.profileWeightLabel)
        } footer: {
            if let profileError = viewModel.profileError {
                Text(profileError)
                    .foregroundStyle(Color.pulseDanger)
            }
        }
        .sensoryFeedback(.success, trigger: viewModel.profileSaveCount)
    }
}
