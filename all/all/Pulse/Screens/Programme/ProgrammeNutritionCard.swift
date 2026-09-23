//
//  ProgrammeNutritionCard.swift
//  all (bridge-connect)
//
//  Domaine « Alimentation » — jauges des cibles du jour, frise 7 jours (part
//  des cibles tenues) et notes du programme. Miroir de la section
//  `@if (nutrition(d); as n)` du template Angular (`app-panel` simplifié en
//  `PulseCard`).
//

import SwiftUI

struct ProgrammeNutritionCard: View {
    let domain: ProgrammeDomainView
    let detail: ProgrammeNutritionDetail

    var body: some View {
        PulseCard {
            SectionHeader(domain.active?.name ?? domain.label) {
                Text(programmeNutritionSummary(detail.today))
                    .font(.caption2)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Text("\(domain.label) · \(programmeBadge(domain)) · pilote \(domain.drives.lowercased())")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)

            weekStrip
            Text("Sept derniers jours · part des cibles tenues, pointillés quand rien n’est saisi.")
                .font(.caption2)
                .foregroundStyle(Color.pulseTextSecondary)

            VStack(alignment: .leading, spacing: PulseSpacing.md) {
                ForEach(detail.today.rules) { rule in
                    ProgrammeMacroGaugeRow(rule: rule)
                }
            }
            .padding(.top, PulseSpacing.xs)

            if detail.weightKg == nil {
                Text("Aucun poids enregistré : les cibles par kilo restent vides.")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseDanger)
            }

            ForEach(domain.active?.notes ?? [], id: \.self) { note in
                Text(note).font(.footnote)
            }
        }
    }

    private var weekStrip: some View {
        HStack(alignment: .bottom, spacing: PulseSpacing.xs) {
            ForEach(detail.days) { day in
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(day.logged ? Color.pulseSurfaceAlt : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        day.logged ? Color.clear : Color.pulseBorder,
                                        style: StrokeStyle(lineWidth: 1, dash: [3])
                                    )
                            )
                            .frame(height: 44)
                        if day.logged, day.total > 0 {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.pulseSuccess)
                                .frame(height: 44 * CGFloat(day.hits) / CGFloat(day.total))
                        }
                    }
                    Text(programmeWeekdayLetter(day.date))
                        .font(.system(size: 10, design: .monospaced))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(rule.rule.label).font(.subheadline.weight(.medium))
                Spacer()
                Text(valueText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(color)
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
            Text(rangeText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    private var valueText: String {
        guard let value = rule.value else { return "—" }
        let unit = programmeMacroUnit(rule.rule.metric)
        return "\(Int(value.rounded()))\(unit.isEmpty ? "" : " " + unit)"
    }

    private var color: Color {
        switch rule.status {
        case .hit: return .pulseSuccess
        case .over: return .pulseDanger
        case .under: return .pulseAccent
        case .unknown: return .pulseTextSecondary
        }
    }

    private var maxScale: Double {
        let candidates = [rule.target.max, rule.target.min, rule.value].compactMap { $0 }
        let scaled = (candidates.max() ?? 0) * 1.35
        return scaled > 0 ? scaled : 0
    }

    private var rangeText: String {
        func format(_ value: Double) -> String { "\(Int(value.rounded()))" }
        if let min = rule.target.min, let max = rule.target.max { return "\(format(min)) – \(format(max))" }
        if let min = rule.target.min { return "≥ \(format(min))" }
        if let max = rule.target.max { return "≤ \(format(max))" }
        return "sans cible"
    }
}
