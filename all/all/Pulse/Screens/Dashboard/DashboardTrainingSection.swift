//
//  DashboardTrainingSection.swift
//  all (bridge-connect)
//
//  Onglet Entraînement — figrow (séances/volume/FC/kcal/delta), puis selon la
//  sous-vue : charge hebdomadaire (barres + moyenne 4 sem.), répartition par
//  sport + régularité, temps par zone d'effort, records de la période.
//

import Charts
import SwiftUI

struct DashboardTrainingSection: View {
    let viewModel: DashboardViewModel

    /// Semaine survolée sur le graphe de charge — répercutée sur la tuile
    /// figrow « Volume » (tuile 1) : le volume total de la période et le
    /// volume d'une semaine sont la même grandeur (durée, format `hm()`),
    /// contrairement à la charge elle-même (indicateur composite sans tuile
    /// dédiée).
    @State private var loadHover: DashboardTrainingWeek?

    var body: some View {
        if let training = viewModel.training {
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                DashboardFigureRow(tiles: figures(for: training), highlights: figureHighlight)

                switch viewModel.subView {
                case .load:
                    DashboardTrainingLoadCard(weeks: training.weeks, hover: $loadHover)
                case .sport:
                    VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                        DashboardSportShareCard(shares: training.shares)
                        DashboardStreakCard(streak: training.streak)
                    }
                case .zones:
                    DashboardZonesCard(zones: training.zones)
                case .records:
                    DashboardRecordsCard(records: training.records)
                default:
                    DashboardTrainingLoadCard(weeks: training.weeks, hover: $loadHover)
                }
            }
            .onChange(of: viewModel.subView) { _, _ in loadHover = nil }
        } else {
            DashboardSkeletonCard()
        }
    }

    private var figureHighlight: [Int: String] {
        guard viewModel.subView == .load, let week = loadHover else { return [:] }
        return [1: dashboardFormatHM(Int(week.durationS))]
    }

    private func figures(for training: DashboardTrainingTab) -> [DashboardFigure] {
        [
            DashboardFigure(label: "Séances", value: "\(training.count)"),
            DashboardFigure(label: "Volume", value: dashboardFormatHM(Int(training.totalS))),
            DashboardFigure(label: "Séances / sem.", value: String(format: "%.1f", training.perWeek)),
            DashboardFigure(label: "FC moy. effort", value: training.avgHr.map { "\($0)" } ?? "—"),
            DashboardFigure(label: "kcal actives", value: "\(training.activeKcal)"),
            DashboardFigure(
                label: "vs période préc.",
                value: training.deltaPct.map { "\($0 > 0 ? "+" : "")\($0) %" } ?? "—",
                accent: (training.deltaPct ?? 0) > 0 ? .pulseSuccess : ((training.deltaPct ?? 0) < 0 ? .pulseDanger : .pulseAccent)
            ),
        ]
    }
}

/// Charge hebdomadaire — barres de charge, surcharge (>130 % de la moyenne des
/// 4 semaines précédentes) en couleur d'alerte, ligne de moyenne mobile.
private struct DashboardTrainingLoadCard: View {
    let weeks: [DashboardTrainingWeek]
    @Binding var hover: DashboardTrainingWeek?

    /// Semaine (catégorielle, `week.label`) sous le doigt — `chartXSelection`
    /// fonctionne aussi sur un axe X catégoriel (`String`), pas seulement sur
    /// des `Date` continues.
    @State private var selectedLabel: String?

