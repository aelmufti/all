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

/// Carte « Heure de coucher conseillée » — met en avant la reco calculée côté
/// serveur (`/api/stats/sleep-recommendation`). Ne s'affiche que quand la reco
/// est exploitable (≥ 3 nuits) ; sous ce seuil l'appelant montre autre chose.
struct DashboardSleepRecommendationCard: View {
    let reco: DashboardSleepRecommendation

    /// Date (`YYYY-MM-DD`) de la nuit AFFICHÉE dans l'écran Sommeil — clé par
    /// jour de RÉVEIL (cf. `SommeilViewModel`). Quand elle est fournie, l'heure
    /// conseillée est calculée POUR CETTE nuit-là (`SleepBedtimePlan.plan`) :
    /// réveil PRÉVU de ce jour (alarme réglée pour ce jour de semaine, sinon
    /// lever habituel semaine/week-end, sinon global) moins la durée idéale de
    /// la nuit (contexte du jour) — jamais le réveil réel. Marche aussi pour une
    /// nuit à venir, sans sommeil mesuré. `nil` → reco prospective.
    var nightDate: String? = nil

    /// Réveil réglé dans l'app pour DEMAIN (`Pulse/Core/WakeScheduleStore.swift`)
    /// prime sur l'heure de lever habituelle du serveur — recalcul purement
    /// local, aucun appel réseau. `nil` → reco serveur affichée telle quelle.
    /// Cette carte étant utilisée à la fois par l'écran Sommeil et l'onglet
    /// Sommeil du Dashboard, l'adaptation apparaît aux deux endroits.
    private var adapted: AdaptedBedtime? {
        WakeScheduleStore.shared.adaptedBedtime(reco: reco)
    }

    /// Heure conseillée pour `nightDate` (`nil` sans date ou sans donnée
    /// exploitable → repli sur la reco prospective).
    private var plan: SleepBedtimePlan.Result? {
        guard let nightDate,
              let weekday = SleepBedtimePlan.weekday(ofDateKey: nightDate) else { return nil }
        return SleepBedtimePlan.plan(
            reco: reco, date: nightDate,
            alarmMinutes: WakeScheduleStore.shared.minutes(for: weekday))
    }

    var body: some View {
        let plan = plan
        PulseCard {
            DashboardCardHeader("Heure de coucher conseillée")

            Text(plan?.bedtime ?? adapted?.bedtime ?? reco.recommendedBedtime ?? "—")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.pulseSleep)

            // Ligne de contexte seulement quand un réveil cadre la nuit À VENIR
            // (reco prospective, sans date). Avec une date (`plan`), le réveil
            // prévu est déjà celui de CE jour : la ligne n'a plus lieu d'être.
            if plan == nil, let adapted {
                Text("Pour te réveiller à \(WakeScheduleStore.hhmm(adapted.wakeMinutes)) — réglé sur ton téléphone")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextPrimary)
            }

            // Une seule ligne discrète (détail dans Paramètres › Aide) : la durée
            // idéale de CETTE nuit quand elle existe ; sinon « nuit d'essai »
            // (fait ponctuel sur CE soir) ou la durée idéale globale.
            if let plan, plan.isNightSpecific {
                Text("Durée idéale cette nuit : \(SleepBedtimePlan.durationLabel(hours: plan.idealHours))")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else if reco.trial == true {
                Text("Nuit d'essai")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseSleep)
            } else if let ideal = reco.idealHours {
                let range: String = {
                    guard let lo = reco.idealLowHours, let hi = reco.idealHighHours, lo != hi else { return "" }
                    return " (\(dashboardHoursHM(lo))–\(dashboardHoursHM(hi)))"
                }()
                Text("Ta durée idéale : \(dashboardHoursHM(ideal))\(range)")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }
}

