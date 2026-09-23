//
//  Spo2ReportView.swift
//  all (bridge-connect)
//
//  Écran natif « Rapport SpO2 » — miroir de la page Angular `/rapport-spo2`
//  (`custom-connect/web/src/app/pages/spo2-report/spo2-report.component.ts`) :
//  document de synthèse de la saturation en oxygène nocturne, nuit par nuit.
//  La page Angular est pensée pour l'impression (feuille A4) ; ici on garde
//  l'esprit (notice sur l'origine des données, synthèse, courbe par nuit)
//  mais dans une mise en page native défilante avec les composants du socle
//  (`DesignSystem.swift`) et Swift Charts pour les courbes.
//
//  Trois états stricts (cf. contrat de l'agent) : chargement (`LoadingView`),
//  erreur (`ErrorView(message:retry:)`), données — avec, à l'intérieur de
//  l'état « données », le cas particulier « aucune nuit exploitable » que
//  l'Angular affiche aussi comme un message dédié plutôt qu'un vrai état
//  d'erreur.
//

import SwiftUI
import Charts

struct Spo2ReportView: View {
    @State private var viewModel = Spo2ReportViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if let report = viewModel.report {
                    loaded(report: report)
                } else if let message = viewModel.errorMessage {
                    ErrorView(message: message) {
                        Task { await viewModel.retry() }
                    }
                } else {
                    LoadingView(message: "Chargement du rapport…")
                }
            }
            .navigationTitle("Rapport SpO2")
            .navigationBarTitleDisplayMode(.large)
            .background(Color.pulseBackground)
        }
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private func loaded(report: Spo2Report) -> some View {
        if report.nights.isEmpty {
            Spo2EmptyStateView(minCoverageMinutes: viewModel.minCoverageMinutes)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                    Spo2ReportHeaderCard(viewModel: viewModel)
                    Spo2NoticeCard(viewModel: viewModel)
                    Spo2SummaryCard(totals: viewModel.totals, nightsCount: viewModel.nights.count)
                    ForEach(viewModel.nights) { night in
                        Spo2NightCard(nightView: night)
                    }
                }
                .padding(PulseSpacing.lg)
            }
            .background(Color.pulseBackground)
        }
    }
}

// MARK: - En-tête (miroir de `doc-head`)

private struct Spo2ReportHeaderCard: View {
    let viewModel: Spo2ReportViewModel

    var body: some View {
        PulseCard {
            Text("Saturation en oxygène nocturne")
                .font(PulseFont.sectionTitle)
                .foregroundStyle(Color.pulseTextPrimary)
            Text("Relevés issus d'une montre connectée — document remis à titre indicatif")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
            VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                Text("Période : \(viewModel.periodLabel)")
                Text("Édité le \(viewModel.generatedLabel)")
                Text("Nuits exploitables : \(viewModel.nights.count) / \(viewModel.nights.count + viewModel.excludedNights)")
            }
            .font(.footnote)
            .foregroundStyle(Color.pulseTextSecondary)
            .padding(.top, PulseSpacing.xs)
        }
    }
}

// MARK: - Notice (miroir de `.notice`)

private struct Spo2NoticeCard: View {
    let viewModel: Spo2ReportViewModel

    var body: some View {
        PulseCard {
            SectionHeader("Origine des données et limites")
            VStack(alignment: .leading, spacing: PulseSpacing.sm) {
                bullet(
                    "Mesures issues d'un capteur optique de poignet grand public (montre Garmin). " +
                    "Ce n'est pas un oxymètre à usage médical certifié : les valeurs peuvent être " +
                    "biaisées par les mouvements, la perfusion périphérique, la position du poignet " +
                    "ou la pigmentation cutanée."
                )
                bullet(
                    "Échantillonnage : une mesure toutes les \(viewModel.intervalLabel). " +
                    "L'oxymétrie nocturne diagnostique enregistre à 1 Hz. À cette cadence, une " +
                    "désaturation brève peut passer inaperçue, et l'index de désaturation (IDO) " +
                    "ainsi que l'IAH ne peuvent pas être calculés à partir de ces données."
                )
                bullet(
                    "Les fenêtres de sommeil sont celles détectées par la montre elle-même. Les " +
                    "périodes d'éveil intra-nuit ne sont pas exclues du calcul."
                )
                bullet(
                    "Ce document est un élément de contexte, destiné à accompagner un avis médical. " +
                    "Il ne constitue ni un dépistage ni un diagnostic, et ne remplace pas une " +
                    "polygraphie ou une polysomnographie."
                )
                if viewModel.excludedNights > 0 {
                    bullet(excludedText)
                }
            }
        }
    }

