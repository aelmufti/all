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
            // `<app-panel [title]="d.active.name" [summary]="nutritionSummary(n)">`
            // simplifié en en-tête toujours déplié (même parti pris que la
            // carte sommeil « Ce que dit le papier »). Web `.title { font-size:15px;
            // font-weight:600 }`, `.summary { font-family:mono; font-size:13px;
            // color:var(--text-dim) }` — pas la taille de `SectionHeader`
            // (17px, réservée aux titres de section génériques).
            HStack(alignment: .firstTextBaseline) {
                Text(domain.active?.name ?? domain.label)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(programmeNutritionSummary(detail.today))
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Text("\(domain.label) · \(programmeBadge(domain))")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color.pulseTextSecondary)

            weekStrip

            VStack(alignment: .leading, spacing: PulseSpacing.md) {
                ForEach(detail.today.rules) { rule in
                    ProgrammeMacroGaugeRow(rule: rule)
                }
            }
            .padding(.top, PulseSpacing.xs)

            if detail.weightKg == nil {
                ProgrammeWarnBox(text: "Aucun poids enregistré : les cibles par kilo restent vides.")
            }

            ForEach(domain.active?.notes ?? [], id: \.self) { note in
                Text(note).font(.system(size: 14))
            }
        }
    }

    // Web `.strip { gap:6px }`, `.day { gap:5px }`, `.day-bar { height:48px;
    // border-radius:8px }`.
    private var weekStrip: some View {
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
        // Web `:host { gap:7px }`.
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                // `.name { font-size:15px; font-weight:600 }`.
                Text(rule.rule.label).font(.system(size: 15, weight: .semibold))
                Spacer()
                // `.val { font-family:mono; font-size:19px; font-weight:600 }`.
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
            // `.bot` — puce de statut + libellé dynamique (reste/dépassé/dans
            // la cible) à gauche, cible min–max à droite. Équivalent
            // `stateLabel()`/`goalLabel()` (`macro-gauge.component.ts`) —
            // `target` n'est jamais passé par `programme.component.ts`
            // (seul `range` l'est), donc `goalFor(edge)` s'y réduit toujours
            // à `edge`.
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

    /// Équivalent `MARKER_COLOR` (`macro-gauge.component.ts`) : "sous la
    /// cible" reprend `--m-stress`, quel que soit le macro (protéines,
    /// glucides, lipides ou kcal) — le web n'a pas de teinte dédiée aux
    /// calories sur cet écran, uniquement ce statut par cible.
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

    /// Équivalent `stateLabel()`.
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

    /// Équivalent `goalLabel()` (`note`/`target` jamais fournis ici, cf.
    /// remarque ci-dessus).
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
