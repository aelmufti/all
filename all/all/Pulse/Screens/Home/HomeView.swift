//
//  HomeView.swift
//  all (bridge-connect)
//
//  Écran Accueil — port 1-1 de `custom-connect/web/src/app/pages/home/home.component.ts` :
//  FC « Maintenant » (+ mini-graphe + vitaux), entraînement de la semaine +
//  intensité, séance du jour/à venir, « Depuis le réveil » (pas/calories) et
//  « Nuit dernière » (durée, hypnogramme, régularité du coucher). Trois
//  états : chargement (`LoadingView`), erreur (`ErrorView`), données.
//
//  Couleurs par métrique (cf. `DesignSystem.swift`) : chaque donnée reprend
//  la teinte de sa métrique (FC → `.pulseHR`, stress → `.pulseStress`,
//  SpO2 → `.pulseSpo2`, respiration → `.pulseResp`, pas → `.pulseSteps`,
//  calories → `.pulseCalories`, sommeil → `.pulseSleep`/phases `.pulseSleep*`)
//  — jamais l'accent bleu générique pour une donnée de métrique.
//
//  À brancher dans `PulseShellView`, case `.accueil`, à la place de
//  `ComingSoonView(title: "Accueil", …)` — pas de dépendance de navigation
//  externe : l'écran gère sa propre `NavigationStack`. Divergence assumée vs
//  le web : les liens `routerLink="/programme"` (« Voir le programme »,
//  bande « Coucher moyen ») ne sont pas portés — pas d'API de navigation
//  inter-onglets exposée à cet écran, cf. contrainte de périmètre du prompt.
//

import SwiftUI

struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    /// Menu système (Paramètres, Statut, Rapport SpO2, Montre) — hors barre
    /// d'onglets, accessible par la roue crantée (cf. `PulseShellView`).
    @State private var showSystemMenu = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Accueil")
                .background(Color.pulseBackground)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSystemMenu = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .tint(Color.pulseTextPrimary)
                        .accessibilityLabel("Système")
                    }
                }
                .sheet(isPresented: $showSystemMenu) {
                    SystemMenuView()
                }
        }
        .task { await viewModel.load() }
        .task {
            // FC en direct : rafraîchissement périodique tant que l'écran est
            // visible — annulé automatiquement par SwiftUI à sa disparition.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await viewModel.refreshLive()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingView(message: "Chargement de l'accueil…")
        case .failed(let message):
            ErrorView(message: message) {
                Task { await viewModel.load() }
            }
        case .loaded:
            ScrollView {
                VStack(spacing: PulseSpacing.lg) {
                    NowCard(viewModel: viewModel)
                    WeekTrainingCard(viewModel: viewModel)
                    if let session = viewModel.session {
                        SessionCard(session: session)
                    }
                    WakeCard(viewModel: viewModel)
                    NightCard(viewModel: viewModel)
                }
                .padding(PulseSpacing.lg)
            }
        }
    }
}

/// Couleur par métrique pour les vitaux de « Maintenant » — jamais l'accent
/// bleu générique (cf. en-tête du fichier).
private func vitalAccent(_ id: String) -> Color {
    switch id {
    case "stress": return .pulseStress
    case "spo2": return .pulseSpo2
    case "resp": return .pulseResp
    default: return .pulseAccent
    }
}

// MARK: - « Maintenant » (FC + vitaux)

private struct NowCard: View {
    let viewModel: HomeViewModel

    var body: some View {
        PulseCard {
            HStack {
                SectionHeader(viewModel.staleLabel == nil ? "Maintenant" : "Dernier relevé")
                Spacer()
                if let staleLabel = viewModel.staleLabel {
                    Text(staleLabel)
                        .font(PulseFont.metricLabel)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: PulseSpacing.sm) {
                Text(viewModel.shownHr.map(String.init) ?? "—")
                    .font(.system(size: 52, weight: .semibold, design: .monospaced))
                    .foregroundStyle(viewModel.shownHr == nil ? Color.pulseTextSecondary : Color.pulseHR)
                Text("bpm")
                    .font(PulseFont.metricUnit)
                    .foregroundStyle(Color.pulseTextSecondary)
                if viewModel.live?.heartRate != nil, viewModel.live?.enabled == true,
                    viewModel.live?.reachable == true
                {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(Color.pulseHR)
                        .symbolEffect(.pulse, options: .repeating)
                        .accessibilityLabel("En direct")
                }
            }

            HeartRateSparkline(samples: viewModel.day?.hr ?? [], stale: viewModel.staleLabel != nil)

            Text(nowSubtitle)
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)

            liveControl

            HStack(spacing: PulseSpacing.lg) {
                ForEach(viewModel.vitals) { vital in
                    StatTile(
                        label: vital.label,
                        value: vital.value.map(String.init) ?? "—",
                        unit: vital.value != nil ? vital.unit : nil,
                        accent: vitalAccent(vital.id)
                    )
                }
            }
        }
    }