    var body: some View {
        PulseCard {
            DashboardCardHeader("Charge hebdomadaire")
            if weeks.isEmpty {
                Text("Pas d'activité sur la période.")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                Chart {
                    ForEach(weeks) { week in
                        BarMark(
                            x: .value("Semaine", week.label),
                            y: .value("Charge", week.load)
                        )
                        .foregroundStyle(week.overload ? DashboardMetricColor.stress : Color.pulseAccent.opacity(0.85))
                        if let avg4 = week.avg4 {
                            LineMark(
                                x: .value("Semaine", week.label),
                                y: .value("Moyenne 4 sem.", avg4)
                            )
                            .foregroundStyle(DashboardMetricColor.stress)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                    // Repère de la semaine survolée.
                    if let sel = selectedWeek {
                        RuleMark(x: .value("Semaine", sel.label))
                            .foregroundStyle(Color.pulseTextSecondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value("Semaine", sel.label), y: .value("Charge", sel.load))
                            .foregroundStyle(Color.pulseAccent)
                            .symbolSize(80)
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 160)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: min(weeks.count, 6)))
                }
                .chartXSelection(value: $selectedLabel)
                .onChange(of: selectedLabel) { _, newValue in
                    hover = newValue.flatMap { label in weeks.first { $0.label == label } }
                }

                DashboardLegendRow(items: [
                    (Color.pulseAccent.opacity(0.85), "charge de la semaine"),
                    (DashboardMetricColor.stress, "surcharge · plus de 130 % de la moyenne"),
                    (DashboardMetricColor.stress, "moyenne des 4 semaines précédentes"),
                ])
            }

            Text("Charge = durée × intensité relative. Une semaine à plus de 130 % de la moyenne des quatre précédentes est marquée en ambre : c'est là que les blessures arrivent.")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    private var selectedWeek: DashboardTrainingWeek? {
        guard let selectedLabel else { return nil }
        return weeks.first { $0.label == selectedLabel }
    }
}

private struct DashboardSportShareCard: View {
    let shares: [DashboardSportShare]

    var body: some View {
        PulseCard {
            DashboardCardHeader("Répartition par sport")
            if shares.isEmpty {
                Text("Pas d'activité sur la période.")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                DashboardProportionBar(segments: shares.map { (dashboardSportColor($0.sport), $0.pct) })
                VStack(spacing: PulseSpacing.sm) {
                    ForEach(shares) { share in
                        HStack {
                            Circle().fill(dashboardSportColor(share.sport)).frame(width: 9, height: 9)
                            Text(dashboardSportName(share.sport))
                                .font(.subheadline)
                                .foregroundStyle(Color.pulseTextPrimary)
                            Spacer()
                            Text(dashboardFormatHM(Int(share.durationS)))
                                .font(PulseFont.metricUnit)
                                .foregroundStyle(Color.pulseTextSecondary)
                            Text("\(share.pct) %")
                                .font(PulseFont.metricUnit)
                                .foregroundStyle(Color.pulseTextSecondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

private struct DashboardStreakCard: View {
    let streak: DashboardStreak

    var body: some View {
        PulseCard {
            HStack {
                DashboardCardHeader("Régularité")
                Spacer()
                Text(dashboardStreakLabel(current: streak.current))
                    .font(PulseFont.metricLabel)
                    .padding(.horizontal, PulseSpacing.sm)
                    .padding(.vertical, 3)
                    .background(streak.current >= 4 ? Color.pulseSuccess.opacity(0.14) : Color.pulseSurfaceAlt)
                    .foregroundStyle(streak.current >= 4 ? Color.pulseSuccess : Color.pulseTextSecondary)
                    .clipShape(Capsule())
            }
            HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
                Text("\(streak.best)")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pulseTextPrimary)
                Text("semaines sans coupure")
                    .font(PulseFont.metricUnit)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Text("plus longue série de l'historique · 3 séances / sem. minimum")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

private struct DashboardZonesCard: View {
    let zones: [DashboardZone]

    var body: some View {
        let ordered = zones.sorted { $0.zone > $1.zone }
        let maxSeconds = max(ordered.map(\.seconds).max() ?? 1, 1)
        let totalSeconds = ordered.reduce(0.0) { $0 + $1.seconds }

        return PulseCard {
            HStack {
                DashboardCardHeader("Temps par zone d'effort")
                Spacer()
                Text("\(dashboardFormatHM(Int(totalSeconds))) cumulées")
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            if ordered.isEmpty {
                Text("Pas de zone d'effort calculée sur la période.")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                VStack(spacing: PulseSpacing.sm) {
                    ForEach(ordered) { zone in
                        HStack(spacing: PulseSpacing.sm) {
                            Text("Z\(zone.zone)")
                                .font(PulseFont.metricUnit)
                                .foregroundStyle(Color.pulseTextSecondary)
                                .frame(width: 24, alignment: .leading)
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.pulseSurfaceAlt)
                                    .overlay(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(dashboardZoneColor(zone.zone))
                                            .frame(width: proxy.size.width * CGFloat(zone.seconds) / CGFloat(maxSeconds))
                                    }
                            }
                            .frame(height: 12)
                            Text(dashboardFormatHM(Int(zone.seconds)))
                                .font(PulseFont.metricUnit)
                                .foregroundStyle(Color.pulseTextPrimary)
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

private struct DashboardRecordsCard: View {
    let records: DashboardTrainingRecords

    var body: some View {
        PulseCard {
            DashboardCardHeader("Records de la période")
            VStack(spacing: 0) {
                if let r = records.longestSession {
                    DashboardRecordRow(name: "Séance la plus longue", value: dashboardFormatHM(Int(r.value)), caption: r.date.map(dashboardRecordDate))
                }
                if let r = records.longestDistance {
                    DashboardRecordRow(name: "Plus longue sortie", value: String(format: "%.1f km", r.value / 1000), caption: r.date.map(dashboardRecordDate))
                }
                if let r = records.bestPace {
                    DashboardRecordRow(name: "Meilleure allure", value: dashboardFormatPace(secPerKm: r.value), caption: r.date.map(dashboardRecordDate))
                }
                if let r = records.heaviestWeek {
                    DashboardRecordRow(name: "Semaine la plus chargée", value: dashboardFormatHM(Int(r.value)), caption: r.label)
                }
                if let r = records.maxHr {
                    DashboardRecordRow(name: "FC max relevée", value: "\(Int(r.value)) bpm", caption: r.date.map(dashboardRecordDate))
                }
                if records.longestSession == nil && records.longestDistance == nil && records.bestPace == nil
                    && records.heaviestWeek == nil && records.maxHr == nil {
                    Text("Pas assez de séances pour établir de records sur la période.")
                        .font(PulseFont.body)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
        }
    }
}

private struct DashboardRecordRow: View {
    let name: String
    let value: String
    let caption: String?

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
            Text(name)
                .font(.subheadline)
                .foregroundStyle(Color.pulseTextPrimary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(Color.pulseTextPrimary)
            if let caption {
                Text(caption)
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
        .padding(.vertical, PulseSpacing.sm)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.pulseBorder).frame(height: 1)
        }
    }
}

// MARK: - Composants réutilisés par plusieurs onglets

/// `.propbar` côté Angular : barre proportionnelle empilée.
struct DashboardProportionBar: View {
    let segments: [(Color, Int)]

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segment.0)
                        .frame(width: proxy.size.width * CGFloat(segment.1) / 100)
                }
            }
        }
        .frame(height: 10)
    }
}

/// `.legend` côté Angular.
struct DashboardLegendRow: View {
    let items: [(Color, String)]

    var body: some View {
        HStack(spacing: PulseSpacing.md) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: PulseSpacing.xs) {
                    RoundedRectangle(cornerRadius: 2).fill(item.0).frame(width: 10, height: 10)
                    Text(item.1)
                        .font(.caption2)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
        }
    }
}

/// État de chargement local (données pas encore arrivées mais écran déjà
/// affiché) — `#loadingBlock` côté Angular.
struct DashboardSkeletonCard: View {
    var body: some View {
        PulseCard {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        }
    }
}
