//
//  HealthSubviews.swift
//  all (bridge-connect)
//
//  Sous-vues de l'écran Santé : nuit + hypnogramme, sélecteur de métrique,
//  carte de graphique (FC/stress/énergie/SpO2/respiration/calories), minutes
//  d'intensité, poids. Miroir des blocs `.card` de `health.component.ts`,
//  traduits en `PulseCard`/`StatTile` (DesignSystem) + Swift Charts pour les
//  séries temporelles (équivalent natif de `app-stream-chart`).
//

import SwiftUI
import Charts

// MARK: - Navigation de jour

struct HealthDayNavigator: View {
    var viewModel: HealthViewModel

    private var selectedDate: Binding<Date> {
        Binding(
            get: { HealthViewModel.parseDate(viewModel.date) ?? Date() },
            set: { newDate in
                Task { await viewModel.selectDate(HealthViewModel.formatDate(newDate)) }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
            HStack(spacing: PulseSpacing.sm) {
                Button {
                    Task { await viewModel.shiftDay(by: -1) }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)

                DatePicker(
                    "Jour",
                    selection: selectedDate,
                    in: ...(HealthViewModel.parseDate(viewModel.maxDate) ?? Date()),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .frame(maxWidth: .infinity)

                Button {
                    Task { await viewModel.shiftDay(by: 1) }
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLastDay)
            }
            Text(viewModel.dateLabel)
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

// MARK: - Nuit

private enum SleepStageColor {
    static func of(_ stage: SleepStageKind) -> Color {
        switch stage {
        case .deep: return Color.pulseAccent
        case .light: return Color.pulseAccent.opacity(0.45)
        case .rem: return Color.purple
        case .awake: return Color.pulseDanger.opacity(0.6)
        }
    }

    static func label(_ stage: SleepStageKind) -> String {
        switch stage {
        case .deep: return "Profond"
        case .light: return "Léger"
        case .rem: return "Paradoxal"
        case .awake: return "Éveillé"
        }
    }
}

struct SleepCard: View {
    var viewModel: HealthViewModel
    let sleep: WellnessDaySleep

    var body: some View {
        if let main = sleep.main {
            PulseCard {
                HStack {
                    Text("NUIT")
                        .font(PulseFont.metricLabel)
                        .foregroundStyle(Color.pulseTextSecondary)
                        .tracking(0.6)
                    Spacer()
                    Text("\(HealthViewModel.clock(main.from)) → \(HealthViewModel.clock(main.to))")
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                HStack(alignment: .lastTextBaseline) {
                    Text(HealthViewModel.sleepShort(main.durationS))
                        .font(PulseFont.metricValue)
                        .foregroundStyle(Color.pulseTextPrimary)
                    Spacer()
                    if let score = sleep.score {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(Int(score.rounded()))")
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.pulseAccent)
                            Text("/100")
                                .font(PulseFont.metricUnit)
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                    }
                }
                if !sleep.stages.isEmpty {
                    stageBar
                    stageLegend
                }
                if let spo2 = viewModel.nightSpo2 {
                    Divider()
                    HStack {
                        Text("SpO2 nocturne")
                            .font(.footnote)
                            .foregroundStyle(Color.pulseTextSecondary)
                        Spacer()
                        Text("\(spo2.mean) % · \(spo2.min) – \(spo2.max)")
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextPrimary)
                    }
                }
            }
        }
    }

    private var totalStageDuration: Double {
        sleep.stages.reduce(0) { $0 + Double($1.to - $1.from) }
    }

    private var stageBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(Array(sleep.stages.enumerated()), id: \.offset) { _, stage in
                    let duration = Double(stage.to - stage.from)
                    let fraction = totalStageDuration > 0 ? duration / totalStageDuration : 0
                    Rectangle()
                        .fill(SleepStageColor.of(stage.stage))
                        .frame(width: max(geometry.size.width * fraction, 1))
                }
            }
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous))
    }

    private var stageLegend: some View {
        let breakdown = viewModel.stageBreakdown
        return HStack(spacing: PulseSpacing.md) {
            ForEach([SleepStageKind.deep, .light, .rem, .awake], id: \.self) { stage in
                HStack(spacing: 5) {
                    Circle().fill(SleepStageColor.of(stage)).frame(width: 8, height: 8)
                    Text(SleepStageColor.label(stage))
                        .font(.caption)
                        .foregroundStyle(Color.pulseTextSecondary)
                    if let breakdown {
                        Text("\(breakdown.percent(part(of: stage, in: breakdown)))%")
                            .font(.caption.bold())
                            .foregroundStyle(Color.pulseTextPrimary)
                    }
                }
            }
        }
    }

    private func part(of stage: SleepStageKind, in breakdown: HealthViewModel.StageBreakdown) -> Int {
        switch stage {
        case .deep: return breakdown.deep
        case .light: return breakdown.light
        case .rem: return breakdown.rem
        case .awake: return breakdown.awake
        }
    }
}

// MARK: - Sélecteur de métrique

struct MetricTabPicker: View {
    @Bindable var viewModel: HealthViewModel

