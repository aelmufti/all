//
//  ProgrammeBravoView.swift
//  all (bridge-connect)
//
//  Écran de fin de programme d'entraînement : bilan des séances. Présenté en
//  plein écran, une fois à la fin du bloc puis à la demande (« Bilan »).
//

import SwiftUI

struct ProgrammeBravoView: View {
    let active: ProgrammeActive
    let bilan: ProgrammeBilan
    let isBusy: Bool
    let onRestart: () -> Void
    let onChooseOther: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                ProgrammeCard(spacing: 20) {
                    HStack(alignment: .lastTextBaseline) {
                        HStack(alignment: .lastTextBaseline, spacing: 10) {
                            ProgrammeBigNumber(value: "\(bilan.done)", total: "\(bilan.planned)")
                            Text("séances")
                                .font(.programmeMono(11))
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                        Spacer()
                        if let percent = bilan.percent {
                            Text("\(percent) %")
                                .font(.programmeMono(17, weight: .semibold))
                                .foregroundStyle(Color.pulseTextPrimary)
                        }
                    }
                    weekBars
                }
                VStack(spacing: 0) {
                    statRow("Meilleure série", "\(bilan.bestStreak) semaine\(bilan.bestStreak > 1 ? "s" : "")")
                    ProgrammeHairline()
                    statRow("Hors programme", "\(bilan.extras)")
                }
                .padding(.horizontal, 2)
                VStack(spacing: 0) {
                    Button("Relancer le bloc", action: onRestart)
                        .buttonStyle(.programmePrimary)
                        .disabled(isBusy)
                    Button("Choisir un autre objectif", action: onChooseOther)
                        .buttonStyle(.programmeText)
                    Button("Fermer", action: onClose)
                        .buttonStyle(.programmeText)
                }
            }
            .padding(16)
        }
        .background(Color.pulseBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bravo")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.pulseTextPrimary)
            Text(active.name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.pulseTextPrimary)
            Text(period)
                .font(.programmeMono(11))
                .foregroundStyle(Color.pulseTextSecondary)
        }
        .padding(.top, 24)
    }

    private var period: String {
        let start = ProgrammeDate.shortLabel(active.startedOn)
        guard let end = bilan.endDate else { return start }
        return "\(start) → \(ProgrammeDate.shortLabel(end))"
    }

    private var weekBars: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(bilan.weeks) { week in
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.pulseSurfaceAlt)
                        if week.planned > 0 {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.pulseTextPrimary)
                                .frame(height: 48 * CGFloat(week.done) / CGFloat(week.planned))
                        }
                    }
                    .frame(height: 48)
                    Text("\(week.week)")
                        .font(.programmeMono(10))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Semaine \(week.week) : \(week.done) sur \(week.planned)")
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Color.pulseTextSecondary)
            Spacer()
            Text(value)
                .font(.programmeMono(14, weight: .semibold))
                .foregroundStyle(Color.pulseTextPrimary)
        }
        .padding(.vertical, 13)
    }
}

// MARK: - Présentation partagée (écran Programme + détail entraînement)

private struct ProgrammeBravoCover: ViewModifier {
    @Binding var isPresented: Bool
    var viewModel: ProgrammeViewModel

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented) {
            if let domain = viewModel.trainingDomain,
               let active = domain.active,
               case .training(let detail) = domain.detail {
                ProgrammeBravoView(
                    active: active,
                    bilan: programmeBilan(
                        weeks: active.weeks,
                        startedOn: active.startedOn,
                        sessions: detail.sessions,
                        extras: detail.extras ?? []
                    ),
                    isBusy: viewModel.isBusy,
                    onRestart: {
                        Task {
                            await viewModel.restart(domain)
                            isPresented = false
                        }
                    },
                    onChooseOther: {
                        isPresented = false
                        Task {
                            // Laisser la couverture se refermer avant la feuille.
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            viewModel.openObjectives()
                        }
                    },
                    onClose: { isPresented = false }
                )
            }
        }
    }
}

extension View {
    func programmeBravoCover(isPresented: Binding<Bool>, viewModel: ProgrammeViewModel) -> some View {
        modifier(ProgrammeBravoCover(isPresented: isPresented, viewModel: viewModel))
    }
}
