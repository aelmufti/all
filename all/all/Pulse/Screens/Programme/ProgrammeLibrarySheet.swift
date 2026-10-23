//
//  ProgrammeLibrarySheet.swift
//  all (bridge-connect)
//
//  Sheet de bibliothèque d'un domaine — liste des programmes catalogués
//  (`domain.choices`), avec sélection des jours pour ceux qui en ont besoin
//  (entraînement, sommeil). Miroir simplifié du sheet `picking` Angular :
//  pas de sous-écran de rapprochement d'activités (`candidates`), l'essentiel
//  étant de pouvoir démarrer/arrêter un programme depuis le téléphone (cf.
//  `ProgrammeViewModel` pour la même remarque côté actions).
//

import SwiftUI

struct ProgrammeLibrarySheet: View {
    let domain: ProgrammeDomainView
    let isBusy: Bool
    /// Jours proposés d'après les habitudes pour un nombre de séances donné.
    let suggest: (Int) -> ProgrammeDaySuggestion
    let loadHabits: () async -> Void
    let onActivate: (String, [Int]) -> Void
    let onStop: () -> Void

    @State private var picking: ProgrammeChoice?
    @State private var pickedDays: Set<Int> = []

    private static let workDays = [1, 2, 3, 4, 5]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let choice = picking {
                        pickingSection(choice)
                    } else {
                        ForEach(Array(domain.choices.enumerated()), id: \.element.id) { index, choice in
                            if index > 0 { ProgrammeHairline() }
                            ProgrammeChoiceRow(
                                choice: choice,
                                meta: choiceMeta(choice),
                                isActive: domain.active?.programmeId == choice.id,
                                isBusy: isBusy,
                                onBegin: { begin(choice) },
                                onStop: onStop
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color.pulseBackground)
            .task { if domain.kind == .training { await loadHabits() } }
            .navigationTitle(domain.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if picking != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Retour") { picking = nil }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pickingSection(_ choice: ProgrammeChoice) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(choice.name)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.pulseTextPrimary)
            if domain.kind == .sleep {
                VStack(alignment: .leading, spacing: 12) {
                    ProgrammeLabel("Réveil imposé")
                    ProgrammeDayPicker(order: programmeDayPickerOrder, picked: $pickedDays)
                }
            } else {
                ProgrammeDaysSelector(
                    perWeek: choice.perWeek, suggestion: suggest(choice.perWeek), picked: $pickedDays)
            }
            Button("Commencer") {
                onActivate(choice.id, pickedDays.sorted())
                picking = nil
            }
            .buttonStyle(.programmePrimary)
            .disabled(isBusy || (domain.kind == .training && pickedDays.count < choice.perWeek))
        }
        .padding(.top, 16)
    }

    private func begin(_ choice: ProgrammeChoice) {
        switch domain.kind {
        case .nutrition:
            onActivate(choice.id, [])
        case .sleep:
            let existing = domain.active?.days ?? []
            pickedDays = Set(existing.isEmpty ? Self.workDays : existing)
            picking = choice
        case .training:
            pickedDays = Set(suggest(choice.perWeek).days)
            picking = choice
        }
    }

    private func choiceMeta(_ choice: ProgrammeChoice) -> String {
        switch domain.kind {
        case .nutrition: return "\(choice.rules) cibles par jour"
        case .sleep: return "\(choice.rules) critères sur 14 nuits"
        case .training: return "\(choice.weeks) semaines"
        }
    }
}

private struct ProgrammeChoiceRow: View {
    let choice: ProgrammeChoice
    let meta: String
    let isActive: Bool
    let isBusy: Bool
    let onBegin: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(choice.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.pulseTextPrimary)
                Text(choice.goal)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.pulseTextSecondary)
                Text("\(meta) · \(choice.source)")
                    .font(.programmeMono(10))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isActive {
                Button("Arrêter", role: .destructive, action: onStop)
                    .buttonStyle(.programmeDestructiveText)
                    .disabled(isBusy)
            } else {
                Button("Commencer", action: onBegin)
                    .buttonStyle(.programmeText)
                    .disabled(isBusy)
            }
        }
        .padding(.vertical, 14)
    }
}
