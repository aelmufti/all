//
//  DashboardSleepSection.swift
//  all (bridge-connect)
//
//  Onglet Sommeil — tendance (durée par nuit sur `/api/wellness/days`), dette
//  de sommeil (+ détail des nuits + insights : impact stress, fragmentation,
//  composition des phases, éveils × oxygénation), régularité coucher/lever.
//

import Charts
import SwiftUI

struct DashboardSleepSection: View {
    let viewModel: DashboardViewModel

    var body: some View {
        switch viewModel.subView {
        case .debt:
            if let sleepDebt = viewModel.sleepDebt {
                DashboardSleepDebtCard(viewModel: viewModel, sleepDebt: sleepDebt)
            } else {
                DashboardSkeletonCard()
            }
        case .regularity:
            if let regularity = viewModel.sleepRegularity {
                DashboardSleepRegularityCard(regularity: regularity)
            } else {
                DashboardSkeletonCard()
            }
        default:
            DashboardSleepTrendCard(viewModel: viewModel)
        }
    }
}

private struct DashboardSleepTrendCard: View {
    let viewModel: DashboardViewModel

    private var points: [(date: Date, hours: Double)] {
        zip(viewModel.wellnessDates, viewModel.wellnessSleepHours).compactMap { date, hours in
            guard let date, let hours else { return nil }
            return (date, hours)
        }
    }

    var body: some View {
        PulseCard {
            HStack {
                SectionHeader("Sommeil · \(viewModel.sleepNightsCount) nuits")
                Spacer()
                Text(rangeLabel)
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            if points.count < 2 {
                Text("Pas assez de nuits pour une tendance.")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                Chart(points, id: \.date) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Heures", point.hours)
                    )
                    .foregroundStyle(DashboardMetricColor.sleep)
                    .interpolationMethod(.monotone)
                }
                .frame(height: 190)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { AxisValueLabel(format: .dateTime.day().month()) }
                }
            }
        }
    }

    private var rangeLabel: String {
        let hours = points.map(\.hours)
        guard !hours.isEmpty else { return "aucune nuit" }
        let avg = hours.reduce(0, +) / Double(hours.count)
        return "moy \(String(format: "%.1f", avg)) h"
    }
}

private struct DashboardSleepDebtCard: View {
    let viewModel: DashboardViewModel
    let sleepDebt: DashboardSleepDebt

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.lg) {
            if sleepDebt.nights > 0 {
                PulseCard {
                    HStack {
                        SectionHeader("Dette de sommeil")
                        Spacer()
                        Text(viewModel.debtLevel)
                            .font(PulseFont.metricLabel)
                            .padding(.horizontal, PulseSpacing.sm)
                            .padding(.vertical, 3)
                            .background(Color.pulseSurfaceAlt)
                            .foregroundStyle(badgeColor)
                            .clipShape(Capsule())
                    }
                    HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
                        Text(String(format: "%.1f", abs(sleepDebt.debtHours)))
                            .font(.system(size: 44, weight: .semibold, design: .monospaced))
                            .foregroundStyle(sleepDebt.debtHours <= 0 ? Color.pulseSuccess : Color.pulseTextPrimary)
                        Text("h")
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    HStack(spacing: PulseSpacing.xl) {
                        DashboardMiniFigure(label: "Objectif", value: "\(sleepDebt.targetHours) h")
                        DashboardMiniFigure(label: "Moyenne", value: String(format: "%.1f h", sleepDebt.avgHours))
                        DashboardMiniFigure(label: "Sous l'objectif", value: "\(sleepDebt.deficitNights)/\(sleepDebt.nights)")
                    }
                }

                DashboardNightsDetailCard(viewModel: viewModel, sleepDebt: sleepDebt)

                if let insights = viewModel.sleepInsights {
                    DashboardSleepInsightsCard(insights: insights)
                }
            } else {
                PulseCard {
                    SectionHeader("Dette de sommeil")
                    Text("Aucune nuit mesurée sur la période.")
                        .font(PulseFont.body)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
        }
    }

    private var badgeColor: Color {
        switch viewModel.debtLevel {
        case "élevée": return .pulseDanger
        case "à jour", "faible": return .pulseSuccess
        default: return .pulseTextSecondary
        }
    }
}

private struct DashboardMiniFigure: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .foregroundStyle(Color.pulseTextPrimary)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