    private var nowSubtitle: String {
        var parts: [String] = []
        if viewModel.live?.enabled == true, viewModel.live?.reachable == true,
            viewModel.live?.heartRate != nil
        {
            parts.append("en direct")
        } else if let staleLabel = viewModel.staleLabel {
            parts.append("dernier relevé · \(staleLabel)")
        } else if let ago = viewModel.lastReadingLabel {
            parts.append(ago)
        } else {
            parts.append("battements par minute")
        }
        if let rest = viewModel.restingHr {
            parts.append("repos \(rest)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var liveControl: some View {
        HStack(spacing: PulseSpacing.sm) {
            if viewModel.live?.enabled == true {
                Button("Arrêter") { Task { await viewModel.stopLive() } }
                    .font(.footnote)
            } else {
                Button("Reprendre la mesure") { Task { await viewModel.startLive() } }
                    .font(.footnote)
            }
            if let hint = viewModel.live?.hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
        .tint(Color.pulseAccent)
    }
}

/// Mini-graphe FC des 60 derniers relevés du jour — port du `spark()` SVG
/// côté Angular (ligne + aire teintées `.pulseHR`, estompées si périmé,
/// jamais l'accent bleu générique : c'est une donnée FC).
private struct HeartRateSparkline: View {
    let samples: [HomeSample]
    let stale: Bool

    private var points: [HomeSample] { Array(samples.suffix(60)) }

    var body: some View {
        if points.count < 2 {
            EmptyView()
        } else {
            let color: Color = stale ? .pulseTextSecondary : .pulseHR
            GeometryReader { geo in
                let values = points.map(\.value)
                let minValue = values.min() ?? 0
                let span = max((values.max() ?? 0) - minValue, 1)
                let coords = points.enumerated().map { index, sample -> CGPoint in
                    CGPoint(
                        x: geo.size.width * CGFloat(index) / CGFloat(points.count - 1),
                        y: geo.size.height - CGFloat((sample.value - minValue) / span) * geo.size.height)
                }

                Path { path in
                    guard let first = coords.first, let last = coords.last else { return }
                    path.move(to: CGPoint(x: first.x, y: geo.size.height))
                    for point in coords { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.1))

                Path { path in
                    guard let first = coords.first else { return }
                    path.move(to: first)
                    for point in coords.dropFirst() { path.addLine(to: point) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                if let last = coords.last {
                    Circle().fill(color).frame(width: 7, height: 7).position(last)
                }
            }
            .frame(height: 48)
            .opacity(stale ? 0.45 : 1)
        }
    }
}

// MARK: - Entraînement de la semaine (+ intensité)

private struct WeekTrainingCard: View {
    let viewModel: HomeViewModel

    var body: some View {
        PulseCard {
            HStack {
                SectionHeader("Entraînement de la semaine")
                Spacer()
                Text(viewModel.weekRangeLabel)
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            let lead = viewModel.weekLead
            VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                Text(lead.label.uppercased())
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
                HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
                    Text(lead.value)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.pulseTextPrimary)
                    Text(lead.sub)
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }

            WeekProgressChart(
                training: viewModel.trainingShare,
                intensity: viewModel.intensityShare
            )

            if !viewModel.intensityShare.isEmpty {
                HStack(spacing: PulseSpacing.md) {
                    if !viewModel.trainingShare.isEmpty {
                        WeekChartLegend(color: .pulseTextPrimary, label: "Séances")
                    }
                    WeekChartLegend(color: .pulseHR, label: "Intensité")
                }
            }

            VStack(alignment: .leading, spacing: PulseSpacing.sm) {
                ForEach(viewModel.weekFacts) { fact in
                    HStack {
                        Text(fact.name)
                            .font(.footnote)
                            .foregroundStyle(Color.pulseTextPrimary)
                        Spacer()
                        Text(fact.value)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Color.pulseTextPrimary)
                    }
                }
            }
            .padding(.top, PulseSpacing.xs)

            Text(viewModel.weekNote)
                .font(.caption2)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

/// Mini-graphe de progression hebdomadaire — équivalent simplifié du SVG
/// `weekCurve()` côté Angular (deux courbes de part d'objectif, 0 → lundi,
/// 1 → objectif atteint) : le trait plein pour l'entraînement, le pointillé
/// pour l'intensité, une ligne de référence à l'objectif.
private struct WeekProgressChart: View {
    let training: [Double]
    let intensity: [Double]

    private static let headroom = 0.9

    private var top: Double {
        let highest = max(1, max(training.max() ?? 0, intensity.max() ?? 0))
        return highest / Self.headroom
    }

    var body: some View {
        if training.isEmpty && intensity.isEmpty {
            EmptyView()
        } else {
            Canvas { context, size in
                let goalY = size.height * (1 - CGFloat(1 / top))
                var goalPath = Path()
                goalPath.move(to: CGPoint(x: 0, y: goalY))
                goalPath.addLine(to: CGPoint(x: size.width, y: goalY))
                context.stroke(
                    goalPath, with: .color(.pulseBorder),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 5]))

                drawCurve(training, in: &context, size: size, color: .pulseTextPrimary, dash: [])
                // Intensité = zones FC (cf. `.c-int { stroke: var(--m-hr) }` côté
                // web) : couleur métrique FC, jamais l'accent bleu générique.
                drawCurve(intensity, in: &context, size: size, color: .pulseHR, dash: [6, 4])
            }
            .frame(height: 84)
        }
    }

    private func drawCurve(
        _ values: [Double], in context: inout GraphicsContext, size: CGSize, color: Color,
        dash: [CGFloat]
    ) {
        guard !values.isEmpty else { return }
        func point(_ index: Int, _ value: Double) -> CGPoint {
            CGPoint(
                x: size.width * CGFloat(index) / 7,
                y: size.height * (1 - CGFloat(value / top)))
        }
        var path = Path()
        path.move(to: point(0, 0))
        for (i, v) in values.enumerated() {
            path.addLine(to: point(i + 1, v))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: dash))
    }
}

/// Puce de légende du mini-graphe — miroir de `.lg` côté web.
private struct WeekChartLegend: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 14, height: 2)
            Text(label)
                .font(PulseFont.metricLabel)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

// MARK: - Séance (jour ou à venir)

private struct SessionCard: View {
    let session: HomeViewModel.SessionCardModel

    var body: some View {
        PulseCard {
            HStack {
                SectionHeader(session.title)
                Spacer()
                if let when = session.when {
                    Text(when)
                        .font(PulseFont.metricLabel)
                        .foregroundStyle(session.late ? Color.pulseDanger : Color.pulseTextPrimary)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(session.name)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Color.pulseTextPrimary)
                Spacer()
                if let duration = session.duration {
                    Text(duration)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.pulseTextPrimary)
                }
            }

            Text(session.meta)
                .font(PulseFont.metricLabel)
                .foregroundStyle(Color.pulseTextSecondary)

            if session.done {
                Label(session.doneLabel, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseSuccess)
            }

            if let focus = session.focus {
                Text(focus)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            if !session.items.isEmpty {
                VStack(alignment: .leading, spacing: PulseSpacing.sm) {
                    ForEach(session.items, id: \.name) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline)
                                .foregroundStyle(Color.pulseTextPrimary)
                            Text(item.prescription)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                        .padding(.top, PulseSpacing.xs)
                    }
                }
            }
        }
    }
}

