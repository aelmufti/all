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
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                header
                PulseCard {
                    VStack(alignment: .leading, spacing: PulseSpacing.md) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(bilan.done)/\(bilan.planned)")
                                .font(.system(size: 34, weight: .semibold, design: .rounded))
                            Text("séances")
                                .foregroundStyle(Color.pulseTextSecondary)
                            Spacer()
                            if let percent = bilan.percent {
                                Text("\(percent) %")
                                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.pulseSuccess)
                            }
                        }
                        weekBars
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                PulseCard {
                    VStack(spacing: PulseSpacing.sm) {
                        statRow("Meilleure série", "\(bilan.bestStreak) semaine\(bilan.bestStreak > 1 ? "s" : "")")
                        statRow("Hors programme", "\(bilan.extras)")
                    }
                }
                VStack(spacing: PulseSpacing.sm) {
                    Button("Relancer le bloc", action: onRestart)
                        .buttonStyle(.pulsePrimary)
                        .disabled(isBusy)
                    Button("Choisir un autre objectif", action: onChooseOther)
                        .buttonStyle(.pulseSecondary)
                    Button("Fermer", action: onClose)
                        .buttonStyle(.pulseSecondary)
                }
            }
            .padding(PulseSpacing.lg)
        }
        .background(Color.pulseBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bravo")
                .font(.system(size: 40, weight: .bold, design: .rounded))
            Text(active.name)
                .font(.system(size: 17, weight: .semibold))
            Text(period)
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
        .padding(.top, PulseSpacing.xl)
    }

    private var period: String {
        let start = ProgrammeDate.shortLabel(active.startedOn)
        guard let end = bilan.endDate else { return start }
        return "\(start) → \(ProgrammeDate.shortLabel(end))"
    }

    private var weekBars: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(bilan.weeks) { week in
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.pulseSurfaceAlt)
                        if week.planned > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.pulseSuccess)
                                .frame(height: 48 * CGFloat(week.done) / CGFloat(week.planned))
                        }
                    }
                    .frame(height: 48)
                    Text("\(week.week)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Semaine \(week.week) : \(week.done) sur \(week.planned)")
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.pulseTextSecondary)
            Spacer()
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded))
        }
        .font(.subheadline)
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