    var body: some View {
        Picker("Métrique", selection: $viewModel.selectedTab) {
            ForEach(HealthViewModel.MetricTab.allCases) { tab in
                Text(tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Carte de graphique

struct HealthMetricChartCard: View {
    var viewModel: HealthViewModel
    let day: WellnessDayDetail

    var body: some View {
        PulseCard {
            let headline = viewModel.metricHeadline
            HStack(alignment: .lastTextBaseline) {
                HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.xs) {
                    Text(headline.value)
                        .font(PulseFont.metricValue)
                        .foregroundStyle(Color.pulseTextPrimary)
                        .lineLimit(1)
                    Text(headline.unit)
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                Spacer()
                if !headline.range.isEmpty {
                    Text(headline.range)
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            chart
                .frame(height: 180)
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch viewModel.selectedTab {
        case .cardio:
            SampleLineChart(samples: day.hr, color: Color.pulseAccent, yRange: nil)
        case .stress:
            StressBarChart(samples: day.stress)
        case .energie:
            SampleLineChart(samples: day.bodyBatteryPivot, color: Color.pulseSuccess, yRange: 0...100)
        case .spo2:
            SampleLineChart(samples: day.spo2, color: Color.pulseAccent, yRange: nil)
        case .respiration:
            SampleLineChart(samples: day.respiration, color: Color.pulseAccent, yRange: nil)
        case .calories:
            CaloriesSummary(viewModel: viewModel)
        }
    }
}

/// Ligne temporelle générique (FC, énergie, SpO2, respiration) — équivalent
/// natif de `app-stream-chart` pour les séries continues.
struct SampleLineChart: View {
    let samples: [WellnessSample]
    let color: Color
    let yRange: ClosedRange<Double>?

    var body: some View {
        if samples.isEmpty {
            emptyState
        } else {
            Chart(samples, id: \.ts) { sample in
                LineMark(
                    x: .value("Heure", Date(timeIntervalSince1970: TimeInterval(sample.ts))),
                    y: .value("Valeur", sample.value)
                )
                .foregroundStyle(color)
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: yRange ?? autoRange)
        }
    }

    private var autoRange: ClosedRange<Double> {
        let values = samples.map(\.value)
        let lower = values.min() ?? 0
        let upper = values.max() ?? 1
        guard lower < upper else { return (lower - 1)...(lower + 1) }
        let pad = (upper - lower) * 0.1
        return (lower - pad)...(upper + pad)
    }

    private var emptyState: some View {
        Text("Aucune donnée pour ce jour.")
            .font(.footnote)
            .foregroundStyle(Color.pulseTextSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Barres de stress colorées par zone — équivalent de `stressBarColor`
/// (Angular) : repos / bas / moyen / élevé.
struct StressBarChart: View {
    let samples: [WellnessSample]

    var body: some View {
        if samples.isEmpty {
            Text("Aucune donnée pour ce jour.")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(samples, id: \.ts) { sample in
                BarMark(
                    x: .value("Heure", Date(timeIntervalSince1970: TimeInterval(sample.ts))),
                    y: .value("Stress", sample.value)
                )
                .foregroundStyle(zoneColor(sample.value))
            }
            .chartYScale(domain: 0...100)
        }
    }

    private func zoneColor(_ value: Double) -> Color {
        switch value {
        case ..<25: return Color.pulseSuccess
        case ..<50: return Color.pulseAccent
        case ..<75: return Color.orange
        default: return Color.pulseDanger
        }
    }
}

/// Simplification native du triptyque actives/passives/total (l'Angular
/// répartit aussi ces calories heure par heure sur un graphique en barres —
/// pas reproduit ici, cf. rendu de l'agent : la répartition horaire pondérée
/// par la FC n'apporte pas assez à cet écran pour justifier son coût de
/// portage).
struct CaloriesSummary: View {
    var viewModel: HealthViewModel

    var body: some View {
        HStack(spacing: PulseSpacing.lg) {
            StatTile(label: "Actives", value: formatted(viewModel.activeCalories), unit: "kcal", accent: Color.pulseAccent)
            StatTile(label: "Passives", value: formatted(viewModel.passiveCalories), unit: "kcal", accent: Color.pulseTextSecondary)
            StatTile(label: "Total", value: formatted(viewModel.totalCalories), unit: "kcal", accent: Color.pulseSuccess)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(Int(value.rounded()))
    }
}

// MARK: - Minutes d'intensité

struct IntensityCard: View {
    let intensity: IntensityDayDetail?
    let failed: Bool

    var body: some View {
        PulseCard {
            SectionHeader("Minutes d'intensité") {
                if let intensity {
                    Text("FC mesurée sur \(Int((intensity.coverage * 100).rounded())) %")
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            if let intensity {
                HStack(alignment: .lastTextBaseline) {
                    HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.xs) {
                        Text("\(Int(intensity.minutes.rounded()))")
                            .font(PulseFont.metricValue)
                            .foregroundStyle(Color.pulseTextPrimary)
                        Text("min")
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    Spacer()
                    if intensity.minutes > 0 {
                        Text(splitLabel(intensity))
                            .font(.footnote)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }

                if intensity.bouts.isEmpty {
                    Text(
                        "Aucun effort de \(Int(intensity.params.minBoutS / 60)) minutes d'affilée " +
                        "au-dessus de \(Int(intensity.params.moderateBpm)) bpm ce jour-là."
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
                } else {
                    VStack(alignment: .leading, spacing: PulseSpacing.sm) {
                        ForEach(Array(intensity.bouts.enumerated()), id: \.offset) { _, bout in
                            HStack(spacing: PulseSpacing.sm) {
                                Text("\(HealthViewModel.clock(bout.from)) – \(HealthViewModel.clock(bout.to))")
                                    .font(PulseFont.metricUnit)
                                    .foregroundStyle(Color.pulseTextPrimary)
                                if bout.vigorousMin >= 0.5 {
                                    Text("vigoureux")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.pulseAccent.opacity(0.15))
                                        .foregroundStyle(Color.pulseAccent)
                                        .clipShape(Capsule())
                                }
                                Spacer()
                                Text("\(Int(bout.minutes.rounded())) min")
                                    .font(PulseFont.metricUnit)
                                    .foregroundStyle(Color.pulseTextPrimary)
                            }
                        }
                    }
                }

                if intensity.coverage < intensity.params.minCoverage {
                    Text(
                        "La FC n'a été mesurée que sur \(Int((intensity.coverage * 100).rounded())) % " +
                        "de la journée : ce cumul est sous-estimé, pas forcément votre activité."
                    )
                    .font(.caption)
                    .foregroundStyle(Color.pulseTextSecondary)
                }
            } else if failed {
                Text("Minutes d'intensité indisponibles.")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                Text("Calcul en cours…")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }

    private func splitLabel(_ detail: IntensityDayDetail) -> String {
        var parts: [String] = []
        if detail.moderateMin >= 0.5 { parts.append("\(Int(detail.moderateMin.rounded())) modérées") }
        if detail.vigorousMin >= 0.5 { parts.append("\(Int(detail.vigorousMin.rounded())) vigoureuses ×2") }
        return parts.isEmpty ? "aucune minute comptée" : parts.joined(separator: " + ")
    }
}

// MARK: - Poids

struct WeightCard: View {
    @Bindable var viewModel: HealthViewModel

    var body: some View {
        PulseCard {
            HStack {
                Text("POIDS")
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
                    .tracking(0.6)
                Spacer()
                Text(viewModel.weighLabel)
                    .font(PulseFont.metricUnit)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            HStack(alignment: .lastTextBaseline) {
                if let shown = viewModel.shownWeight {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", shown))
                            .font(PulseFont.metricValue)
                            .foregroundStyle(
                                viewModel.dayWeight == nil ? Color.pulseTextSecondary : Color.pulseTextPrimary
                            )
                        Text("kg")
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                } else {
                    Text("—").font(PulseFont.metricValue).foregroundStyle(Color.pulseTextPrimary)
                }
                Spacer()
                if let delta = viewModel.weightDelta {
                    Text("\(delta > 0 ? "+" : "")\(String(format: "%.1f", delta)) kg")
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(delta < 0 ? Color.pulseSuccess : Color.pulseTextSecondary)
                }
            }

            if let series = viewModel.weight?.series, series.count > 1 {
                WeightLineChart(series: series)
                    .frame(height: 110)
            }

            HStack(spacing: PulseSpacing.sm) {
                TextField("kg", text: $viewModel.weightInputText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                Button(viewModel.dayWeight != nil ? "Corriger" : "Enregistrer") {
                    Task { await viewModel.saveWeight() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.pulseAccent)
                .disabled(viewModel.weightInputText.isEmpty || viewModel.isSavingWeight)
            }

            HStack(alignment: .firstTextBaseline) {
                if let message = viewModel.weightMessage {
                    Text(message).font(.caption).foregroundStyle(Color.pulseTextSecondary)
                } else if let series = viewModel.weight?.series, series.count > 1 {
                    Text("\(series.count) pesées · la ligne suit la moyenne 7 jours")
                        .font(.caption)
                        .foregroundStyle(Color.pulseTextSecondary)
                } else {
                    Text("Deux pesées suffisent à tracer la tendance.")
                        .font(.caption)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                Spacer()
                if viewModel.dayWeight != nil {
                    Button("effacer") {
                        Task { await viewModel.removeWeight() }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.pulseTextSecondary)
                }
            }

            if let note = viewModel.watchNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(note.contains("transmis") ? Color.pulseAccent : Color.pulseTextSecondary)
            }
        }
    }
}

struct WeightLineChart: View {
    let series: [WeightSeriesPoint]

    var body: some View {
        Chart(series, id: \.date) { point in
            LineMark(
                x: .value("Date", HealthViewModel.parseDate(point.date) ?? Date()),
                y: .value("Poids", point.avg)
            )
            .foregroundStyle(Color.pulseAccent)
            .interpolationMethod(.monotone)
        }
    }
}