// MARK: - Depuis le réveil (pas + calories)

private struct WakeCard: View {
    let viewModel: HomeViewModel

    var body: some View {
        PulseCard {
            SectionHeader("Depuis le réveil")
            HStack(alignment: .top, spacing: PulseSpacing.lg) {
                ForEach(viewModel.wake) { metric in
                    WakeMetricView(metric: metric, accent: Self.accent(for: metric.id))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Couleur par métrique — pas → `.pulseSteps`, calories (brûlées ou
    /// mangées) → `.pulseCalories`, jamais l'accent bleu générique.
    private static func accent(for id: String) -> Color {
        switch id {
        case "steps": return .pulseSteps
        case "burned", "eaten": return .pulseCalories
        default: return .pulseAccent
        }
    }
}

/// Une jauge « Depuis le réveil » : trait vertical + point de position
/// (rythme atteint), valeur et écart au rythme — port de `.metric`/`.wake-gauge`
/// côté web.
private struct WakeMetricView: View {
    let metric: HomeViewModel.WakeMetric
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: PulseSpacing.sm) {
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    Capsule()
                        .fill(Color.pulseSurfaceAlt)
                        .frame(width: 6, height: geo.size.height)
                    if let reached = metric.reached {
                        Circle()
                            .fill(Color.pulseTextPrimary)
                            .frame(width: 11, height: 11)
                            .offset(y: max(geo.size.height - 11, 0) * CGFloat(1 - max(reached, 0)))
                    }
                }
            }
            .frame(width: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(metric.label.uppercased())
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
                Text(metric.value.map { String(Int($0.rounded())) } ?? "—")
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundStyle(metric.value == nil ? Color.pulseTextSecondary : accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let delta = metric.delta {
                    // Écart au rythme : ambre par défaut, succès si tenu —
                    // même choix que `.wake-delta`/`.wake-delta.hit` côté web
                    // (couleur d'écart, pas la couleur de la métrique).
                    Text("\(delta.sign)\(Int(delta.value))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(delta.hit ? Color.pulseSuccess : Color.pulseStress)
                }
            }
        }
        .frame(height: 76)
    }
}

// MARK: - Nuit dernière (durée, hypnogramme, coucher moyen)

private struct NightCard: View {
    let viewModel: HomeViewModel

    var body: some View {
        PulseCard {
            SectionHeader("Nuit dernière")

            if let duration = viewModel.nightDurationLabel {
                HStack(alignment: .firstTextBaseline, spacing: PulseSpacing.sm) {
                    Text(duration)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.pulseSleep)
                    if let delta = viewModel.nightDelta {
                        Text(delta.label)
                            .font(.footnote)
                            .foregroundStyle(delta.short ? Color.pulseDanger : Color.pulseTextSecondary)
                    }
                }
                if let blocks = viewModel.hypnogram {
                    Hypnogram(blocks: blocks)
                }
            } else {
                VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                    Text(viewModel.nightMissing.title)
                        .font(.subheadline)
                        .foregroundStyle(Color.pulseTextPrimary)
                    Text(viewModel.nightMissing.sub)
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }

            if let bedtime = viewModel.bedtime {
                VStack(alignment: .leading, spacing: PulseSpacing.sm) {
                    HStack {
                        SectionHeader("Coucher moyen")
                        Spacer()
                        Text(bedtime.clock)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Color.pulseSleep)
                    }
                    BedtimeSpread(bedtime: bedtime)
                    Text(bedtime.note)
                        .font(.caption2)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                .padding(.top, PulseSpacing.sm)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.pulseBorder).frame(height: 1)
                }
            }
        }
    }
}

