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
                VStack(spacing: PulseSpacing.md) {
                    ForEach(ProgrammeObjective.all) { objective in
                        objectiveCard(objective)
                    }
                    Menu {
                        ForEach(viewModel.domains) { domain in
                            Button(domain.label) {
                                viewModel.showObjectives = false
                                viewModel.openLibrary(for: domain.kind)
                            }
                        }
                    } label: {
                        Text("Programmes un par un")
                            .font(.footnote)
                            .foregroundStyle(Color.pulseTextSecondary)
                            .padding(.vertical, PulseSpacing.sm)
                    }
                }
                .padding(PulseSpacing.lg)
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
    private func objectiveCard(_ objective: ProgrammeObjective) -> some View {
        let choices = programmeObjectiveChoices(objective, domains: viewModel.domains)
        let isActive = programmeActiveObjective(domains: viewModel.domains) == objective
        let card = PulseCard {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(objective.name).font(.system(size: 20, weight: .semibold))
                    Text(objective.tagline)
                        .font(.subheadline)
                        .foregroundStyle(Color.pulseTextSecondary)
                    if let choices {
                        Text("\(choices.training.perWeek) séances · \(choices.training.weeks) sem.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.pulseSuccess)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.pulseAbsent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.pulseTextPrimary)
        }
        if choices != nil {
            NavigationLink(value: objective) { card }.buttonStyle(.plain)
        } else {
            card.opacity(0.4)
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
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
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
                .buttonStyle(PulseButtonStyle(kind: .primary))
                .tint(Color.pulseAccent)
                .disabled(viewModel.isBusy || picked.count < perWeek)
            }
            .padding(PulseSpacing.lg)
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
