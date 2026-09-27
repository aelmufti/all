//
//  SommeilView.swift
//  all (bridge-connect)
//
//  Onglet **Sommeil** dédié — écart assumé vs la barre web (cf. `PulseTab`).
//  Pensé « une nuit à la fois » comme l'écran Santé : navigation par nuit +
//  analyse poussée de la nuit sélectionnée (hypnogramme, phases, efficacité,
//  fragmentation, stress nocturne, composition vs référence, écart à la
//  moyenne) + carte « Heure de coucher conseillée » (`sleep-recommendation`).
//

import SwiftUI

struct SommeilView: View {
    @State private var viewModel = SommeilViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.day != nil || !viewModel.days30.isEmpty {
                    content
                } else if let message = viewModel.errorMessage {
                    ErrorView(message: message) { Task { await viewModel.retry() } }
                } else {
                    LoadingView(message: "Chargement du sommeil…")
                }
            }
            .background(Color.pulseBackground)
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await viewModel.load() }
        .refreshesAtDayChange { await viewModel.reloadForNewDay() }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: PulseSpacing.lg) {
                SommeilDayNavigator(viewModel: viewModel)

                if let message = viewModel.errorMessage {
                    DashboardInlineError(message: message) { Task { await viewModel.retry() } }
                }

                if let reco = viewModel.recommendation, reco.isActionable {
                    DashboardSleepRecommendationCard(reco: reco)
                }

                if let main = viewModel.day?.sleep.main {
                    SommeilNightCard(viewModel: viewModel, main: main)
                    SommeilAnalysisCard(viewModel: viewModel)
                    SommeilCompositionCard(rows: viewModel.compositionRows)
                } else {
                    SommeilNoNightCard()
                }
            }
            .padding(PulseSpacing.lg)
        }
        .pulseTabBarClearance()
        .background(Color.pulseBackground)
        .refreshable { await viewModel.load() }
    }
}

// MARK: - Navigation de nuit

private struct SommeilDayNavigator: View {
    var viewModel: SommeilViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
            HStack(alignment: .top, spacing: PulseSpacing.md) {
                Text("Sommeil")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.pulseTextPrimary)
                Spacer()
                HStack(spacing: 6) {
                    Button { Task { await viewModel.shiftDay(by: -1) } } label: {
                        Text("‹").font(.system(size: 14, design: .monospaced))
                    }
                    .buttonStyle(SommeilDayPillStyle())

                    Text(viewModel.shortLabel)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.pulseTextPrimary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, PulseSpacing.md)
                        .frame(height: 40)
                        .background(Color.pulseSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Color.pulseBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                    Button { Task { await viewModel.shiftDay(by: 1) } } label: {
                        Text("›").font(.system(size: 14, design: .monospaced))
                    }
                    .buttonStyle(SommeilDayPillStyle())
                    .disabled(viewModel.isLastDay)
                }
            }
            Text(viewModel.dateLabel)
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

