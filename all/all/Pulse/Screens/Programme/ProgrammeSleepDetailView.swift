//
//  ProgrammeSleepDetailView.swift
//  all (bridge-connect)
//
//  Détail « Sommeil » — critères tenus, frise des nuits et liste compacte
//  des critères (libellé, valeur, statut). Cibles, bandes de risque, preuves
//  et notes sont dans la fiche « À propos ».
//
//  La frise reprend les nuits (`strip`) en barres proportionnelles à
//  `sleepMin`, colorées jour travaillé/libre — pas le positionnement horaire
//  de l'actogramme web.
//

import SwiftUI

struct ProgrammeSleepDetailView: View {
    var viewModel: ProgrammeViewModel
    @Environment(\.dismiss) private var dismiss

    private var domain: ProgrammeDomainView? { viewModel.domains.first { $0.kind == .sleep } }

    var body: some View {
        ScrollView {
            if let domain, case .sleep(let detail) = domain.detail {
                VStack(alignment: .leading, spacing: 16) {
                    ProgrammeCard(spacing: 20) {
                        hero(detail)

                        if !detail.strip.isEmpty {
                            strip(detail)
                            legend
                        }

                        if let warning = programmeSleepStripWarning(detail) {
                            ProgrammeWarnBox(text: warning)
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(detail.metrics.enumerated()), id: \.element.id) { index, metric in
                                if index > 0 { ProgrammeHairline() }
                                metricRow(metric)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Color.pulseBackground)
        .navigationTitle(domain?.active?.name ?? "Sommeil")
        .navigationBarTitleDisplayMode(.inline)
        .programmeAbout(kind: .sleep, viewModel: viewModel)
        .onChange(of: domain?.active == nil) { _, stopped in if stopped { dismiss() } }
    }

    private func hero(_ detail: ProgrammeSleepDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgrammeBigNumber(
                value: detail.nights > 0 ? "\(detail.hits)" : "—", total: "\(detail.total)",
                dim: detail.nights == 0)
            Text("critères tenus · \(programmeSleepWindowLabel(detail))")
                .font(.programmeMono(11))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    private func strip(_ detail: ProgrammeSleepDetail) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(detail.strip) { night in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(night.workDay ? Color.pulseSleep : Color.pulseSleep.opacity(0.42))
                        .frame(height: max(4, CGFloat(night.sleepMin) / 8))
                    Text(ProgrammeDate.weekdayLetters[max(0, min(6, night.weekday))])
                        .font(.programmeMono(9))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("\(night.date) · \(programmeSleepDuration(night.sleepMin))"))
            }
        }
        .frame(height: 70, alignment: .bottom)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ProgrammeLegendItem(label: "jour travaillé", color: .pulseSleep)
            ProgrammeLegendItem(label: "jour libre", color: .pulseSleep.opacity(0.42))
        }
    }

    /// Libellé, valeur, statut — une rangée par critère.
    private func metricRow(_ metric: ProgrammeSleepMetric) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(metric.label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.pulseTextPrimary)
                HStack(spacing: 6) {
                    if !metric.informative {
                        Circle().fill(programmeSleepMarkerColor(metric)).frame(width: 6, height: 6)
                    }
                    Text(programmeSleepStateText(metric))
                        .font(.programmeMono(11))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            Spacer()
            Text(programmeSleepValueText(metric))
                .font(.programmeMono(17, weight: .semibold))
                .foregroundStyle(Color.pulseTextPrimary)
        }
        .padding(.vertical, 14)
    }
}
