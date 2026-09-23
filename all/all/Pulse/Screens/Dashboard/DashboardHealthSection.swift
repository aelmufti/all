//
//  DashboardHealthSection.swift
//  all (bridge-connect)
//
//  Onglet Santé — figrow (FC repos/respiration/SpO2/stress/poids/sommeil),
//  puis selon la sous-vue : FC au repos, respiration nocturne (+ bande
//  habituelle), distribution SpO2, poids, corrélations observées.
//

import Charts
import SwiftUI

struct DashboardHealthSection: View {
    let viewModel: DashboardViewModel

    var body: some View {
        if let health = viewModel.health {
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                DashboardFigureRow(tiles: figures(for: health))

                switch viewModel.subView {
                case .restingHr:
                    DashboardRestingHrCard(health: health)
                case .respiration:
                    DashboardRespirationCard(health: health)
                case .spo2:
                    DashboardSpo2Card(health: health)
                case .weight:
                    DashboardWeightCard(health: health)
                case .correlations:
                    DashboardCorrelationsCard(correlations: health.correlations)
                default:
                    DashboardRestingHrCard(health: health)
                }
            }
        } else {
            DashboardSkeletonCard()
        }
    }

    private func figures(for health: DashboardHealthTab) -> [DashboardFigure] {
        [
            DashboardFigure(label: "FC repos moy.", value: health.restingHr.map { "\($0)" } ?? "—", unit: "bpm"),
            DashboardFigure(label: "Resp. nuit / min", value: health.respiration.map { String(format: "%.1f", $0) } ?? "—"),
            DashboardFigure(label: "SpO2 nocturne", value: health.spo2Night.map { String(format: "%.0f", $0) } ?? "—", unit: health.spo2Night != nil ? "%" : nil),
            DashboardFigure(label: "Stress moy.", value: health.stress.map { "\($0)" } ?? "—"),
            DashboardFigure(label: "Poids", value: health.weightKg.map { String(format: "%.1f", $0) } ?? "—", unit: health.weightKg != nil ? "kg" : nil),
            DashboardFigure(label: "Sommeil moy.", value: health.sleepHours.map { String(format: "%.1f", $0) } ?? "—", unit: "h"),
        ]
    }
}

private struct DashboardRestingHrCard: View {
    let health: DashboardHealthTab

    var body: some View {
        PulseCard {
            HStack {
                SectionHeader("FC au repos")
                Spacer()
                Text(deltaLabel)
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            if health.restingSeries.isEmpty {
                Text("Pas assez de jours pour une tendance.")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                Chart(health.restingSeries) { point in
                    LineMark(
                        x: .value("Date", dashboardDate(from: point.date) ?? Date()),
                        y: .value("bpm", point.value)
                    )
                    .foregroundStyle(DashboardMetricColor.heartRate)
                    .interpolationMethod(.monotone)
                }
                .frame(height: 150)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { AxisValueLabel(format: .dateTime.day().month()) }
                }
            }
        }
    }

    private var deltaLabel: String {
        guard let delta = health.restingDelta else { return "trop peu de jours" }
        if delta == 0 { return "stable sur la période" }
        return "\(delta > 0 ? "+" : "")\(delta) bpm sur la période"
    }
}

private struct DashboardRespirationCard: View {
    let health: DashboardHealthTab

