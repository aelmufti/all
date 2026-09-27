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

    /// Point survolé sur le graphe FC repos / respiration — remonté ici (pas
    /// dans la carte) car c'est la section qui calcule l'override figrow (elle
    /// seule connaît l'index de tuile ET la sous-vue active). Le poids (tuile 4)
    /// n'est jamais visible en figrow (`prefix(3)`) : `DashboardWeightCard` gère
    /// son survol en interne, en annotation sur le graphe.
    @State private var restingHover: DashboardHealthPoint?
    @State private var respirationHover: DashboardHealthPoint?

    var body: some View {
        if let health = viewModel.health {
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                DashboardFigureRow(tiles: figures(for: health), highlights: figureHighlight)

                switch viewModel.subView {
                case .restingHr:
                    DashboardRestingHrCard(health: health, hover: $restingHover)
                case .respiration:
                    DashboardRespirationCard(health: health, hover: $respirationHover)
                case .spo2:
                    DashboardSpo2Card(health: health)
                case .weight:
                    DashboardWeightCard(health: health)
                case .correlations:
                    DashboardCorrelationsCard(correlations: health.correlations)
                default:
                    DashboardRestingHrCard(health: health, hover: $restingHover)
                }
            }
            // Le point survolé n'a de sens que pour la sous-vue courante : on le
            // purge au changement de sous-vue (sinon une FC repos pointée
            // resterait affichée en figrow sous l'onglet respiration).
            .onChange(of: viewModel.subView) { _, _ in
                restingHover = nil
                respirationHover = nil
            }
        } else {
            DashboardSkeletonCard()
        }
    }

    /// Override de tuile figrow au survol — FC repos (tuile 0) ou respiration
    /// (tuile 1), seulement pour la sous-vue actuellement affichée.
    private var figureHighlight: [Int: String] {
        switch viewModel.subView {
        case .restingHr:
            if let h = restingHover { return [0: String(Int(h.value.rounded()))] }
        case .respiration:
            if let h = respirationHover { return [1: String(format: "%.1f", h.value)] }
        default:
            break
        }
        return [:]
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
    @Binding var hover: DashboardHealthPoint?

    /// Position (temporelle) du doigt — `chartXSelection` renvoie une date
    /// continue, recalée sur le point le plus proche (miroir de
    /// `SampleLineChart`, écran Santé).
    @State private var selectedDate: Date?

    var body: some View {
        PulseCard {
            HStack {
                DashboardCardHeader("FC au repos")
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
                Chart {
                    ForEach(health.restingSeries) { point in
                        LineMark(
                            x: .value("Date", dashboardDate(from: point.date) ?? Date()),
                            y: .value("bpm", point.value)
                        )
                        .foregroundStyle(DashboardMetricColor.heartRate)
                        .interpolationMethod(.monotone)
                    }
                    // Repère du point survolé : trait vertical + pastille pleine.
                    if let sel = selectedPoint, let date = dashboardDate(from: sel.date) {
                        RuleMark(x: .value("Date", date))
                            .foregroundStyle(Color.pulseTextSecondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value("Date", date), y: .value("bpm", sel.value))
                            .foregroundStyle(DashboardMetricColor.heartRate)
                            .symbolSize(80)
                    }
                }
                .frame(height: 150)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { AxisValueLabel(format: .dateTime.day().month()) }
                }
                .chartXSelection(value: $selectedDate)
                .onChange(of: selectedDate) { _, newValue in
                    hover = newValue.flatMap(nearestRestingPoint)
                }
            }
        }
    }

    private var selectedPoint: DashboardHealthPoint? {
        guard let selectedDate else { return nil }
        return nearestRestingPoint(to: selectedDate)
    }

    private func nearestRestingPoint(to date: Date) -> DashboardHealthPoint? {
        let t = date.timeIntervalSince1970
        return health.restingSeries.min {
            let a = dashboardDate(from: $0.date)?.timeIntervalSince1970 ?? 0
            let b = dashboardDate(from: $1.date)?.timeIntervalSince1970 ?? 0
            return abs(a - t) < abs(b - t)
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
    @Binding var hover: DashboardHealthPoint?

    @State private var selectedDate: Date?

    var body: some View {
        PulseCard {
            HStack {
                DashboardCardHeader("Respiration nocturne")
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
                    if let sel = selectedPoint, let date = dashboardDate(from: sel.date) {
                        RuleMark(x: .value("Date", date))
                            .foregroundStyle(Color.pulseTextSecondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value("Date", date), y: .value("resp/min", sel.value))
                            .foregroundStyle(Color.pulseAccent)
                            .symbolSize(80)
                    }
                }
                .frame(height: 150)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { AxisValueLabel(format: .dateTime.day().month()) }
                }
                .chartXSelection(value: $selectedDate)
                .onChange(of: selectedDate) { _, newValue in
                    hover = newValue.flatMap(nearestRespirationPoint)
                }
                if let band = health.respirationBand {
                    Text("habituel entre \(String(format: "%.0f", band.lo)) et \(String(format: "%.0f", band.hi)) respirations / min")
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
        }
    }

    private var selectedPoint: DashboardHealthPoint? {
        guard let selectedDate else { return nil }
        return nearestRespirationPoint(to: selectedDate)
    }

    private func nearestRespirationPoint(to date: Date) -> DashboardHealthPoint? {
        let t = date.timeIntervalSince1970
        return health.respirationSeries.min {
            let a = dashboardDate(from: $0.date)?.timeIntervalSince1970 ?? 0
            let b = dashboardDate(from: $1.date)?.timeIntervalSince1970 ?? 0
            return abs(a - t) < abs(b - t)
        }
    }
}

private struct DashboardSpo2Card: View {
    let health: DashboardHealthTab

    var body: some View {
        PulseCard {
            HStack {
                DashboardCardHeader("SpO2 · distribution")
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

    /// Pesée survolée — le poids (tuile 4) n'est jamais visible en figrow
    /// (`prefix(3)` ne montre que les 3 premières tuiles) : contrairement à FC
    /// repos/respiration, le survol se montre en annotation sur le point plutôt
    /// que par override de tuile.
    @State private var selectedDate: Date?

    var body: some View {
        PulseCard {
            if health.weightSeries.count > 1 {
                HStack {
                    DashboardCardHeader("Poids")
                    Spacer()
                    // Le poids (tuile 4) n'étant pas dans la figrow visible, la
                    // valeur survolée s'affiche ici, en tête de carte, plutôt
                    // qu'en annotation SUR le point : une annotation débordait du
                    // tracé près des bords et forçait Swift Charts à recomposer
                    // (le graphe « sautait » et le survol tremblait).
                    Text(hoverLabel ?? deltaLabel)
                        .font(PulseFont.metricLabel)
                        .foregroundStyle(hoverLabel != nil ? Color.pulseTextPrimary : Color.pulseTextSecondary)
                }
                Chart {
                    ForEach(health.weightSeries) { point in
                        LineMark(
                            x: .value("Date", dashboardDate(from: point.date) ?? Date()),
                            y: .value("kg", point.kg)
                        )
                        .foregroundStyle(DashboardMetricColor.sleep)
                        .interpolationMethod(.monotone)
                    }
                    if let sel = selectedPoint, let date = dashboardDate(from: sel.date) {
                        RuleMark(x: .value("Date", date))
                            .foregroundStyle(Color.pulseTextSecondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value("Date", date), y: .value("kg", sel.kg))
                            .foregroundStyle(DashboardMetricColor.sleep)
                            .symbolSize(80)
                    }
                }
                .frame(height: 150)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { AxisValueLabel(format: .dateTime.day().month()) }
                }
                .chartXSelection(value: $selectedDate)
                if let first = health.weightSeries.first, let last = health.weightSeries.last {
                    Text("\(String(format: "%.1f", first.kg)) kg → \(String(format: "%.1f", last.kg)) kg · \(health.weightSeries.count) pesées")
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            } else {
                DashboardCardHeader("Poids") { Text("aucune pesée").font(PulseFont.metricLabel).foregroundStyle(Color.pulseTextSecondary) }
                Text("Pas de pesée sur la période. La saisie se fait sur la page Santé, jour par jour.")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }

    private var selectedPoint: DashboardWeightPoint? {
        guard let selectedDate else { return nil }
        return nearestWeightPoint(to: selectedDate)
    }

    /// Lecture du point survolé, montrée en tête de carte (pas d'annotation
    /// sur le tracé — cf. commentaire dans l'en-tête).
    private var hoverLabel: String? {
        guard let sel = selectedPoint, let date = dashboardDate(from: sel.date) else { return nil }
        return "\(String(format: "%.1f", sel.kg)) kg · \(dashboardShortDayMonth(date))"
    }

    private func nearestWeightPoint(to date: Date) -> DashboardWeightPoint? {
        let t = date.timeIntervalSince1970
        return health.weightSeries.min {
            let a = dashboardDate(from: $0.date)?.timeIntervalSince1970 ?? 0
            let b = dashboardDate(from: $1.date)?.timeIntervalSince1970 ?? 0
            return abs(a - t) < abs(b - t)
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
            DashboardCardHeader("Ce qui bouge ensemble")
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
