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
                VStack(alignment: .leading, spacing: 16) {
                    ProgrammeCard(spacing: 20) {
                        weekStrip(detail)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(detail.today.rules.enumerated()), id: \.element.id) { index, rule in
                                if index > 0 { ProgrammeHairline() }
                                ProgrammeMacroGaugeRow(rule: rule)
                            }
                        }
                    }
                    if detail.weightKg == nil {
                        ProgrammeWarnBox(text: "Aucun poids enregistré : les cibles par kilo restent vides.")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Color.pulseBackground)
        .navigationTitle(domain?.active?.name ?? "Alimentation")
        .navigationBarTitleDisplayMode(.inline)
        .programmeAbout(kind: .nutrition, viewModel: viewModel)
        .onChange(of: domain?.active == nil) { _, stopped in if stopped { dismiss() } }
    }

    private func weekStrip(_ detail: ProgrammeNutritionDetail) -> some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(detail.days) { day in
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(day.logged ? Color.pulseSurfaceAlt : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        day.logged ? Color.clear : Color.pulseEmpty,
                                        style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                                    )
                            )
                            .frame(height: 48)
                        if day.logged, day.total > 0 {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.pulseTextPrimary)
                                .frame(height: 48 * CGFloat(day.hits) / CGFloat(day.total))
                        }
                    }
                    Text(programmeWeekdayLetter(day.date))
                        .font(.programmeMono(10))
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                ProgrammeLabel(rule.rule.label)
                Spacer()
                Text(valueText)
                    .font(.programmeMono(19, weight: .semibold))
                    .foregroundStyle(Color.pulseTextPrimary)
            }
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.pulseSurfaceAlt)
                    if maxScale > 0, let value = rule.value {
                        Capsule()
                            .fill(Color.pulseTextPrimary)
                            .frame(width: width * CGFloat(min(max(value / maxScale, 0), 1)))
                    }
                }
            }
            .frame(height: 4)
            HStack(spacing: 6) {
                Text(stateText)
                    .font(.programmeMono(11))
                    .foregroundStyle(stateColor)
                Spacer()
                Text(goalText)
                    .font(.programmeMono(11))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
        .padding(.vertical, 14)
    }

    private var valueText: String {
        guard let value = rule.value else { return "—" }
        return "\(Int(value.rounded()))\(unit.isEmpty ? "" : " " + unit)"
    }

    /// Seul l'écart (dépassé / sous la cible) garde une teinte : il porte la donnée.
    private var stateColor: Color {
        switch rule.status {
        case .over: return .pulseDanger
        case .under: return .pulseStress
        case .hit, .unknown: return .pulseTextSecondary
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
