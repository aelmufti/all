//
//  HomeView.swift
//  all (bridge-connect)
//
//  Écran Accueil — port natif de `custom-connect/web/src/app/pages/home/home.component.ts`,
//  restreint à ce que `PulseShellView` annonce pour cet onglet : entraînement
//  de la semaine + intensité du jour, avec la FC « Maintenant » en bonus (le
//  sommeil et les pas/calories du jour vivent sur l'écran Santé). Trois
//  états : chargement (`LoadingView`), erreur (`ErrorView`), données.
//
//  À brancher dans `PulseShellView`, case `.accueil`, à la place de
//  `ComingSoonView(title: "Accueil", …)` — pas de dépendance de navigation
//  externe : l'écran gère sa propre `NavigationStack`.
//

import SwiftUI

struct HomeView: View {
    @State private var viewModel = HomeViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Accueil")
                .background(Color.pulseBackground)
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
                }
                .padding(PulseSpacing.lg)
            }
        }
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
                    .foregroundStyle(viewModel.shownHr == nil ? Color.pulseTextSecondary : Color.pulseAccent)
                Text("bpm")
                    .font(PulseFont.metricUnit)
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            Text(nowSubtitle)
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)

            liveControl

            HStack(spacing: PulseSpacing.lg) {
                ForEach(viewModel.vitals) { vital in
                    StatTile(
                        label: vital.label,
                        value: vital.value.map(String.init) ?? "—",
                        unit: vital.value != nil ? vital.unit : nil
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
                drawCurve(intensity, in: &context, size: size, color: .pulseAccent, dash: [6, 4])
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

#Preview {
    HomeView()
}