    private var excludedText: String {
        let n = viewModel.excludedNights
        let plural = n > 1 ? "s" : ""
        let verb = n > 1 ? "ont" : "a"
        return "\(n) nuit\(plural) \(verb) été écartée\(plural) : moins de " +
            "\(viewModel.minCoverageMinutes) minutes de mesures exploitables."
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PulseSpacing.xs) {
            Text("•")
                .foregroundStyle(Color.pulseTextSecondary)
            Text(text)
                .foregroundStyle(Color.pulseTextPrimary)
        }
        .font(.footnote)
    }
}

// MARK: - Synthèse (miroir de `tfoot` — ensemble de la période)

private struct Spo2SummaryCard: View {
    let totals: Spo2ReportTotals
    let nightsCount: Int

    var body: some View {
        PulseCard {
            SectionHeader("Synthèse — \(nightsCount) nuit\(nightsCount > 1 ? "s" : "")")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: PulseSpacing.md) {
                StatTile(label: "Moyenne", value: String(format: "%.1f", totals.mean), unit: "%")
                StatTile(
                    label: "Minimum",
                    value: String(format: "%.0f", totals.min),
                    unit: "%",
                    accent: totals.min < 88 ? .pulseDanger : .pulseAccent
                )
                StatTile(
                    label: "< 90 %",
                    value: "\(totals.t90Min)",
                    unit: "min",
                    accent: totals.t90Min > 0 ? .pulseDanger : .pulseAccent
                )
                StatTile(label: "Couverture", value: totals.coverageLabel)
            }
        }
    }
}

// MARK: - Nuit (miroir de `.night` — synthèse ligne + courbe)

private struct Spo2NightCard: View {
    let nightView: Spo2NightView

    private var night: Spo2Night { nightView.night }

    var body: some View {
        PulseCard {
            HStack(alignment: .firstTextBaseline) {
                Text(nightView.dayLabel)
                    .font(PulseFont.sectionTitle)
                    .foregroundStyle(Color.pulseTextPrimary)
                Spacer()
                Text(nightView.coverageLabel)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Text(nightView.window)
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)

            Spo2NightChartView(night: night, domain: nightView.chartDomain)
                .frame(height: 140)
                .padding(.vertical, PulseSpacing.xs)

            HStack(spacing: PulseSpacing.lg) {
                metric("Moy.", String(format: "%.1f", night.mean))
                metric("Méd.", String(format: "%.0f", night.median))
                metric("P5", String(format: "%.0f", night.p5))
                metric("Min", String(format: "%.0f", night.min), highlighted: night.min < 88)
            }
            HStack(spacing: PulseSpacing.lg) {
                metric("< 90 %", "\(nightView.t90Min) min", highlighted: nightView.t90Min >= 5)
                metric("< 88 %", "\(nightView.t88Min) min")
                metric("< 85 %", "\(nightView.t85Min) min")
            }
        }
    }

    private func metric(_ label: String, _ value: String, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(PulseFont.metricLabel)
                .foregroundStyle(Color.pulseTextSecondary)
            Text(value)
                .font(.system(size: 14, weight: highlighted ? .bold : .medium, design: .monospaced))
                .foregroundStyle(highlighted ? Color.pulseDanger : Color.pulseTextPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Courbe SpO2 d'une nuit — équivalent Swift Charts du tracé SVG fait à la
/// main côté Angular (`buildChart`), avec un seuil pointillé à 90 %.
private struct Spo2NightChartView: View {
    let night: Spo2Night
    let domain: ClosedRange<Double>

    var body: some View {
        if night.samples.isEmpty {
            Text("Aucune mesure pour cette nuit.")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(night.samples, id: \.ts) { sample in
                    LineMark(
                        x: .value("Heure", Date(timeIntervalSince1970: TimeInterval(sample.ts))),
                        y: .value("SpO2", sample.value)
                    )
                }
                .foregroundStyle(Color.pulseAccent)
                .interpolationMethod(.monotone)

                RuleMark(y: .value("Seuil", 90))
                    .foregroundStyle(Color.pulseTextSecondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartYScale(domain: domain)
            .chartLegend(.hidden)
        }
    }
}

// MARK: - Aucune nuit exploitable (miroir du message `.empty`)

private struct Spo2EmptyStateView: View {
    let minCoverageMinutes: Int

    var body: some View {
        VStack(spacing: PulseSpacing.md) {
            Image(systemName: "moon.zzz")
                .font(.largeTitle)
                .foregroundStyle(Color.pulseTextSecondary)
            Text(
                "Aucune nuit exploitable. La montre n'a enregistré aucune SpO2 nocturne d'au moins " +
                "\(minCoverageMinutes) minutes. Le capteur SpO2 pendant le sommeil doit être activé " +
                "dans les réglages de la montre."
            )
            .font(PulseFont.body)
            .foregroundStyle(Color.pulseTextPrimary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, PulseSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pulseBackground)
    }
}

#Preview {
    Spo2ReportView()
}
