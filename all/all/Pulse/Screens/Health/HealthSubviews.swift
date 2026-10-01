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

/// Point mis en évidence quand le doigt survole un graphique : remplace la
/// valeur de tête (la « dernière valeur ») par la valeur pointée + son heure,
/// puis redevient `nil` au relâchement. Commun à tous les graphes de l'écran
/// Santé (courbes Swift Charts + barres dessinées main).
struct ChartHoverPoint: Equatable {
    let value: Double
    let timeLabel: String
}

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
            // Titre aligné en haut (`.top`) : la pastille de date fait 40pt de
            // haut ; en `.center` le titre était centré dans cette ligne et
            // retombait plus bas que sur les écrans sans pastille.
            HStack(alignment: .top, spacing: PulseSpacing.md) {
                Text("Santé")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.pulseTextPrimary)
                Spacer()
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
                        .fixedSize()
                        .padding(.horizontal, PulseSpacing.md)
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

    /// Valeur pointée au survol du graphique — quand elle est renseignée, la
    /// tête affiche la valeur/l'heure du point touché plutôt que la moyenne.
    @State private var hover: ChartHoverPoint?

    var body: some View {
        PulseCard {
            let headline = viewModel.metricHeadline
            // Au survol : la grosse valeur devient celle du point touché et le
            // libellé de droite affiche son heure (sinon la plage habituelle).
            let value = hover.map { formatValue($0.value) } ?? headline.value
            let detail = hover?.timeLabel ?? headline.range
            HStack(alignment: .lastTextBaseline) {
                HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.xs) {
                    // Maquette « Santé » : classe `.hero-n` = 32px (pas
                    // `PulseFont.metricValue`, 36 — jeton générique StatTile).
                    Text(value)
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.pulseTextPrimary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    Text(headline.unit)
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                Spacer()
                if !detail.isEmpty {
                    Text(detail)
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(hover != nil ? Color.pulseTextPrimary : Color.pulseTextSecondary)
                }
            }
            chart
                .frame(height: 180)
        }
        // Le point survolé n'a de sens que pour l'onglet courant : on le purge
        // au changement de métrique (sinon une valeur cardio resterait affichée
        // sur l'onglet stress).
        .onChange(of: viewModel.selectedTab) { _, _ in hover = nil }
    }

    /// Formatage de la valeur survolée selon l'onglet — miroir de la précision
    /// utilisée par `metricHeadline` (respiration à la décimale, sinon entier).
    private func formatValue(_ v: Double) -> String {
        switch viewModel.selectedTab {
        case .respiration: return String(format: "%.1f", v)
        default: return String(Int(v.rounded()))
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
            SampleLineChart(samples: day.hr, color: Color.pulseHR, yRange: nil, xDomain: dayDomain, hover: $hover)
        case .stress:
            // Barres colorées par zone (repos/bas/moyen/élevé), dessinées à la
            // main comme les calories : Swift Charts rendait les barres vides.
            StressZoneChart(samples: day.stress, dayStart: dayDomain.lowerBound.timeIntervalSince1970, hover: $hover)
        case .energie:
            SampleLineChart(samples: day.bodyBatteryPivot, color: Color.pulseBattery, yRange: 0...100, xDomain: dayDomain, hover: $hover)
        case .spo2:
            SampleLineChart(samples: day.spo2, color: Color.pulseSpo2, yRange: nil, xDomain: dayDomain, hover: $hover)
        case .respiration:
            SampleLineChart(samples: day.respiration, color: Color.pulseResp, yRange: nil, xDomain: dayDomain, hover: $hover)
        case .calories:
            CaloriesSummary(viewModel: viewModel, hover: $hover)
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
    @Binding var hover: ChartHoverPoint?

    /// Position (temporelle) du doigt sur l'axe X — `chartXSelection` renvoie
    /// une date continue ; on recale sur l'échantillon le plus proche.
    @State private var selectedDate: Date?

    /// Progression du tracé gauche→droite (0 = rien, 1 = courbe complète) —
    /// animée à chaque arrivée de nouvelles données (synchro, changement de
    /// source, de jour). Rend visible « les données qui se chargent petit à
    /// petit » : un masque de largeur `width * drawProgress` dévoile la courbe
    /// (ligne + aire) du début de journée vers le plus récent. Cf. `animateDraw`.
    @State private var drawProgress: CGFloat = 0

    var body: some View {
        if samples.isEmpty {
            emptyState
        } else {
            Chart {
                ForEach(samples, id: \.ts) { sample in
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
                // Repère du point survolé : trait vertical + pastille pleine.
                if let sel = selectedSample {
                    RuleMark(x: .value("Heure", Date(timeIntervalSince1970: TimeInterval(sel.ts))))
                        .foregroundStyle(Color.pulseTextSecondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(
                        x: .value("Heure", Date(timeIntervalSince1970: TimeInterval(sel.ts))),
                        y: .value("Valeur", sel.value)
                    )
                    .foregroundStyle(color)
                    .symbolSize(80)
                }
            }
            .chartYScale(domain: yRange ?? autoRange)
            .healthChartAxes(domain: xDomain)
            .chartXSelection(value: $selectedDate)
            .onChange(of: selectedDate) { _, newValue in
                guard let newValue, let sample = nearest(to: newValue) else { hover = nil; return }
                hover = ChartHoverPoint(value: sample.value, timeLabel: HealthViewModel.clock(Int(sample.ts)))
            }
            // Dévoilement gauche→droite : masque dont la largeur suit
            // `drawProgress`. `GeometryReader` place son contenu en haut-gauche,
            // donc le rectangle part du bord gauche (début de journée). Une fois
            // à 1, le masque couvre toute la largeur → aucun rognage résiduel
            // (survol/hit-test intacts).
            .mask(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle().frame(width: geo.size.width * drawProgress)
                }
            }
            .onAppear { animateDraw() }
            .onChange(of: dataSignature) { _, _ in animateDraw() }
        }
    }

    /// Change dès que la série affichée change (nouveau jour, données
    /// synchronisées, bascule de source) — déclencheur du re-tracé. Basé sur le
    /// cardinal + les bornes temporelles : suffisant pour distinguer deux séries
    /// sans hacher toutes les valeurs à chaque rendu.
    private var dataSignature: String {
        "\(samples.count)-\(samples.first?.ts ?? 0)-\(samples.last?.ts ?? 0)"
    }

    /// Relance le tracé : remet la progression à 0 (sans animation), puis anime
    /// jusqu'à 1 au tour de boucle suivant. Le `DispatchQueue.main.async`
    /// garantit que la frame à 0 est bien appliquée avant l'animation — sinon
    /// SwiftUI fusionne les deux mutations et il n'y a aucun balayage visible.
    private func animateDraw() {
        drawProgress = 0
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.65)) { drawProgress = 1 }
        }
    }

    private var selectedSample: WellnessSample? {
        guard let selectedDate else { return nil }
        return nearest(to: selectedDate)
    }

    private func nearest(to date: Date) -> WellnessSample? {
        let t = date.timeIntervalSince1970
        return samples.min { abs($0.ts - t) < abs($1.ts - t) }
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

/// Barres de stress par zone, dessinées à la main (Canvas) sur la journée
/// (00h→24h) — miroir de `stressBarColor`/`barSeconds:300` (web). Chaque
/// fenêtre de 5 min : une barre colorée par zone (repos/bas/moyen/élevé),
/// hauteur = valeur/100. Dessin manuel car Swift Charts rendait les barres
/// vides (comme pour les calories).
private struct StressZoneChart: View {
    let samples: [WellnessSample]
    let dayStart: TimeInterval
    @Binding var hover: ChartHoverPoint?

    /// Fenêtre de 5 min survolée (repérée par son `ts`) — trace un trait
    /// vertical sur la barre pointée.
    @State private var selectedTs: Double?

    private let span: Double = 86_400

    var body: some View {
        let buckets = healthStressBuckets(samples)
        if buckets.isEmpty {
            Text("Aucune donnée pour ce jour.")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                GeometryReader { geo in
                    Canvas { context, size in
                        let slotW = max(size.width * 300 / span, 1)
                        for bucket in buckets {
                            let fx = (bucket.ts - dayStart) / span
                            guard fx >= 0, fx <= 1 else { continue }
                            let barH = min(max(bucket.value / 100, 0), 1) * size.height
                            let rect = CGRect(
                                x: fx * size.width - slotW / 2,
                                y: size.height - barH,
                                width: slotW,
                                height: barH
                            )
                            context.fill(Path(rect), with: .color(zoneColor(bucket.value)))
                        }
                        // Trait vertical sur la fenêtre survolée.
                        if let selectedTs {
                            let fx = (selectedTs - dayStart) / span
                            if fx >= 0, fx <= 1 {
                                let x = fx * size.width
                                context.stroke(
                                    Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                    with: .color(Color.pulseTextSecondary.opacity(0.4)),
                                    lineWidth: 1
                                )
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                let fx = max(0, min(1, g.location.x / max(geo.size.width, 1)))
                                let ts = dayStart + fx * span
                                if let b = buckets.min(by: { abs($0.ts - ts) < abs($1.ts - ts) }) {
                                    selectedTs = b.ts
                                    hover = ChartHoverPoint(value: b.value, timeLabel: HealthViewModel.clock(Int(b.ts)))
                                }
                            }
                            .onEnded { _ in selectedTs = nil; hover = nil }
                    )
                }
                HStack {
                    Text("0h"); Spacer(); Text("6h"); Spacer(); Text("12h"); Spacer(); Text("18h"); Spacer(); Text("24h")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }

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
    @Binding var hover: ChartHoverPoint?

    /// Heure (0–23) survolée — met en évidence sa colonne.
    @State private var selectedHour: Int?

    var body: some View {
        // Histogramme 24 h empilé — base (BMR réparti, translucide) + actif
        // (plein) — miroir de `app-calories-chart`. Dessiné à la main
        // (GeometryReader + rectangles) plutôt qu'en Swift Charts, qui rendait
        // le graphe vide de façon répétée. Chaque colonne : actif au-dessus de
        // la base, aligné en bas.
        let base = viewModel.hourlyBaseCalories
        let active = viewModel.hourlyActiveCalories
        let totals = (0..<24).map { base[$0] + active[$0] }
        let maxVal = max(totals.max() ?? 0, 1)
        if totals.contains(where: { $0 > 0 }) {
            VStack(spacing: 6) {
                GeometryReader { geo in
                    let h = max(geo.size.height, 1)
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(0..<24, id: \.self) { i in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                Rectangle()
                                    .fill(Color.pulseCalories)
                                    .frame(height: CGFloat(active[i] / maxVal) * h)
                                Rectangle()
                                    .fill(Color.pulseCalories.opacity(0.34))
                                    .frame(height: CGFloat(base[i] / maxVal) * h)
                            }
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                            .overlay {
                                // Colonne survolée : liseré discret.
                                if selectedHour == i {
                                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                        .stroke(Color.pulseTextSecondary.opacity(0.5), lineWidth: 1)
                                }
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: h, alignment: .bottom)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                let idx = Int((g.location.x / max(geo.size.width, 1)) * 24)
                                let hour = min(max(idx, 0), 23)
                                selectedHour = hour
                                hover = ChartHoverPoint(value: totals[hour], timeLabel: "\(hour)h")
                            }
                            .onEnded { _ in selectedHour = nil; hover = nil }
                    )
                }
                HStack {
                    Text("0h"); Spacer(); Text("6h"); Spacer(); Text("12h"); Spacer(); Text("18h"); Spacer(); Text("24h")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
            }
        } else {
            Text("Aucune donnée pour ce jour.")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
    /// État de l'écriture du poids vers la montre par le téléphone (upload FIT,
    /// cf. `BLEManager.requestWatchWeightWrite`) — distinct du statut de push
    /// côté serveur (`viewModel.watchNote`, qui ne concerne que le pont homelab).
    @ObservedObject private var ble = BLEManager.shared
    /// Focus du champ de saisie — sert à refermer le pavé numérique dès qu'on
    /// enregistre (le `.decimalPad` iOS n'a pas de touche « retour »).
    @FocusState private var weightFieldFocused: Bool
    /// Pesée survolée sur la courbe de tendance — remplace la grosse valeur du
    /// jour par la pesée pointée (comme les graphes de Santé).
    @State private var weightHover: WeightSeriesPoint?

    private var canSaveWeight: Bool {
        !viewModel.weightInputText.isEmpty && !viewModel.isSavingWeight
    }

    var body: some View {
        PulseCard {
            HStack {
                Text("POIDS")
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
                    .tracking(0.6)
                Spacer()
                Text(weightHover.map { HealthViewModel.shortDateLabel($0.date) } ?? viewModel.weighLabel)
                    .font(PulseFont.metricUnit)
                    .foregroundStyle(weightHover != nil ? Color.pulseTextPrimary : Color.pulseTextSecondary)
            }
            HStack(alignment: .lastTextBaseline) {
                // Maquette / SCSS Pulse : classe `.weigh .n44` (44px), même
                // jeton que la durée de sommeil — pas `PulseFont.metricValue`.
                // Au survol de la courbe : la pesée pointée prime sur celle du jour.
                if let shown = weightHover?.kg ?? viewModel.shownWeight {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", shown))
                            .font(.system(size: 44, weight: .semibold, design: .monospaced))
                            .foregroundStyle(
                                (weightHover == nil && viewModel.dayWeight == nil) ? Color.pulseTextSecondary : Color.pulseTextPrimary
                            )
                            .contentTransition(.numericText())
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
                WeightLineChart(series: series, hover: $weightHover)
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
                    .focused($weightFieldFocused)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.pulseTextPrimary)
                    .padding(.horizontal, PulseSpacing.md)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous)
                            .fill(Color.pulseSurfaceAlt)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous)
                            .stroke(weightFieldFocused ? Color.pulseAccent : Color.pulseBorder, lineWidth: 1)
                    )

                Button {
                    // Referme le pavé numérique puis enregistre.
                    weightFieldFocused = false
                    Task { await viewModel.saveWeight() }
                } label: {
                    Text("Enregistrer")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.pulseOnAccent)
                        .padding(.horizontal, PulseSpacing.lg)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous)
                                .fill(canSaveWeight ? Color.pulseAccent : Color.pulseEmpty)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSaveWeight)
            }

            HStack(alignment: .firstTextBaseline) {
                if let message = viewModel.weightMessage {
                    Text(message).font(.caption).foregroundStyle(Color.pulseTextSecondary)
                } else if let series = viewModel.weight?.series, series.count > 1 {
                    Text("\(series.count) pesées · poids réel saisi")
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

            // Écriture directe téléphone → montre (upload FIT). Ne s'affiche que
            // lorsqu'une écriture est en cours/aboutie/échouée sur ce lien.
            if ble.weightWriteState != .idle {
                HStack(spacing: PulseSpacing.xs) {
                    Image(systemName: watchWriteIcon)
                        .font(.system(size: 11))
                    Text("Montre : \(ble.weightWriteState.label)")
                        .font(.caption)
                }
                .foregroundStyle(watchWriteColor)
            }
        }
    }

    private var watchWriteIcon: String {
        switch ble.weightWriteState {
        case .sent: return "checkmark.circle.fill"
        case .refused, .failed: return "exclamationmark.triangle.fill"
        case .uploading: return "arrow.up.circle"
        default: return "clock"
        }
    }

    private var watchWriteColor: Color {
        switch ble.weightWriteState {
        case .sent: return Color.pulseSteps
        case .refused, .failed: return Color.pulseCalories
        default: return Color.pulseTextSecondary
        }
    }
}

struct WeightLineChart: View {
    let series: [WeightSeriesPoint]
    /// Pesée survolée — remontée au `WeightCard` pour que la grosse valeur
    /// affiche la pesée pointée (et sa date), comme les graphes de Santé.
    @Binding var hover: WeightSeriesPoint?

    @State private var selectedDate: Date?

    /// Domaine Y calé sur les pesées RÉELLES saisies (min → max), avec une
    /// marge, plutôt que l'échelle auto (qui écrasait la courbe en une ligne
    /// plate). On veut « voir » les kilos qui bougent, pas un 0–100.
    private var yDomain: ClosedRange<Double> {
        let values = series.map(\.kg)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if lo == hi { return (lo - 1)...(hi + 1) }
        let margin = max(0.3, (hi - lo) * 0.15)
        return (lo - margin)...(hi + margin)
    }

    var body: some View {
        // Miroir `color="var(--m-steps)"` (Angular, `health.component.ts`) —
        // la tendance de poids reprend la teinte « pas », pas l'accent bleu.
        // On trace les pesées RÉELLES (`kg`), pas la moyenne 7 j lissée.
        Chart {
            ForEach(series, id: \.date) { point in
                LineMark(
                    x: .value("Date", HealthViewModel.parseDate(point.date) ?? Date()),
                    y: .value("Poids", point.kg)
                )
                .foregroundStyle(Color.pulseSteps)
                .interpolationMethod(.monotone)

                PointMark(
                    x: .value("Date", HealthViewModel.parseDate(point.date) ?? Date()),
                    y: .value("Poids", point.kg)
                )
                .foregroundStyle(Color.pulseSteps)
                .symbolSize(18)
            }
            if let sel = selectedPoint, let date = HealthViewModel.parseDate(sel.date) {
                RuleMark(x: .value("Date", date))
                    .foregroundStyle(Color.pulseTextSecondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Date", date), y: .value("Poids", sel.kg))
                    .foregroundStyle(Color.pulseSteps)
                    .symbolSize(80)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $selectedDate)
        .onChange(of: selectedDate) { _, newValue in
            hover = newValue.flatMap { nearest(to: $0) }
        }
    }

    private var selectedPoint: WeightSeriesPoint? {
        guard let selectedDate else { return nil }
        return nearest(to: selectedDate)
    }

    private func nearest(to date: Date) -> WeightSeriesPoint? {
        let t = date.timeIntervalSince1970
        return series.min {
            let a = HealthViewModel.parseDate($0.date)?.timeIntervalSince1970 ?? 0
            let b = HealthViewModel.parseDate($1.date)?.timeIntervalSince1970 ?? 0
            return abs(a - t) < abs(b - t)
        }
    }
}