private struct SommeilDayPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 40, height: 40)
            .foregroundStyle(isEnabled ? Color.pulseTextSecondary : Color.pulseAbsent)
            .background(isEnabled ? Color.pulseSurface : Color.pulseSurfaceAlt)
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.pulseBorder.opacity(isEnabled ? 1 : 0.6), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Couleurs de phase (le helper de l'écran Santé est privé — dupliqué ici)

private func sommeilStageColor(_ stage: SleepStageKind) -> Color {
    switch stage {
    case .deep: return .pulseSleepDeep
    case .light: return .pulseSleepLight
    case .rem: return .pulseSleepRem
    case .awake: return .pulseSleepAwake
    }
}

private func sommeilStageLabel(_ stage: SleepStageKind) -> String {
    switch stage {
    case .deep: return "Profond"
    case .light: return "Léger"
    case .rem: return "Paradoxal"
    case .awake: return "Éveillé"
    }
}

// MARK: - Carte nuit (durée, score, hypnogramme, phases, SpO2)

private struct SommeilNightCard: View {
    var viewModel: SommeilViewModel
    let main: SleepMain

    @State private var showingSpo2Report = false

    private var stages: [SleepStageInterval] { viewModel.day?.sleep.stages ?? [] }
    private var totalStageDuration: Double {
        stages.reduce(0) { $0 + Double($1.to - $1.from) }
    }

    var body: some View {
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
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.pulseTextPrimary)
                Spacer()
                if let score = viewModel.day?.sleep.score {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(Int(score.rounded()))")
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.pulseSleep)
                        Text("/100")
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }
            }

            if let delta = viewModel.deltaToAvgS {
                Text(deltaLabel(delta))
                    .font(.footnote)
                    .foregroundStyle(abs(delta) < 900 ? Color.pulseTextSecondary
                                     : (delta < 0 ? Color.pulseDanger : Color.pulseSuccess))
            }

            if !stages.isEmpty {
                stageBar
                hypnogramAxis
                stageLegend
            }

            if let spo2 = viewModel.nightSpo2 {
                Divider()
                Button { showingSpo2Report = true } label: {
                    HStack {
                        Text("SpO2 nocturne")
                            .font(.footnote)
                            .foregroundStyle(Color.pulseTextSecondary)
                        Spacer()
                        Text("\(spo2.mean) % · \(spo2.min) – \(spo2.max)")
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextPrimary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.pulseAbsent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showingSpo2Report) { Spo2ReportView() }
    }

    private func deltaLabel(_ delta: Double) -> String {
        let minutes = Int(abs(delta) / 60)
        if minutes < 15 { return "≈ ta moyenne des 30 dernières nuits" }
        let hm = "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
        return delta < 0 ? "− \(hm) sous ta moyenne 30 nuits" : "+ \(hm) au-dessus de ta moyenne 30 nuits"
    }

    private var stageBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(Array(stages.enumerated()), id: \.offset) { _, stage in
                    let duration = Double(stage.to - stage.from)
                    let fraction = totalStageDuration > 0 ? duration / totalStageDuration : 0
                    Rectangle()
                        .fill(sommeilStageColor(stage.stage))
                        .frame(width: max(geometry.size.width * fraction, 1))
                }
            }
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous))
    }

    private var hypnogramTicks: [String] {
        guard let start = stages.first?.from, let end = stages.last?.to, end > start else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var labels: [String] = []
        var t = ((start + 3_599) / 3_600) * 3_600
        while t <= end {
            let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(t)))
            labels.append("\(hour)h")
            t += 3_600
        }
        return labels
    }

    @ViewBuilder
    private var hypnogramAxis: some View {
        let ticks = hypnogramTicks
        if !ticks.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(ticks.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.pulseTextSecondary)
                    if index < ticks.count - 1 { Spacer(minLength: 0) }
                }
            }
        }
    }

    private var stageLegend: some View {
        let breakdown = viewModel.stageBreakdown
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: PulseSpacing.sm), GridItem(.flexible())],
            spacing: PulseSpacing.sm
        ) {
            ForEach([SleepStageKind.deep, .light, .rem, .awake], id: \.self) { stage in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(sommeilStageColor(stage))
                        .frame(width: 10, height: 10)
                    Text(sommeilStageLabel(stage))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.pulseTextSecondary)
                    Spacer(minLength: 0)
                    if let breakdown {
                        Text("\(breakdown.percent(part(of: stage, in: breakdown)))%")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
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

// MARK: - Analyse poussée (efficacité, fragmentation, stress nocturne)

private struct SommeilAnalysisCard: View {
    var viewModel: SommeilViewModel

    var body: some View {
        if let stats = viewModel.nightStats {
            PulseCard {
                DashboardCardHeader("Analyse de la nuit")

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: PulseSpacing.md
                ) {
                    figure("Efficacité", "\(stats.efficiencyPct)", unit: "%",
                           tint: stats.efficiencyPct >= 85 ? .pulseSuccess
                               : (stats.efficiencyPct >= 75 ? .pulseTextPrimary : .pulseDanger))
                    figure("Au lit", hm(stats.inBedS))
                    figure("Éveil (WASO)", "\(stats.awakeS / 60)", unit: "min",
                           tint: stats.awakeS / 60 > 45 ? .pulseDanger : .pulseTextPrimary)
                    figure("Réveils", "\(stats.arousals)")
                    figure("Plus long éveil", "\(stats.longestAwakeS / 60)", unit: "min")
                    if let stress = stats.avgNightStress {
                        figure("Stress nuit", "\(stress)",
                               tint: stress > 30 ? .pulseDanger : .pulseSuccess)
                    }
                }

                Text(summary(stats))
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }

    private func figure(_ label: String, _ value: String, unit: String? = nil, tint: Color = .pulseTextPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Color.pulseTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hm(_ seconds: Int) -> String {
        "\(seconds / 3600) h \(String(format: "%02d", (seconds % 3600) / 60))"
    }

    private func summary(_ stats: NightStatsAlias) -> String {
        var parts: [String] = []
        parts.append(stats.efficiencyPct >= 85
            ? "Bonne efficacité : tu passes l'essentiel de ton temps au lit à dormir."
            : "Efficacité perfectible : une part notable du temps au lit est passée éveillé.")
        if stats.arousals >= 1 {
            parts.append("\(stats.arousals) réveil\(stats.arousals > 1 ? "s" : "") pour \(stats.awakeS / 60) min éveillé au total.")
        }
        if let s = stats.avgNightStress {
            parts.append(s > 30
                ? "Stress nocturne élevé (\(s)) — la récupération a pu en pâtir."
                : "Stress nocturne bas (\(s)) — bon signe de récupération.")
        }
        return parts.joined(separator: " ")
    }
}

/// Alias local vers le type imbriqué du view-model (lisibilité de `summary`).
private typealias NightStatsAlias = SommeilViewModel.NightStats

// MARK: - Composition vs référence

private struct SommeilCompositionCard: View {
    let rows: [SommeilViewModel.CompositionRow]

    var body: some View {
        if !rows.isEmpty {
            PulseCard {
                DashboardCardHeader("Composition vs référence")
                VStack(spacing: PulseSpacing.md) {
                    ForEach(rows) { row in
                        HStack(spacing: PulseSpacing.sm) {
                            Text(row.label)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.pulseTextSecondary)
                                .frame(width: 74, alignment: .leading)
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.pulseSurfaceAlt)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(row.out ? Color.pulseDanger : phaseColor(row.label))
                                        .frame(width: proxy.size.width * CGFloat(min(max(Double(row.pct) / 100, 0), 1)))
                                    Rectangle()
                                        .fill(Color.pulseTextPrimary.opacity(0.35))
                                        .frame(width: 2)
                                        .offset(x: proxy.size.width * CGFloat(Double(row.lo + row.hi) / 200))
                                }
                            }
                            .frame(height: 8)
                            Text("\(row.pct) %")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(row.out ? Color.pulseDanger : Color.pulseTextPrimary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
                Text("Le trait vertical marque la fourchette de référence (indicative, varie avec l'âge). En part du sommeil réel de cette nuit.")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }

    private func phaseColor(_ label: String) -> Color {
        switch label {
        case "Profond": return .pulseSleepDeep
        case "Léger": return .pulseSleepLight
        case "Paradoxal": return .pulseSleepRem
        default: return .pulseSleep
        }
    }
}

// MARK: - Nuit sans données

private struct SommeilNoNightCard: View {
    var body: some View {
        PulseCard {
            DashboardCardHeader("Nuit")
            Text("Pas de nuit mesurée pour cette date. Navigue vers une autre nuit, ou synchronise la montre.")
                .font(PulseFont.body)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

#Preview {
    SommeilView()
}