/// « Détail des N nuits » — `<app-panel>` côté Angular ; ici toujours visible
/// (pas d'accordéon replié par défaut, l'écran natif défile déjà en liste).
private struct DashboardNightsDetailCard: View {
    let viewModel: DashboardViewModel
    let sleepDebt: DashboardSleepDebt

    var body: some View {
        PulseCard {
            SectionHeader("Détail des \(sleepDebt.nights) nuits")

            VStack(spacing: 0) {
                ForEach(viewModel.debtDetail) { night in
                    HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
                        Text(dashboardLongDate(night.date))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                            .frame(minWidth: 90, alignment: .leading)
                        Text(dashboardFormatHM(night.sleepS))
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .foregroundStyle(Color.pulseTextPrimary)
                        Spacer()
                        Text(dashboardFormatSignedHM(night.deltaS))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(night.deltaS < 0 ? Color.pulseDanger : Color.pulseSuccess)
                        Text(dashboardFormatSignedHours(night.cumulativeS))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    .padding(.vertical, PulseSpacing.xs)
                    .overlay(alignment: .top) { Rectangle().fill(Color.pulseBorder).frame(height: 1) }
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: PulseSpacing.md) {
                if let worst = viewModel.worstNight {
                    DashboardMiniFigure(label: "Pire nuit", value: dashboardFormatHM(worst.sleepS))
                }
                if let best = viewModel.bestNight {
                    DashboardMiniFigure(label: "Meilleure", value: dashboardFormatHM(best.sleepS))
                }
                DashboardMiniFigure(label: "7 derniers jours", value: "\(viewModel.weekDeltaHours > 0 ? "+" : "")\(String(format: "%.1f", viewModel.weekDeltaHours)) h")
                DashboardMiniFigure(label: "Nuits sans données", value: "\(viewModel.missingNights)")
            }

            Text("Somme des écarts négatifs à l'objectif sur la période. La durée retenue est le sommeil réel — profond, léger et paradoxal — soit \(String(format: "%.1f", sleepDebt.avgInBedHours)) h de fenêtre en moyenne dont \(sleepDebt.avgAwakeMin) min éveillé, qui ne comptent pas. Les nuits sans données de montre sont exclues, pas comptées à zéro.")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

private struct DashboardSleepInsightsCard: View {
    let insights: DashboardSleepInsights

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.lg) {
            PulseCard {
                Text("Impact sur ton stress du lendemain").font(.headline).foregroundStyle(Color.pulseTextPrimary)
                let maxStress = insights.stressImpact.buckets.compactMap(\.avgStress).max() ?? 1
                VStack(spacing: PulseSpacing.sm) {
                    ForEach(insights.stressImpact.buckets) { bucket in
                        if let avgStress = bucket.avgStress {
                            HStack(spacing: PulseSpacing.sm) {
                                Text(bucket.label)
                                    .font(.caption)
                                    .foregroundStyle(Color.pulseTextSecondary)
                                    .frame(width: 92, alignment: .leading)
                                GeometryReader { proxy in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.pulseSurfaceAlt)
                                        .overlay(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(DashboardMetricColor.stress)
                                                .frame(width: proxy.size.width * CGFloat(maxStress > 0 ? avgStress / maxStress : 0))
                                        }
                                }
                                .frame(height: 12)
                                Text(String(format: "%.1f", avgStress))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Color.pulseTextPrimary)
                                Text("\(bucket.nights) n")
                                    .font(.caption2)
                                    .foregroundStyle(Color.pulseTextSecondary)
                            }
                        }
                    }
                }
                Text("Sur \(insights.stressImpact.nights) nuits · corrélation r = \(insights.stressImpact.r.map { String(format: "%.2f", $0) } ?? "—")\(insights.stressImpact.significant ? "" : " (non significative)"). Une corrélation n'est pas une preuve de causalité : une journée stressante peut aussi abîmer la nuit qui suit.")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            PulseCard {
                Text("Fragmentation").font(.headline).foregroundStyle(Color.pulseTextPrimary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: PulseSpacing.md) {
                    DashboardMiniFigure(label: "Éveils / nuit", value: String(format: "%.1f", insights.fragmentation.avgArousals))
                    DashboardMiniFigure(label: "Min éveillé", value: "\(insights.fragmentation.avgAwakeMin)")
                    DashboardMiniFigure(label: "Min, plus long éveil", value: "\(insights.fragmentation.avgLongestMin)")
                }
                Text("Moyennes sur \(insights.fragmentation.nights) nuits. Le temps éveillé après endormissement dépasse habituellement peu 5 à 10 % de la nuit.")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            PulseCard {
                Text("Composition des phases").font(.headline).foregroundStyle(Color.pulseTextPrimary)
                VStack(spacing: PulseSpacing.sm) {
                    ForEach(dashboardCompositionRows(insights.composition), id: \.label) { row in
                        HStack(spacing: PulseSpacing.sm) {
                            Text(row.label)
                                .font(.caption)
                                .foregroundStyle(Color.pulseTextSecondary)
                                .frame(width: 92, alignment: .leading)
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.pulseSurfaceAlt)
                                    .overlay(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(row.out ? Color.pulseDanger : DashboardMetricColor.stress)
                                            .frame(width: proxy.size.width * CGFloat(row.pct / 100))
                                    }
                            }
                            .frame(height: 12)
                            Text(String(format: "%.1f %%", row.pct))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(row.out ? Color.pulseDanger : Color.pulseTextPrimary)
                            Text("réf. \(Int(row.lo))–\(Int(row.hi)) %")
                                .font(.caption2)
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                    }
                }
                Text("En part du sommeil réel, moyenné sur \(insights.composition.nights) nuits. L'éveil représente \(String(format: "%.1f", insights.composition.wasoPct)) % de la fenêtre. Les fourchettes de référence sont indicatives et varient avec l'âge.")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            if let spo2Arousal = insights.spo2Arousal {
                PulseCard {
                    Text("Éveils × oxygénation").font(.headline).foregroundStyle(Color.pulseTextPrimary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: PulseSpacing.md) {
                        DashboardMiniFigure(label: "Désaturations proches d'un éveil", value: String(format: "%.1f %%", spo2Arousal.desatNearPct))
                        DashboardMiniFigure(label: "Témoins décalés de 30 min", value: String(format: "%.1f %%", spo2Arousal.controlPct))
                    }
                    Text("À ne pas lire comme un dépistage d'apnée. Tes éveils durent \(spo2Arousal.medianArousalMin) min en médiane et seulement \(spo2Arousal.microArousals) sur \(spo2Arousal.totalArousals) font moins de 5 minutes : ce sont de longs réveils, pas les micro-éveils de quelques secondes qui suivent une apnée. L'explication la plus probable de l'écart ci-dessus est un artefact de mouvement du capteur au réveil, pas une désaturation réelle. Calculé sur \(spo2Arousal.nights) nuits seulement, celles où le capteur SpO2 nocturne était actif.")
                        .font(.footnote)
                        .foregroundStyle(DashboardMetricColor.stress)
                }
            }
        }
    }
}

/// `compositionRows` côté Angular — extrait ici en fonction libre (pas besoin
/// du view-model, ne dépend que d'`DashboardComposition`).
private func dashboardCompositionRows(_ composition: DashboardComposition) -> [(label: String, pct: Double, lo: Double, hi: Double, out: Bool)] {
    let rows: [(String, Double, DashboardRange)] = [
        ("Profond", composition.deep, composition.ref.deep),
        ("Léger", composition.light, composition.ref.light),
        ("Paradoxal", composition.rem, composition.ref.rem),
    ]
    return rows.map { label, pct, range in
        (label: label, pct: pct, lo: range.lo, hi: range.hi, out: pct < range.lo || pct > range.hi)
    }
}

private struct DashboardSleepRegularityCard: View {
    let regularity: DashboardSleepRegularity

    var body: some View {
        PulseCard {
            SectionHeader("Régularité")
            if let score = regularity.score {
                HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
                    Text("\(score)")
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .foregroundStyle(dashboardRegularityColor(score: score))
                    Text("/100")
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                Text("coucher ~\(regularity.bedtime ?? "—") (±\(regularity.bedStdMin ?? 0) min) · lever ~\(regularity.waketime ?? "—") (±\(regularity.wakeStdMin ?? 0) min)")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                Text("Pas assez de nuits pour calculer une régularité (\(regularity.nights) nuit\(regularity.nights > 1 ? "s" : "")).")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }
}
