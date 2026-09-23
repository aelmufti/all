//
//  DashboardNutritionSection.swift
//  all (bridge-connect)
//
//  Onglet Nutrition — si aucune journée complète, message d'invitation à
//  saisir un repas (comme côté Angular). Sinon figrow, puis selon la
//  sous-vue : apport vs dépense, macros, régularité de saisie (grille 30 j),
//  aliments les plus fréquents.
//

import Charts
import SwiftUI

struct DashboardNutritionSection: View {
    let viewModel: DashboardViewModel

    var body: some View {
        if let nutrition = viewModel.nutrition {
            if nutrition.completeDays == 0 {
                DashboardNutritionEmptyCard(nutrition: nutrition)
            } else {
                VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                    DashboardFigureRow(tiles: figures(for: nutrition))

                    switch viewModel.subView {
                    case .intake:
                        DashboardIntakeCard(nutrition: nutrition)
                    case .macros:
                        DashboardMacrosCard(macros: nutrition.macros, completeDays: nutrition.completeDays)
                    case .logging:
                        DashboardLoggingGridCard(series: nutrition.series)
                    case .foods:
                        DashboardTopFoodsCard(nutrition: nutrition)
                    default:
                        DashboardIntakeCard(nutrition: nutrition)
                    }
                }
            }
        } else {
            DashboardSkeletonCard()
        }
    }

    private func figures(for nutrition: DashboardNutritionTab) -> [DashboardFigure] {
        [
            DashboardFigure(label: "kcal / jour", value: nutrition.kcalPerDay.map { "\($0)" } ?? "—"),
            DashboardFigure(label: "Dépense / jour", value: nutrition.expenditurePerDay.map { "\($0)" } ?? "—"),
            DashboardFigure(
                label: "Balance",
                value: nutrition.balance.map { "\($0 > 0 ? "+" : "")\($0)" } ?? "—",
                accent: (nutrition.balance ?? 0) <= 0 ? .pulseSuccess : .pulseDanger
            ),
            DashboardFigure(label: "Protéines / jour", value: "\(nutrition.proteinPerDay ?? 0)", unit: "g"),
            DashboardFigure(label: "Jours saisis", value: "\(nutrition.daysLogged) / \(nutrition.days)"),
            DashboardFigure(label: "Prises / jour", value: String(format: "%.1f", nutrition.entriesPerDay)),
        ]
    }
}

private struct DashboardNutritionEmptyCard: View {
    let nutrition: DashboardNutritionTab

    var body: some View {
        PulseCard {
            SectionHeader("Nutrition")
            Text("\(nutrition.daysLogged) jour\(nutrition.daysLogged > 1 ? "s" : "") saisi\(nutrition.daysLogged > 1 ? "s" : "") sur la période, dont aucun complet. Les moyennes ont besoin de journées entières pour vouloir dire quelque chose.")
                .font(PulseFont.body)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

private struct DashboardIntakeCard: View {
    let nutrition: DashboardNutritionTab

    var body: some View {
        PulseCard {
            SectionHeader("Apport vs dépense")
            Chart {
                ForEach(nutrition.series) { day in
                    if let kcal = day.kcal, let date = dashboardDate(from: day.date) {
                        BarMark(
                            x: .value("Date", date, unit: .day),
                            y: .value("kcal", kcal)
                        )
                        .foregroundStyle(Color.pulseAccent.opacity(day.state == "partial" ? 0.35 : 0.85))
                    }
                }
                ForEach(nutrition.series) { day in
                    if let expenditure = day.expenditure, let date = dashboardDate(from: day.date) {
                        LineMark(
                            x: .value("Date", date, unit: .day),
                            y: .value("Dépense", expenditure)
                        )
                        .foregroundStyle(DashboardMetricColor.stress)
                        .interpolationMethod(.monotone)
                    }
                }
            }
            .frame(height: 160)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { AxisValueLabel(format: .dateTime.day().month()) }
            }

            DashboardLegendRow(items: [
                (Color.pulseAccent.opacity(0.85), "journée complète"),
                (Color.pulseAccent.opacity(0.35), "journée partielle"),
                (DashboardMetricColor.stress, "dépense estimée"),
            ])

            Text("Les barres pâles sont des journées partiellement saisies : elles ne comptent pas dans la moyenne. Les jours sans aucune saisie restent vides plutôt que comptés à zéro.")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

private struct DashboardMacrosCard: View {
    let macros: [DashboardMacro]
    let completeDays: Int

    var body: some View {
        PulseCard {
            HStack {
                SectionHeader("Répartition macros")
                Spacer()
                Text("moyenne \(completeDays) j")
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            DashboardProportionBar(segments: macros.map { (dashboardMacroColor($0.key), $0.pct) })
            VStack(spacing: PulseSpacing.sm) {
                ForEach(macros) { macro in
                    HStack {
                        Circle().fill(dashboardMacroColor(macro.key)).frame(width: 9, height: 9)
                        Text(macro.label)
                            .font(.subheadline)
                            .foregroundStyle(Color.pulseTextPrimary)
                        Spacer()
                        Text("\(macro.grams ?? 0) g")
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextSecondary)
                        Text("\(macro.pct) %")
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextSecondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }
}

private struct DashboardLoggingGridCard: View {
    let series: [DashboardNutritionDay]

    private var last30: [DashboardNutritionDay] { Array(series.suffix(30)) }

    private var logRate: Int {
        guard !last30.isEmpty else { return 0 }
        let logged = last30.filter { $0.state != "none" }.count
        return Int((Double(logged) / Double(last30.count) * 100).rounded())
    }

    var body: some View {
        PulseCard {
            HStack {
                SectionHeader("Régularité de saisie")
                Spacer()
                Text("\(logRate) % des 30 derniers jours")
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10), spacing: 4) {
                ForEach(last30) { day in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(for: day.state))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            Text("plein = journée complète · pâle = partielle · vide = rien")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "complete": return DashboardMetricColor.steps
        case "partial": return DashboardMetricColor.steps.opacity(0.4)
        default: return Color.pulseSurfaceAlt
        }
    }
}

private struct DashboardTopFoodsCard: View {
    let nutrition: DashboardNutritionTab

    var body: some View {
        PulseCard {
            HStack {
                SectionHeader("Aliments les plus fréquents")
                Spacer()
                Text("\(nutrition.days) jours · \(nutrition.totalEntries) entrées")
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            if nutrition.topFoods.isEmpty {
                Text("Pas encore d'aliment saisi sur la période.")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                VStack(spacing: PulseSpacing.sm) {
                    ForEach(nutrition.topFoods) { food in
                        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                            HStack {
                                Text(food.name)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.pulseTextPrimary)
                                Spacer()
                                Text("\(food.uses) ×")
                                    .font(PulseFont.metricUnit)
                                    .foregroundStyle(Color.pulseTextSecondary)
                                Text("\(food.kcal) kcal")
                                    .font(PulseFont.metricUnit)
                                    .foregroundStyle(Color.pulseTextSecondary)
                                Text("\(food.protein) g")
                                    .font(PulseFont.metricUnit)
                                    .foregroundStyle(Color.pulseTextSecondary)
                            }
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.pulseSurfaceAlt)
                                    .overlay(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(DashboardMetricColor.calories)
                                            .frame(width: proxy.size.width * CGFloat(food.pct) / 100)
                                    }
                            }
                            .frame(height: 8)
                        }
                        .padding(.vertical, PulseSpacing.xs)
                    }
                }
            }
        }
    }
}
