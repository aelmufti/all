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
                    VStack(alignment: .leading, spacing: PulseSpacing.md) {
                        presentation(active)
                        switch domain.detail {
                        case .training(let detail): focusCard(detail, active: active)
                        case .sleep(let detail): criteriaCard(detail, domain: domain)
                        default: EmptyView()
                        }
                        Button("Arrêter le programme", role: .destructive) { confirmStop = true }
                            .buttonStyle(.pulseSecondary)
                            .disabled(viewModel.isBusy)
                    }
                    .padding(PulseSpacing.lg)
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
        PulseCard {
            Text(active.name).font(.system(size: 17, weight: .semibold))
            Text(active.goal).font(.subheadline)
            Text(active.source)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color.pulseTextSecondary)
            ForEach(active.notes, id: \.self) { note in
                Text(note).font(.system(size: 14))
            }
        }
    }

    /// Focus de chaque semaine du bloc.
    @ViewBuilder
    private func focusCard(_ detail: ProgrammeTrainingDetail, active: ProgrammeActive) -> some View {
        let focuses = detail.focus.filter { $0.focus != nil }
        if !focuses.isEmpty {
            PulseCard {
                ForEach(focuses, id: \.index) { week in
                    HStack(alignment: .firstTextBaseline, spacing: PulseSpacing.sm) {
                        Text("S\(week.index)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(width: 28, alignment: .leading)
                        Text(week.focus ?? "").font(.footnote)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }
            }
        }
    }

    /// Chaque critère : libellé · détail, cible, bande de risque, preuve.
    private func criteriaCard(_ detail: ProgrammeSleepDetail, domain: ProgrammeDomainView) -> some View {
        PulseCard {
            VStack(alignment: .leading, spacing: PulseSpacing.md) {
                ForEach(detail.metrics) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(metric.label) · \(metric.detail)")
                            .font(.system(size: 13, weight: .semibold))
                        Text(programmeSleepTargetText(metric))
                            .font(.system(size: 11, design: .rounded))
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
                }
            }
            Divider()
            Text(programmeWorkDaysLabel(domain))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}