/// Barre d'hypnogramme — un segment par phase, largeur proportionnelle à sa
/// durée, teinte par phase (`.pulseSleepDeep/Light/Rem/Awake`, miroir des
/// `--p-*` du web).
private struct Hypnogram: View {
    let blocks: [HomeViewModel.HypnogramBlock]

    var body: some View {
        GeometryReader { geo in
            let total = blocks.reduce(0) { $0 + $1.width }
            HStack(spacing: 0) {
                ForEach(blocks) { block in
                    color(for: block.stage)
                        .frame(width: total > 0 ? geo.size.width * CGFloat(block.width / total) : 0)
                }
            }
        }
        .frame(height: 24)
        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous))
    }

    private func color(for stage: HomeSleepStageKind) -> Color {
        switch stage {
        case .deep: return .pulseSleepDeep
        case .light: return .pulseSleepLight
        case .rem: return .pulseSleepRem
        case .awake: return .pulseSleepAwake
        }
    }
}

/// Bande de régularité du coucher : piste neutre, bande moyenne ± écart type
/// et point moyen teintés `.pulseSleep`, un point par nuit récente — port de
/// `.spread`/`.sp-*` côté web.
private struct BedtimeSpread: View {
    let bedtime: HomeViewModel.Bedtime

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let midY = geo.size.height / 2
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Color.pulseSurfaceAlt)
                        .frame(height: 4)
                        .position(x: geo.size.width / 2, y: midY)

                    Capsule()
                        .fill(Color.pulseSleep.opacity(0.16))
                        .frame(width: max(geo.size.width * CGFloat(bedtime.bandWidth), 0), height: 12)
                        .position(
                            x: geo.size.width * CGFloat(bedtime.bandLeft + bedtime.bandWidth / 2),
                            y: midY)

                    Rectangle()
                        .fill(Color.pulseSleep.opacity(0.55))
                        .frame(width: 1, height: geo.size.height - 2)
                        .position(x: geo.size.width * CGFloat(bedtime.meanAt), y: midY)

                    ForEach(bedtime.dots) { dot in
                        Group {
                            if dot.free {
                                Circle().strokeBorder(Color.pulseSleep.opacity(0.6), lineWidth: 1.5)
                            } else {
                                Circle().fill(Color.pulseSleep.opacity(0.75))
                            }
                        }
                        .frame(width: 7, height: 7)
                        .position(x: geo.size.width * CGFloat(dot.at), y: midY)
                        .accessibilityLabel(dot.title)
                    }
                }
            }
            .frame(height: 18)

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(bedtime.ticks) { tick in
                        Text(tick.label)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                            .position(x: geo.size.width * CGFloat(tick.at), y: geo.size.height / 2)
                    }
                }
            }
            .frame(height: 12)
        }
    }
}

#Preview {
    HomeView()
}
