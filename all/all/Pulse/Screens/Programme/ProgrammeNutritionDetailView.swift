//
//  ProgrammeNutritionDetailView.swift
//  all (bridge-connect)
//
//  Détail « Alimentation » — frise 7 jours (part des cibles tenues), jauges
//  des cibles du jour et avertissement de poids manquant. Les notes du
//  programme sont dans la fiche « À propos ».
//

import SwiftUI

struct ProgrammeNutritionDetailView: View {
    var viewModel: ProgrammeViewModel
    @Environment(\.dismiss) private var dismiss

    private var domain: ProgrammeDomainView? { viewModel.domains.first { $0.kind == .nutrition } }

    var body: some View {
        ScrollView {
            if let domain, case .nutrition(let detail) = domain.detail {
                PulseCard {
                    weekStrip(detail)

                    VStack(alignment: .leading, spacing: PulseSpacing.md) {
                        ForEach(detail.today.rules) { rule in
                            ProgrammeMacroGaugeRow(rule: rule)
                        }
                    }
                    .padding(.top, PulseSpacing.xs)

                    if detail.weightKg == nil {
                        ProgrammeWarnBox(text: "Aucun poids enregistré : les cibles par kilo restent vides.")
                    }
                }
                .padding(PulseSpacing.lg)
            }
        }
        .background(Color.pulseBackground)
        .navigationTitle(domain?.active?.name ?? "Alimentation")
        .navigationBarTitleDisplayMode(.inline)
        .programmeAbout(kind: .nutrition, viewModel: viewModel)
        .onChange(of: domain?.active == nil) { _, stopped in if stopped { dismiss() } }
    }

    private func weekStrip(_ detail: ProgrammeNutritionDetail) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(detail.days) { day in
                VStack(spacing: 5) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(day.logged ? Color.pulseSurfaceAlt : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        day.logged ? Color.clear : Color.pulseBorder,
                                        style: StrokeStyle(lineWidth: 1, dash: [3])
                                    )
                            )
                            .frame(height: 48)
                        if day.logged, day.total > 0 {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.pulseSuccess)
                                .frame(height: 48 * CGFloat(day.hits) / CGFloat(day.total))
                        }
                    }
                    Text(programmeWeekdayLetter(day.date))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text(day.logged ? "\(day.hits)/\(day.total) cibles" : "aucun repas enregistré"))
            }
        }
    }
}

private struct ProgrammeMacroGaugeRow: View {
    let rule: ProgrammeRuleProgress

    private var unit: String { programmeMacroUnit(rule.rule.metric) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(rule.rule.label).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(valueText)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pulseTextPrimary)
            }
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.pulseSurfaceAlt)
                    if maxScale > 0, let value = rule.value {
                        Capsule()
                            .fill(color)
                            .frame(width: width * CGFloat(min(max(value / maxScale, 0), 1)))
                    }
                }
            }
            .frame(height: 6)
            // Puce de statut + libellé (reste/dépassé/dans la cible) à gauche,
            // cible min–max à droite.
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(stateText)
                    .font(.system(size: 11, design: .rounded))
                Spacer()
                Text(goalText)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }

    private var valueText: String {
        guard let value = rule.value else { return "—" }
        return "\(Int(value.rounded()))\(unit.isEmpty ? "" : " " + unit)"
    }

    /// « Sous la cible » reprend la teinte stress, quel que soit le macro.
    private var color: Color {
        switch rule.status {
        case .hit: return .pulseSuccess
        case .over: return .pulseDanger
        case .under: return .pulseStress
        case .unknown: return .pulseTextSecondary
        }
    }

    private var maxScale: Double {
        let candidates = [rule.target.max, rule.target.min, rule.value].compactMap { $0 }
        let scaled = (candidates.max() ?? 0) * 1.35
        return scaled > 0 ? scaled : 0
    }

    private var stateText: String {
        guard let value = rule.value else { return "pas de relevé" }
        switch rule.status {
        case .under:
            guard let min = rule.target.min else { return "sans cible" }
            return "reste \(Int((min - value).rounded())) \(unit)"
        case .over:
            guard let max = rule.target.max else { return "sans cible" }
            return "\(Int((value - max).rounded())) \(unit) de trop"
        case .hit:
            return "dans la cible"
        case .unknown:
            return "sans cible"
        }
    }

    private var goalText: String {
        func format(_ value: Double) -> String { "\(Int(value.rounded()))" }
        if let min = rule.target.min, let max = rule.target.max {
            return "cible \(format(min))–\(format(max)) \(unit)"
        }
        if let min = rule.target.min { return "au moins \(format(min)) \(unit)" }
        if let max = rule.target.max { return "au plus \(format(max)) \(unit)" }
        return ""
    }
}