/// Vue « Tendance » du détail Sommeil — refondue pour suivre l'Écran 2 de la
/// maquette : grand graphe « Durée par nuit » (aire), trois tuiles de synthèse
/// (Moyenne / Dette / Éveil), barres de composition des phases, tuiles de
/// régularité. Les vues plus fouillées (nuit par nuit, insights stress/
/// fragmentation) restent accessibles via les sous-onglets Dette / Régularité.
private struct DashboardSleepTrendCard: View {
    let viewModel: DashboardViewModel

    /// Nuit survolée sur la courbe — pas de `DashboardFigureRow` dans cette
    /// section : la valeur pointée se montre en annotation sur le marqueur,
    /// comme le poids (`DashboardWeightCard`).
    @State private var selectedDate: Date?

    private var points: [(date: Date, hours: Double)] {
        zip(viewModel.wellnessDates, viewModel.wellnessSleepHours).compactMap { date, hours in
            guard let date, let hours else { return nil }
            return (date, hours)
        }
    }

    private var avgHours: Double? {
        let hours = points.map(\.hours)
        guard !hours.isEmpty else { return nil }
        return hours.reduce(0, +) / Double(hours.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.lg) {
            durationCard

            if let debt = viewModel.sleepDebt, debt.nights > 0 {
                DashboardSleepTileRow(tiles: debtTiles(debt))
            }

            if let composition = viewModel.sleepInsights?.composition {
                DashboardSleepCompositionCard(composition: composition)
            }

            if let regularity = viewModel.sleepRegularity, regularity.score != nil {
                DashboardSleepRegularityTiles(regularity: regularity)
            }
        }
    }

    private var durationCard: some View {
        PulseCard {
            HStack {
                DashboardCardHeader("Durée par nuit")
                Spacer()
                // Section sans figrow : la nuit survolée se lit ici, en tête de
                // carte, plutôt qu'en annotation sur le point (qui débordait du
                // tracé près des bords et faisait « sauter » le graphe).
                if let hoverLabel {
                    Text(hoverLabel)
                        .font(PulseFont.metricLabel)
                        .foregroundStyle(Color.pulseTextPrimary)
                } else if let avgHours {
                    Text("moy \(dashboardHoursHM(avgHours))")
                        .font(PulseFont.metricLabel)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            if points.count < 2 {
                Text("Pas assez de nuits pour une tendance.")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                Chart {
                    ForEach(points, id: \.date) { point in
                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Heures", point.hours)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [DashboardMetricColor.sleep.opacity(0.24), DashboardMetricColor.sleep.opacity(0)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Heures", point.hours)
                        )
                        .foregroundStyle(DashboardMetricColor.sleep)
                        .interpolationMethod(.monotone)
                    }
                    // Repère de la nuit survolée — annotation sur le marqueur,
                    // pas d'override de tuile : cette section n'a pas de figrow.
                    if let sel = selectedPoint {
                        RuleMark(x: .value("Date", sel.date))
                            .foregroundStyle(Color.pulseTextSecondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value("Date", sel.date), y: .value("Heures", sel.hours))
                            .foregroundStyle(DashboardMetricColor.sleep)
                            .symbolSize(80)
                    }
                }
                .frame(height: 160)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { AxisValueLabel(format: .dateTime.day().month()) }
                }
                .chartXSelection(value: $selectedDate)
            }
        }
    }

    private var selectedPoint: (date: Date, hours: Double)? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince1970 - selectedDate.timeIntervalSince1970)
                < abs($1.date.timeIntervalSince1970 - selectedDate.timeIntervalSince1970)
        }
    }

    /// Lecture de la nuit survolée, montrée en tête de carte.
    private var hoverLabel: String? {
        guard let sel = selectedPoint else { return nil }
        return "\(String(format: "%.1f", sel.hours)) h · \(dashboardShortDayMonth(sel.date))"
    }

    private func debtTiles(_ debt: DashboardSleepDebt) -> [DashboardSleepTile] {
        [
            DashboardSleepTile(
                label: "Moyenne",
                value: dashboardHoursHM(debt.avgHours),
                sub: "objectif \(debt.targetHours):00"
            ),
            DashboardSleepTile(
                label: "Dette",
                value: (debt.debtHours <= 0 ? "à jour" : "−\(dashboardHoursHM(abs(debt.debtHours)))"),
                sub: "\(debt.deficitNights) nuit\(debt.deficitNights > 1 ? "s" : "") sous l'objectif",
                tint: debt.debtHours > 0 ? .pulseStress : .pulseSuccess
            ),
            DashboardSleepTile(
                label: "Éveil / nuit",
                value: "\(debt.avgAwakeMin)",
                sub: "min en moyenne"
            ),
        ]
    }
}

