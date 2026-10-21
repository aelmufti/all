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
                PulseCard {
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
                            if index > 0 { Divider() }
                            metricRow(metric)
                        }
                    }
                }
                .padding(PulseSpacing.lg)
            }
        }
        .background(Color.pulseBackground)
        .navigationTitle(domain?.active?.name ?? "Sommeil")
        .navigationBarTitleDisplayMode(.inline)
        .programmeAbout(kind: .sleep, viewModel: viewModel)
        .onChange(of: domain?.active == nil) { _, stopped in if stopped { dismiss() } }
    }

    private func hero(_ detail: ProgrammeSleepDetail) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(detail.nights > 0 ? "\(detail.hits)" : "—")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(detail.nights > 0 ? Color.pulseTextPrimary : Color.pulseAbsent)
                Text("/\(detail.total)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Text("critères tenus · \(programmeSleepWindowLabel(detail))")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    private func strip(_ detail: ProgrammeSleepDetail) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(detail.strip) { night in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(night.workDay ? Color.pulseSleep : Color.pulseSleep.opacity(0.42))
                        .frame(height: max(4, CGFloat(night.sleepMin) / 8))
                    Text(ProgrammeDate.weekdayLetters[max(0, min(6, night.weekday))])
                        .font(.system(size: 9, design: .rounded))
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
            ProgrammeLegendDot(color: .pulseSleep, label: "jour travaillé")
            ProgrammeLegendDot(color: .pulseSleep.opacity(0.42), label: "jour libre")
        }
        .font(.system(size: 11, design: .rounded))
    }

    /// Libellé, valeur, statut — une rangée par critère.
    private func metricRow(_ metric: ProgrammeSleepMetric) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PulseSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.label).font(.system(size: 15, weight: .semibold))
                HStack(spacing: 6) {
                    if !metric.informative {
                        Circle().fill(programmeSleepMarkerColor(metric)).frame(width: 7, height: 7)
                    }
                    Text(programmeSleepStateText(metric))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            Spacer()
            Text(programmeSleepValueText(metric))
                .font(.system(size: 19, weight: .semibold, design: .rounded))
        }
        .padding(.vertical, PulseSpacing.sm)
    }
}
