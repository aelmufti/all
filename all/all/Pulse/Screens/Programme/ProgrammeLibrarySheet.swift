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
            List {
                if let choice = picking {
                    pickingSection(choice)
                } else {
                    Section {
                        ForEach(domain.choices) { choice in
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
            }
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
        Section {
            if domain.kind == .sleep {
                Text("Réveil imposé")
                    .font(.subheadline.weight(.semibold))
                ProgrammeDayPicker(order: programmeDayPickerOrder, picked: $pickedDays)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, PulseSpacing.xs)
            } else {
                ProgrammeDaysSelector(
                    perWeek: choice.perWeek, suggestion: suggest(choice.perWeek), picked: $pickedDays)
            }
            Button("Commencer") {
                onActivate(choice.id, pickedDays.sorted())
                picking = nil
            }
            .disabled(isBusy || (domain.kind == .training && pickedDays.count < choice.perWeek))
        } header: {
            Text(choice.name)
        }
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
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.name).font(.subheadline.weight(.semibold))
                // Web `.pick-goal { font-size:13px }`.
                Text(choice.goal).font(.system(size: 13)).foregroundStyle(Color.pulseTextSecondary)
                Text("\(meta) · \(choice.source)")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Spacer()
            if isActive {
                Button("Arrêter", role: .destructive, action: onStop)
                    .buttonStyle(PulseButtonStyle(kind: .secondary, fullWidth: false))
                    .disabled(isBusy)
            } else {
                Button("Commencer", action: onBegin)
                    .buttonStyle(PulseButtonStyle(kind: .primary, fullWidth: false))
                    .tint(Color.pulseAccent)
                    .disabled(isBusy)
            }
        }
        .padding(.vertical, PulseSpacing.xs)
    }
}
