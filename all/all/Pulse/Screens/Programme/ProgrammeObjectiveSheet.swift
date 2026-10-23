//
//  ProgrammeObjectiveSheet.swift
//  all (bridge-connect)
//
//  Choix par objectif : étape 1 = trois cartes (Sèche, Maintien, Masse sèche),
//  étape 2 = jours d'entraînement puis « Commencer », qui active la paire
//  entraînement + alimentation. « Programmes un par un » ouvre la
//  bibliothèque par domaine (sommeil, debug, combinaison libre).
//

import SwiftUI

struct ProgrammeObjectiveSheet: View {
    var viewModel: ProgrammeViewModel
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(ProgrammeObjective.all.enumerated()), id: \.element.id) { index, objective in
                        if index > 0 { ProgrammeHairline() }
                        objectiveRow(objective)
                    }
                    ProgrammeHairline()
                    Menu {
                        ForEach(viewModel.domains) { domain in
                            Button(domain.label) {
                                viewModel.showObjectives = false
                                viewModel.openLibrary(for: domain.kind)
                            }
                        }
                    } label: {
                        Text("Programmes un par un")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.pulseTextSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .padding(.top, 12)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color.pulseBackground)
            .navigationTitle("Objectif")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton { onClose() } }
            .navigationDestination(for: ProgrammeObjective.self) { objective in
                if let choices = programmeObjectiveChoices(objective, domains: viewModel.domains) {
                    ProgrammeObjectiveDaysStep(
                        objective: objective, choices: choices, viewModel: viewModel, onClose: onClose)
                }
            }
        }
    }

    @ViewBuilder
    private func objectiveRow(_ objective: ProgrammeObjective) -> some View {
        let choices = programmeObjectiveChoices(objective, domains: viewModel.domains)
        let isActive = programmeActiveObjective(domains: viewModel.domains) == objective
        let row = HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(objective.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.pulseTextPrimary)
                Text(objective.tagline)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.pulseTextSecondary)
                if let choices {
                    Text("\(choices.training.perWeek) séances · \(choices.training.weeks) sem.")
                        .font(.programmeMono(11))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isActive {
                ProgrammeCheckbox(checked: true)
            } else {
                ProgrammeChevron()
            }
        }
        .padding(.vertical, 18)
        .contentShape(Rectangle())
        if choices != nil {
            NavigationLink(value: objective) { row }.buttonStyle(.plain)
        } else {
            row.opacity(0.4)
        }
    }
}

/// Étape 2 : jours + « Commencer ».
private struct ProgrammeObjectiveDaysStep: View {
    let objective: ProgrammeObjective
    let choices: ProgrammeObjectiveChoices
    var viewModel: ProgrammeViewModel
    let onClose: () -> Void

    @State private var picked: Set<Int> = []

    var body: some View {
        let perWeek = choices.training.perWeek
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ProgrammeDaysSelector(
                    perWeek: perWeek, suggestion: viewModel.daySuggestion(perWeek: perWeek), picked: $picked)
                if let message = viewModel.actionError {
                    Text(message).font(.footnote).foregroundStyle(Color.pulseDanger)
                }
                Button("Commencer") {
                    Task {
                        if await viewModel.activateObjective(choices, days: picked.sorted()) { onClose() }
                    }
                }
                .buttonStyle(.programmePrimary)
                .disabled(viewModel.isBusy || picked.count < perWeek)
            }
            .padding(16)
        }
        .background(Color.pulseBackground)
        .navigationTitle(objective.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            picked = Set(viewModel.daySuggestion(perWeek: perWeek).days)
            await viewModel.loadHabitsIfNeeded()
        }
    }
}