/// Une tuile de synthèse (label mono, grande valeur mono, sous-ligne) dans un
/// cadre bordé — reprend le style des `.tile` de la maquette.
private struct DashboardSleepTile: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var sub: String = ""
    var tint: Color = .pulseTextPrimary
}

private struct DashboardSleepTileRow: View {
    let tiles: [DashboardSleepTile]

    var body: some View {
        HStack(alignment: .top, spacing: PulseSpacing.sm) {
            ForEach(tiles) { tile in
                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.label.uppercased())
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(Color.pulseTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(tile.value)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(tile.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if !tile.sub.isEmpty {
                        Text(tile.sub)
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(Color.pulseTextSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PulseSpacing.md)
                .background(Color.pulseSurface)
                .clipShape(RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous)
                        .strokeBorder(Color.pulseBorder, lineWidth: 1)
                )
            }
        }
    }
}

/// Barres de composition des phases (Profond / Léger / Paradoxal) avec repère
/// de fourchette de référence — équivalent de l'Écran 2 de la maquette.
private struct DashboardSleepCompositionCard: View {
    let composition: DashboardComposition

    var body: some View {
        PulseCard {
            DashboardCardHeader("Composition moyenne")
            VStack(spacing: PulseSpacing.md) {
                ForEach(dashboardCompositionRows(composition), id: \.label) { row in
                    HStack(spacing: PulseSpacing.sm) {
                        Text(row.label)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Color.pulseTextSecondary)
                            .frame(width: 74, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.pulseSurfaceAlt)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(row.out ? Color.pulseDanger : dashboardPhaseColor(row.label))
                                    .frame(width: proxy.size.width * CGFloat(min(max(row.pct / 100, 0), 1)))
                                // Repère : fourchette de référence (bande translucide).
                                Rectangle()
                                    .fill(Color.pulseTextPrimary.opacity(0.35))
                                    .frame(width: 2)
                                    .offset(x: proxy.size.width * CGFloat((row.lo + row.hi) / 200))
                            }
                        }
                        .frame(height: 8)
                        Text("\(Int(row.pct.rounded())) %")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(row.out ? Color.pulseDanger : Color.pulseTextPrimary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            Text("En part du sommeil réel, moyenné sur \(composition.nights) nuits ; l'éveil représente \(String(format: "%.0f", composition.wasoPct)) % de la fenêtre.")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

private struct DashboardSleepRegularityTiles: View {
    let regularity: DashboardSleepRegularity

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.sm) {
            DashboardCardHeader("Régularité")
            HStack(alignment: .top, spacing: PulseSpacing.sm) {
                regularityTile(label: "Coucher", value: regularity.bedtime ?? "—", sub: regularity.bedStdMin.map { "±\($0) min" } ?? "")
                regularityTile(label: "Lever", value: regularity.waketime ?? "—", sub: regularity.wakeStdMin.map { "±\($0) min" } ?? "")
                if let score = regularity.score {
                    regularityTile(label: "Score", value: "\(score)", sub: dashboardRegularityWord(score), tint: dashboardRegularityColor(score: score))
                }
            }
        }
    }

    private func regularityTile(label: String, value: String, sub: String, tint: Color = .pulseTextPrimary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Color.pulseTextSecondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            if !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PulseSpacing.md)
        .background(Color.pulseSurface)
        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous)
                .strokeBorder(Color.pulseBorder, lineWidth: 1)
        )
    }
}

