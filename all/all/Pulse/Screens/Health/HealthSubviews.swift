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

    /// Libellé court dans la pastille centrale : « aujourd'hui » sinon « d MMM ».
    private var shortLabel: String {
        viewModel.date == HealthViewModel.todayKey()
            ? "aujourd'hui"
            : HealthViewModel.shortDateLabel(viewModel.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
            HStack(spacing: 6) {
                Button {
                    Task { await viewModel.shiftDay(by: -1) }
                } label: {
                    Text("‹").font(.system(size: 14, design: .monospaced))
                }
                .buttonStyle(HealthDayPillStyle())

                Text(shortLabel)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.pulseTextPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color.pulseSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.pulseBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                Button {
                    Task { await viewModel.shiftDay(by: 1) }
                } label: {
                    Text("›").font(.system(size: 14, design: .monospaced))
                }
                .buttonStyle(HealthDayPillStyle())
                .disabled(viewModel.isLastDay)
            }
            Text(viewModel.dateLabel)
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

/// Pastille de navigation de jour — miroir de `NutritionDayPillStyle`
/// (40×40, rayon 11, `pulseSurface`/`pulseBorder`, pâlie quand désactivée).
private struct HealthDayPillStyle: ButtonStyle {
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

// MARK: - Nuit

private enum SleepStageColor {
    /// Miroir des phases `--p-deep/-light/-rem/-awake` (SCSS Pulse) — chaque
    /// phase de sommeil a sa teinte propre, jamais le bleu accent générique.
    static func of(_ stage: SleepStageKind) -> Color {
        switch stage {
        case .deep: return Color.pulseSleepDeep
        case .light: return Color.pulseSleepLight
        case .rem: return Color.pulseSleepRem
        case .awake: return Color.pulseSleepAwake
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

    /// Présentation du rapport SpO2 — miroir du `routerLink="/rapport-spo2"`
    /// (Angular) sur la ligne « SpO2 nocturne ». `Spo2ReportView` gère déjà sa
    /// propre `NavigationStack`/chargement ; on la présente en feuille, comme
    /// depuis le hub Système (`SystemMenuView`), sans dépendance croisée.
    @State private var showingSpo2Report = false

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
                    // Maquette « Santé » : classe `.n44` (44px) — un jeton dédié,
                    // plus grand que `PulseFont.metricValue` (36, générique
                    // StatTile), sans toucher à `DesignSystem.swift`.
                    Text(HealthViewModel.sleepShort(main.durationS))
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.pulseTextPrimary)
                    Spacer()
                    if let score = sleep.score {
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
                if !sleep.stages.isEmpty {
                    stageBar
                    hypnogramAxis
                    stageLegend
                }
                if let spo2 = viewModel.nightSpo2 {
                    Divider()
                    // Miroir de `<a class="spo2-row" routerLink="/rapport-spo2">`
                    // (Angular) — toute la ligne est cliquable, chevron `--absent`.
                    Button {
                        showingSpo2Report = true
                    } label: {
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
            .sheet(isPresented: $showingSpo2Report) {
                Spo2ReportView()
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

    /// Repères horaires sous l'hypnogramme — miroir de `hyp.ticks` (Angular) :
    /// un repère à chaque heure pleine traversée par la nuit, simplement
    /// répartis via `justify-content:space-between`, jamais positionnés au
    /// pixel près sur la piste (`t.pos` ne sert qu'au `track` du `@for`).
    private var hypnogramTicks: [String] {
        guard let start = sleep.stages.first?.from,
              let end = sleep.stages.last?.to,
              end > start
        else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var labels: [String] = []
        var t = ((start + 3_599) / 3_600) * 3_600 // Math.ceil(start / 3600) * 3600
        while t <= end {
            let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(t)))
            labels.append("\(hour)h") // miroir `hourFormat` (Angular) — pas d'espace
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
                    if index < ticks.count - 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var stageLegend: some View {
        let breakdown = viewModel.stageBreakdown
        // Miroir `.legend1{grid-template-columns:1fr 1fr}` (Angular) — une
        // grille 2×2, pas une rangée unique (déborde sur les écrans étroits).
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: PulseSpacing.sm), GridItem(.flexible())],
            spacing: PulseSpacing.sm
        ) {
            ForEach([SleepStageKind.deep, .light, .rem, .awake], id: \.self) { stage in
                HStack(spacing: 7) {
                    // Miroir `.lg i{width:10px;height:10px;border-radius:3px}` —
                    // un carré arrondi, pas un rond plein.
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(SleepStageColor.of(stage))
                        .frame(width: 10, height: 10)
                    Text(SleepStageColor.label(stage))
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

// MARK: - Sélecteur de métrique

/// Miroir de `app-seg` (Angular, `seg.component.ts`, variante `tabs` par
/// défaut) : rangée de pilules à largeur égale, celle active en plein
/// (`background:var(--text); color:var(--surface)`) — jamais le `Picker`
/// segmenté système (chrome bleu générique, forme différente de la maquette).
struct MetricTabPicker: View {
    var viewModel: HealthViewModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(HealthViewModel.MetricTab.allCases) { tab in
                let isSelected = tab == viewModel.selectedTab
                Button {
                    viewModel.selectedTab = tab
                } label: {
                    Text(tab.label)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .foregroundStyle(isSelected ? Color.pulseSurface : Color.pulseTextSecondary)
                        .background(isSelected ? Color.pulseTextPrimary : Color.pulseSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(isSelected ? Color.clear : Color.pulseBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
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
                    // Maquette « Santé » : classe `.hero-n` = 32px (pas
                    // `PulseFont.metricValue`, 36 — jeton générique StatTile).
                    Text(headline.value)
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
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

    /// Bornes du jour affiché (00h → 24h) — miroir `dayStart`/`dayEnd`
    /// (Angular) : axe X fixe sur la journée entière, pas une auto-échelle
    /// sur la seule plage des échantillons présents.
    private var dayDomain: ClosedRange<Date> {
        guard let start = HealthViewModel.parseDate(day.date) else {
            let now = Date()
            return now...now.addingTimeInterval(86_400)
        }
        return start...start.addingTimeInterval(86_400)
    }

    // Une couleur par métrique — miroir des `color="var(--m-*)"` passés à
    // `app-stream-chart` dans le template Angular (`health.component.ts`),
    // jamais `pulseAccent` bleu générique.
    @ViewBuilder
    private var chart: some View {
        switch viewModel.selectedTab {
        case .cardio:
            SampleLineChart(samples: day.hr, color: Color.pulseHR, yRange: nil, xDomain: dayDomain)
        case .stress:
            StressBarChart(samples: healthStressBuckets(day.stress), xDomain: dayDomain)
        case .energie:
            SampleLineChart(samples: day.bodyBatteryPivot, color: Color.pulseBattery, yRange: 0...100, xDomain: dayDomain)
        case .spo2:
            SampleLineChart(samples: day.spo2, color: Color.pulseSpo2, yRange: nil, xDomain: dayDomain)
        case .respiration:
            SampleLineChart(samples: day.respiration, color: Color.pulseResp, yRange: nil, xDomain: dayDomain)
        case .calories:
            CaloriesSummary(viewModel: viewModel)
        }
    }
}

// MARK: - Axes des graphiques (Santé)

private extension View {
    /// Habillage d'axes commun aux graphiques temporels de l'écran Santé —
    /// miroir de `hourFormat` (Angular, `health.component.ts`) : cinq repères
    /// 0h/6h/12h/18h/24h en bas, deux lignes de référence horizontales
    /// discrètes, aucun axe Y chiffré (même lecture que le SVG de la
    /// maquette « Santé » — pas de grille complète, pas de bordure de zone).
    func healthChartAxes(domain: ClosedRange<Date>) -> some View {
        chartXScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: stride(from: 0, through: 24, by: 6).map {
                    domain.lowerBound.addingTimeInterval(TimeInterval($0) * 3_600)
                }) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            let hour = Int(date.timeIntervalSince(domain.lowerBound) / 3_600)
                            Text("\(hour)h")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) {
                    AxisGridLine().foregroundStyle(Color.pulseBorder.opacity(0.6))
                }
            }
    }
}

/// Ligne temporelle générique (FC, énergie, SpO2, respiration) — équivalent
/// natif de `app-stream-chart` pour les séries continues.
struct SampleLineChart: View {
    let samples: [WellnessSample]
    let color: Color
    let yRange: ClosedRange<Double>?
    let xDomain: ClosedRange<Date>

    var body: some View {
        if samples.isEmpty {
            emptyState
        } else {
            Chart(samples, id: \.ts) { sample in
                // Aire sous la courbe teintée métrique — miroir de l'attribut
                // `fill-opacity="0.16"` sur `<path [attr.d]="areaPath()">`
                // dans `stream-chart.component.ts`.
                AreaMark(
                    x: .value("Heure", Date(timeIntervalSince1970: TimeInterval(sample.ts))),
                    y: .value("Valeur", sample.value)
                )
                .foregroundStyle(color.opacity(0.16))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Heure", Date(timeIntervalSince1970: TimeInterval(sample.ts))),
                    y: .value("Valeur", sample.value)
                )
                .foregroundStyle(color)
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: yRange ?? autoRange)
            .healthChartAxes(domain: xDomain)
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

/// Bucketise le stress en fenêtres de 5 min (moyenne par fenêtre) — miroir de
/// `stressBuckets()` (Angular, `barSeconds:300`). Sans ça, les centaines
/// d'échantillons bruts tracent une forêt de barres fines illisible (le
/// « raté » signalé). Le point retourné est centré sur sa fenêtre.
private func healthStressBuckets(_ samples: [WellnessSample]) -> [WellnessSample] {
    guard !samples.isEmpty else { return [] }
    let bucket = 300.0
    var sums: [Double: (sum: Double, count: Int)] = [:]
    for s in samples {
        let key = (s.ts / bucket).rounded(.down) * bucket
        let cur = sums[key] ?? (0, 0)
        sums[key] = (cur.sum + s.value, cur.count + 1)
    }
    return sums.keys.sorted().map { key in
        let agg = sums[key]!
        return WellnessSample(ts: key + bucket / 2, value: agg.sum / Double(agg.count))
    }
}

/// Barres de stress colorées par zone — équivalent de `stressBarColor`
/// (Angular) : repos / bas / moyen / élevé.
struct StressBarChart: View {
    let samples: [WellnessSample]
    let xDomain: ClosedRange<Date>

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
            .healthChartAxes(domain: xDomain)
        }
    }

    /// Miroir de `stressBarColor` (Angular) — 4 zones `--s-rest/-low/-mid/-high`.
    private func zoneColor(_ value: Double) -> Color {
        switch value {
        case ..<25: return Color.pulseStressRest
        case ..<50: return Color.pulseStressLow
        case ..<75: return Color.pulseStressMid
        default: return Color.pulseStressHigh
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
        // Une seule teinte « calories » (miroir `--m-cal`/`--c-cal`), déclinée
        // en opacité pour distinguer actif/passif — comme `calories-chart
        // .component.ts` (barres `var(--c-cal)` pleines vs.
        // `color-mix(var(--m-cal) 34%, transparent)` pour la base de repos) :
        // jamais de vert/bleu accent pour une métrique calorique.
        HStack(spacing: PulseSpacing.lg) {
            StatTile(label: "Actives", value: formatted(viewModel.activeCalories), unit: "kcal", accent: Color.pulseCalories)
            StatTile(label: "Passives", value: formatted(viewModel.passiveCalories), unit: "kcal", accent: Color.pulseCalories.opacity(0.55))
            StatTile(label: "Total", value: formatted(viewModel.totalCalories), unit: "kcal", accent: Color.pulseCalories)
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

                if !intensity.bouts.isEmpty {
                    trackBar(intensity)
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
                                    // Miroir de `.tag` (Angular) : teinte FC
                                    // (`--m-hr`), pas l'accent bleu générique.
                                    Text("vigoureux")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.pulseHR.opacity(0.14))
                                        .foregroundStyle(Color.pulseHR)
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

    // MARK: - Piste des blocs (miroir simplifié de `.track`/`.blk` Angular)
    //
    // Segments proportionnels sur la journée entière (`00h → 24h`) ; le
    // recadrage sur la plage active (`window()` côté `IntensityDayCardComponent`)
    // n'est volontairement pas reproduit ici — divergence assumée pour
    // contenir le portage, la teinte FC (`--m-hr`) reste la même.
    private struct TrackSegment: Hashable {
        let fraction: Double
        let color: Color
    }

    private func trackBar(_ intensity: IntensityDayDetail) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(trackSegments(intensity).enumerated()), id: \.offset) { _, segment in
                    Capsule()
                        .fill(segment.color)
                        .frame(width: max(geometry.size.width * segment.fraction, segment.color == .clear ? 0 : 2))
                }
            }
        }
        .frame(height: 24)
        .background(Color.pulseSurfaceAlt, in: Capsule())
        .clipShape(Capsule())
    }

    private func dayBounds(_ dateKey: String) -> (start: Double, end: Double) {
        guard let start = HealthViewModel.parseDate(dateKey)?.timeIntervalSince1970 else {
            return (0, 86_400)
        }
        return (start, start + 86_400)
    }

    private func trackSegments(_ intensity: IntensityDayDetail) -> [TrackSegment] {
        let bounds = dayBounds(intensity.date)
        let span = max(bounds.end - bounds.start, 1)
        var segments: [TrackSegment] = []
        var cursor = bounds.start
        for bout in intensity.bouts.sorted(by: { $0.from < $1.from }) {
            let from = max(Double(bout.from), bounds.start)
            let to = min(Double(bout.to), bounds.end)
            guard to > cursor else { continue }
            if from > cursor {
                segments.append(TrackSegment(fraction: (from - cursor) / span, color: .clear))
            }
            let color: Color = bout.vigorousMin >= 0.5 ? Color.pulseHR : Color.pulseHR.opacity(0.45)
            segments.append(TrackSegment(fraction: max((to - from) / span, 0.004), color: color))
            cursor = to
        }
        if cursor < bounds.end {
            segments.append(TrackSegment(fraction: (bounds.end - cursor) / span, color: .clear))
        }
        return segments
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
                // Maquette / SCSS Pulse : classe `.weigh .n44` (44px), même
                // jeton que la durée de sommeil — pas `PulseFont.metricValue`.
                if let shown = viewModel.shownWeight {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", shown))
                            .font(.system(size: 44, weight: .semibold, design: .monospaced))
                            .foregroundStyle(
                                viewModel.dayWeight == nil ? Color.pulseTextSecondary : Color.pulseTextPrimary
                            )
                        Text("kg")
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.pulseTextPrimary)
                }
                Spacer()
                if let delta = viewModel.weightDelta {
                    // Miroir `.delta.down` (perte → succès) / `.delta.up`
                    // (prise → teinte calories, `--m-cal`) — jamais neutre.
                    Text("\(delta > 0 ? "+" : "")\(String(format: "%.1f", delta)) kg")
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(
                            delta < 0 ? Color.pulseSuccess
                                : delta > 0 ? Color.pulseCalories
                                : Color.pulseTextSecondary
                        )
                }
            }

            if let series = viewModel.weight?.series, series.count > 1 {
                WeightLineChart(series: series)
                    .frame(height: 110)
            }

            // Historique des pesées réellement stockées (`weight_log`, via
            // `weight.series`) — au-delà de la courbe de tendance : chaque
            // pesée saisie, la plus récente en tête, tap = aller à ce jour
            // (pour la corriger / l'effacer). Ajout demandé (le web n'a que la
            // courbe) pour « voir les pesées stockées dans la bdd ».
            if let series = viewModel.weight?.series, !series.isEmpty {
                let recent = Array(series.reversed())
                VStack(spacing: 0) {
                    ForEach(recent.prefix(8), id: \.date) { point in
                        Button {
                            Task { await viewModel.selectDate(point.date) }
                        } label: {
                            HStack {
                                Text(HealthViewModel.shortDateLabel(point.date))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(
                                        point.date == viewModel.date ? Color.pulseTextPrimary : Color.pulseTextSecondary
                                    )
                                Spacer()
                                Text("\(String(format: "%.1f", point.kg)) kg")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.pulseTextPrimary)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Color.pulseBorder).frame(height: 0.5)
                        }
                    }
                    if recent.count > 8 {
                        Text("+ \(recent.count - 8) pesée\(recent.count - 8 > 1 ? "s" : "") plus ancienne\(recent.count - 8 > 1 ? "s" : "") — navigue les jours")
                            .font(.caption2)
                            .foregroundStyle(Color.pulseTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, PulseSpacing.xs)
                    }
                }
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
                // Miroir `.watch.on` (Angular) : le statut « transmis » se lit
                // sur `push.status === 'sent'`, pas sur une sous-chaîne du
                // libellé (« non transmis » contient aussi « transmis »).
                Text(note)
                    .font(.caption)
                    .foregroundStyle(
                        viewModel.weight?.push.status == "sent" ? Color.pulseSteps : Color.pulseTextSecondary
                    )
            }
        }
    }
}

struct WeightLineChart: View {
    let series: [WeightSeriesPoint]

    var body: some View {
        // Miroir `color="var(--m-steps)"` (Angular, `health.component.ts`) —
        // la tendance de poids reprend la teinte « pas », pas l'accent bleu.
        Chart(series, id: \.date) { point in
            LineMark(
                x: .value("Date", HealthViewModel.parseDate(point.date) ?? Date()),
                y: .value("Poids", point.avg)
            )
            .foregroundStyle(Color.pulseSteps)
            .interpolationMethod(.monotone)
        }
    }
}