    var body: some View {
        PulseCard {
            HStack {
                SectionHeader("Respiration nocturne")
                Spacer()
                Text(health.respirationBand != nil ? "bande = normale personnelle" : "trop peu de nuits")
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            if health.respirationSeries.isEmpty {
                Text("Pas assez de nuits pour une tendance.")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                Chart {
                    if let band = health.respirationBand {
                        RuleMark(y: .value("bas", band.lo)).foregroundStyle(Color.pulseBorder).lineStyle(StrokeStyle(dash: [4, 4]))
                        RuleMark(y: .value("haut", band.hi)).foregroundStyle(Color.pulseBorder).lineStyle(StrokeStyle(dash: [4, 4]))
                    }
                    ForEach(health.respirationSeries) { point in
                        LineMark(
                            x: .value("Date", dashboardDate(from: point.date) ?? Date()),
                            y: .value("resp/min", point.value)
                        )
                        .foregroundStyle(Color.pulseAccent)
                        .interpolationMethod(.monotone)
                    }
                }
                .frame(height: 150)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { AxisValueLabel(format: .dateTime.day().month()) }
                }
                if let band = health.respirationBand {
                    Text("habituel entre \(String(format: "%.0f", band.lo)) et \(String(format: "%.0f", band.hi)) respirations / min")
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
        }
    }
}

private struct DashboardSpo2Card: View {
    let health: DashboardHealthTab

    var body: some View {
        PulseCard {
            HStack {
                SectionHeader("SpO2 · distribution")
                Spacer()
                Text("\(health.spo2Nights) nuits")
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            if health.spo2Buckets.allSatisfy({ $0.nights == 0 }) {
                Text("Pas de mesure SpO2 nocturne sur la période.")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                Chart(health.spo2Buckets) { bucket in
                    BarMark(
                        x: .value("SpO2", bucket.label),
                        y: .value("Nuits", bucket.nights)
                    )
                    .foregroundStyle(bucket.label == "<90" ? Color.pulseDanger : DashboardMetricColor.spo2)
                }
                .frame(height: 150)
            }
        }
    }
}

private struct DashboardWeightCard: View {
    let health: DashboardHealthTab

    var body: some View {
        PulseCard {
            if health.weightSeries.count > 1 {
                HStack {
                    SectionHeader("Poids")
                    Spacer()
                    Text(deltaLabel)
                        .font(PulseFont.metricLabel)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                Chart(health.weightSeries) { point in
                    LineMark(
                        x: .value("Date", dashboardDate(from: point.date) ?? Date()),
                        y: .value("kg", point.kg)
                    )
                    .foregroundStyle(DashboardMetricColor.sleep)
                    .interpolationMethod(.monotone)
                }
                .frame(height: 150)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { AxisValueLabel(format: .dateTime.day().month()) }
                }
                if let first = health.weightSeries.first, let last = health.weightSeries.last {
                    Text("\(String(format: "%.1f", first.kg)) kg → \(String(format: "%.1f", last.kg)) kg · \(health.weightSeries.count) pesées")
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            } else {
                SectionHeader("Poids") { Text("aucune pesée").font(PulseFont.metricLabel).foregroundStyle(Color.pulseTextSecondary) }
                Text("Pas de pesée sur la période. La saisie se fait sur la page Santé, jour par jour.")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }

    private var deltaLabel: String {
        guard let delta = health.weightDelta else { return "—" }
        return "\(delta > 0 ? "+" : "")\(String(format: "%.1f", delta)) kg"
    }
}

private struct DashboardCorrelationsCard: View {
    let correlations: [DashboardCorrelation]

    var body: some View {
        PulseCard {
            SectionHeader("Ce qui bouge ensemble")
            VStack(spacing: PulseSpacing.md) {
                ForEach(correlations) { correlation in
                    VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                        HStack {
                            Text(correlation.label)
                                .font(.subheadline)
                                .foregroundStyle(Color.pulseTextPrimary)
                            Spacer()
                            Text(correlation.strength)
                                .font(PulseFont.metricLabel)
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.pulseSurfaceAlt)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.pulseAccent)
                                        .frame(width: proxy.size.width * width(for: correlation.r))
                                }
                        }
                        .frame(height: 8)
                    }
                }
            }
            Text("corrélations observées sur la période, pas des causes")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    private func width(for r: Double?) -> CGFloat {
        guard let r else { return 0 }
        return CGFloat(min(abs(r), 1))
    }
}