/// Couleur par phase de sommeil (aligne les barres sur la palette de phases du
/// thème plutôt que sur une teinte unique).
private func dashboardPhaseColor(_ label: String) -> Color {
    switch label {
    case "Profond": return .pulseSleepDeep
    case "Léger": return .pulseSleepLight
    case "Paradoxal": return .pulseSleepRem
    default: return .pulseSleep
    }
}

/// Qualificatif court du score de régularité (accompagne le chiffre).
private func dashboardRegularityWord(_ score: Int) -> String {
    switch score {
    case 80...: return "excellent"
    case 65..<80: return "bon"
    case 50..<65: return "moyen"
    default: return "irrégulier"
    }
}

/// Formatte des heures décimales en `H:MM` (ex. 7.2 → « 7:12 »).
private func dashboardHoursHM(_ hours: Double) -> String {
    let totalMinutes = Int((hours * 60).rounded())
    return "\(totalMinutes / 60):\(String(format: "%02d", totalMinutes % 60))"
}

private struct DashboardSleepDebtCard: View {
    let viewModel: DashboardViewModel
    let sleepDebt: DashboardSleepDebt

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.lg) {
            if sleepDebt.nights > 0 {
                PulseCard {
                    HStack {
                        DashboardCardHeader("Dette de sommeil")
                        Spacer()
                        Text(viewModel.debtLevel)
                            .font(PulseFont.metricLabel)
                            .padding(.horizontal, PulseSpacing.sm)
                            .padding(.vertical, 3)
                            .background(badgeBackground)
                            .foregroundStyle(badgeColor)
                            .clipShape(Capsule())
                    }
                    HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
                        Text(String(format: "%.1f", abs(sleepDebt.debtHours)))
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
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
                    DashboardCardHeader("Dette de sommeil")
                    Text("Aucune nuit mesurée sur la période.")
                        .font(PulseFont.body)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
        }
    }

    // Le web ne marque en « bon » que "faible" — "à jour" reste au pill gris
    // par défaut ([class.good]="debtLevel() === 'faible'" dans le template).
    private var badgeColor: Color {
        switch viewModel.debtLevel {
        case "élevée": return .pulseDanger
        case "faible": return .pulseSuccess
        default: return .pulseTextSecondary
        }
    }

    private var badgeBackground: Color {
        switch viewModel.debtLevel {
        case "élevée": return Color.pulseDanger.opacity(0.14)
        case "faible": return Color.pulseSuccess.opacity(0.14)
        default: return .pulseSurfaceAlt
        }
    }
}

private struct DashboardMiniFigure: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(Color.pulseTextPrimary)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium, design: .rounded))
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
            DashboardCardHeader("Détail des \(sleepDebt.nights) nuits")

            VStack(spacing: 0) {
                ForEach(viewModel.debtDetail) { night in
                    HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
                        Text(dashboardLongDate(night.date))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(Color.pulseTextSecondary)
                            .frame(minWidth: 90, alignment: .leading)
                        Text(dashboardFormatHM(night.sleepS))
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundStyle(Color.pulseTextPrimary)
                        Spacer()
                        Text(dashboardFormatSignedHM(night.deltaS))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(night.deltaS < 0 ? Color.pulseDanger : Color.pulseSuccess)
                        Text(dashboardFormatSignedHours(night.cumulativeS))
                            .font(.system(.caption, design: .rounded))
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
                                    .font(.system(.caption, design: .rounded))
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
                                .font(.system(.caption, design: .rounded))
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
            DashboardCardHeader("Régularité")
            if let score = regularity.score {
                HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
                    Text("\(score)")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
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
