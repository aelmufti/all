//
//  ProgrammeAbout.swift
//  all (bridge-connect)
//
//  Fiche « À propos » d'un programme actif (feuille ouverte par le bouton ⓘ
//  des pages de détail) : objectif, source, notes, et selon le domaine les
//  focus semaine par semaine (entraînement) ou les critères détaillés avec
//  bandes de risque et preuves (sommeil). En bas, l'arrêt du programme.
//

import SwiftUI

/// Ajoute le bouton ⓘ et la feuille « À propos » à une page de détail.
private struct ProgrammeAboutModifier: ViewModifier {
    let kind: ProgrammeKind
    var viewModel: ProgrammeViewModel
    @State private var showAbout = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAbout = true } label: { Image(systemName: "info.circle") }
                        .tint(Color.pulseAccent)
                }
            }
            .sheet(isPresented: $showAbout) {
                ProgrammeAboutView(kind: kind, viewModel: viewModel)
            }
    }
}

extension View {
    func programmeAbout(kind: ProgrammeKind, viewModel: ProgrammeViewModel) -> some View {
        modifier(ProgrammeAboutModifier(kind: kind, viewModel: viewModel))
    }
}

struct ProgrammeAboutView: View {
    let kind: ProgrammeKind
    var viewModel: ProgrammeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmStop = false

    private var domain: ProgrammeDomainView? { viewModel.domains.first { $0.kind == kind } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let domain, let active = domain.active {
                    VStack(alignment: .leading, spacing: 28) {
                        presentation(active)
                        switch domain.detail {
                        case .training(let detail): focusCard(detail, active: active)
                        case .sleep(let detail): criteriaCard(detail, domain: domain)
                        default: EmptyView()
                        }
                        Button("Arrêter le programme", role: .destructive) { confirmStop = true }
                            .buttonStyle(.programmeDestructiveText)
                            .frame(maxWidth: .infinity)
                            .disabled(viewModel.isBusy)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background(Color.pulseBackground)
            .navigationTitle("À propos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton { dismiss() } }
            .confirmationDialog("Arrêter ce programme ?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Arrêter le programme", role: .destructive) {
                    Task {
                        await viewModel.stop(kind)
                        dismiss()
                    }
                }
            }
        }
    }

    private func presentation(_ active: ProgrammeActive) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(active.name)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.pulseTextPrimary)
            Text(active.goal)
                .font(.system(size: 15))
                .foregroundStyle(Color.pulseTextPrimary)
            Text(active.source)
                .font(.programmeMono(11))
                .foregroundStyle(Color.pulseTextSecondary)
            ForEach(active.notes, id: \.self) { note in
                Text(note)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.pulseTextSecondary)
                    .lineSpacing(3)
            }
        }
    }

    /// Focus de chaque semaine du bloc.
    @ViewBuilder
    private func focusCard(_ detail: ProgrammeTrainingDetail, active: ProgrammeActive) -> some View {
        let focuses = detail.focus.filter { $0.focus != nil }
        if !focuses.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(focuses.enumerated()), id: \.element.index) { index, week in
                    if index > 0 { ProgrammeHairline() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("S\(week.index)")
                            .font(.programmeMono(12, weight: .semibold))
                            .foregroundStyle(Color.pulseTextPrimary)
                            .frame(width: 32, alignment: .leading)
                        Text(week.focus ?? "")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    .padding(.vertical, 11)
                }
            }
        }
    }

    /// Chaque critère : libellé · détail, cible, bande de risque, preuve.
    private func criteriaCard(_ detail: ProgrammeSleepDetail, domain: ProgrammeDomainView) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(detail.metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 { ProgrammeHairline() }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(metric.label) · \(metric.detail)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.pulseTextPrimary)
                    Text(programmeSleepTargetText(metric))
                        .font(.programmeMono(11))
                        .foregroundStyle(Color.pulseTextSecondary)
                    if !metric.informative, let band = metric.band {
                        Text("\(band.label) · \(band.risk)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    if let note = metric.note {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    Text(metric.evidence)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            }
            ProgrammeHairline()
            Text(programmeWorkDaysLabel(domain))
                .font(.programmeMono(11))
                .foregroundStyle(Color.pulseTextSecondary)
                .padding(.top, 12)
        }
    }
}
