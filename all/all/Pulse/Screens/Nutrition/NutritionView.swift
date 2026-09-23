//
//  NutritionView.swift
//  all (bridge-connect)
//
//  Écran Nutrition natif — équivalent SwiftUI de la page Angular `/nutrition`
//  (`custom-connect/web/src/app/pages/nutrition/nutrition.component.ts`).
//  Priorité à l'affichage fidèle (objectif du jour, macros, journal,
//  timing, suggestions) ; les écritures sont volontairement limitées à
//  trois gestes à faible risque (supprimer une entrée, ajout rapide depuis
//  un aliment fréquent, ajouter une suggestion) — cf. rendu de l'agent pour
//  le détail de ce qui a été laissé de côté (recherche, scan de code-barres,
//  saisie manuelle, détail du calcul de l'objectif, plan de macros).
//
//  Toutes les déclarations de ce fichier sont `private` (fileprivate) ou
//  préfixées `Nutrition*` pour ne rien exposer qui puisse entrer en
//  collision avec les autres écrans (`Screens/Home`, `Screens/Health`…)
//  compilés dans la même cible.
//

import SwiftUI

struct NutritionView: View {
    @State private var viewModel = NutritionViewModel()

    var body: some View {
        NavigationStack {
            content
                .background(Color.pulseBackground)
                .navigationTitle("Nutrition")
                .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingView(message: "Chargement de la nutrition…")
        case .failed(let message):
            ErrorView(message: message) {
                Task { await viewModel.load() }
            }
        case .loaded:
            loadedContent
        }
    }

    private var loadedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                NutritionDayHeader(viewModel: viewModel)

                if let day = viewModel.day {
                    NutritionMacrosCard(day: day)
                }

                if let target = viewModel.targetInfo {
                    NutritionObjectiveCard(target: target, weekly: viewModel.weekly)
                }

                if let day = viewModel.day {
                    NutritionJournalCard(day: day, isMutating: viewModel.isMutating) { id in
                        Task { await viewModel.deleteEntry(id) }
                    }
                }

                if !viewModel.frequent.isEmpty {
                    NutritionFrequentCard(items: viewModel.frequent, isMutating: viewModel.isMutating) { food in
                        Task { await viewModel.quickAdd(food) }
                    }
                }

                if let timing = viewModel.mealTiming {
                    NutritionTimingCard(timing: timing)
                }

                if !viewModel.suggestions.isEmpty {
                    NutritionSuggestionsCard(items: viewModel.suggestions, isMutating: viewModel.isMutating) { item in
                        Task { await viewModel.addSuggestion(item) }
                    }
                }
            }
            .padding(PulseSpacing.lg)
        }
    }
}

// MARK: - En-tête (navigation de jour)

private struct NutritionDayHeader: View {
    var viewModel: NutritionViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                Text("Nutrition")
                    .font(.largeTitle.bold())
                Text(viewModel.dateLabel)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Spacer()
            HStack(spacing: PulseSpacing.sm) {
                Button {
                    viewModel.shiftDay(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.shiftDay(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isToday)
            }
        }
    }
}

// MARK: - Carte macros (kcal + protéines/lipides/glucides/fibres)

private struct NutritionMacrosCard: View {
    let day: NutritionDay

    private var bars: [NutritionBarModel] { nutritionBars(for: day) }
    private var kcalBar: NutritionBarModel? { bars.first { $0.key == "kcal" } }
    private var macroBars: [NutritionBarModel] { bars.filter { $0.key != "kcal" } }

    var body: some View {
        PulseCard {
            SectionHeader(day.programme?.name ?? "Aujourd'hui")

            if let kcalBar {
                VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                    HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.xs) {
                        Text(nutritionValueText(kcalBar.consumed))
                            .font(PulseFont.metricValue)
                            .foregroundStyle(kcalBar.consumed == nil ? Color.pulseTextSecondary : Color.pulseTextPrimary)
                        Text("kcal")
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextSecondary)
                        Spacer()
                        Text(kcalBar.rangeText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    NutritionGaugeBar(
                        value: kcalBar.consumed, range: kcalBar.range,
                        target: kcalBar.target, scaleMax: kcalBar.scaleMax, tint: kcalBar.color
                    )
                }
                .padding(.bottom, PulseSpacing.xs)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: PulseSpacing.md) {
                ForEach(macroBars) { bar in
                    let hit = nutritionInRange(bar)
                    VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                        Text(bar.label.uppercased())
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                        HStack(alignment: .lastTextBaseline, spacing: 3) {
                            Text(nutritionValueText(bar.consumed))
                                .font(.system(.body, design: .monospaced)).fontWeight(.semibold)
                                .foregroundStyle(hit ? Color.pulseSuccess : Color.pulseTextPrimary)
                            Text(bar.unit)
                                .font(.caption2)
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                        NutritionGaugeBar(
                            value: bar.consumed, range: bar.range,
                            target: bar.target, scaleMax: bar.scaleMax, tint: bar.color, compact: true
                        )
                        HStack(spacing: 3) {
                            if hit {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            }
                            Text(bar.rangeText)
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(hit ? Color.pulseSuccess : Color.pulseTextSecondary)
                    }
                }
            }

            if let proteinPerKg = day.proteinPerKg {
                Text("\(nutritionFormatted(proteinPerKg, decimals: 1)) g de protéines par kg")
                    .font(.caption)
                    .foregroundStyle(Color.pulseTextSecondary)
                    .padding(.top, PulseSpacing.xs)
            }
        }
    }
}

/// Une barre de macro déjà calculée (équivalent du `computed bars()` Angular)
/// — cf. `nutritionBars(for:)` plus bas.
private struct NutritionBarModel: Identifiable {
    let key: String
    let label: String
    let unit: String
    let color: Color
    let consumed: Double?
    let target: Double?
    let range: NutritionMacroRange?
    let scaleMax: Double?
    let rangeText: String
    var id: String { key }
}

/// Miroir de `NutritionComponent.bars()` (Angular) : calcule, pour les 5
/// macros, la valeur consommée (`nil` si aucune entrée saisie — une journée
/// vide ne vaut pas zéro), la cible, la fourchette de programme éventuelle,
/// et l'échelle max de la jauge (`max(fourchette, cible, consommé) × 1,35`).
private func nutritionBars(for day: NutritionDay) -> [NutritionBarModel] {
    let logged = !day.entries.isEmpty
    let defs: [(key: String, label: String, unit: String, color: Color, consumed: Double?, target: Double?)] = [
        ("kcal", "Calories", "kcal", .pulseTextPrimary, logged ? day.totals.kcal : nil, day.targets.kcal),
        ("protein", "Protéines", "g", .pulseAccent, logged ? day.totals.protein : nil, day.targets.protein),
        ("fat", "Lipides", "g", .pulseDanger, logged ? day.totals.fat : nil, day.targets.fat),
        ("carbs", "Glucides", "g", .pulseSuccess, logged ? day.totals.carbs : nil, day.targets.carbs),
        ("fiber", "Fibres", "g", .pulseTextSecondary, logged ? day.totals.fiber : nil, day.targets.fiber),
    ]
    return defs.map { def in
        let range = day.targetRanges?[def.key]
        let candidates = [range?.max, range?.min, def.target, def.consumed].compactMap { $0 }
        let rawMax = (candidates.max() ?? 0) * 1.35
        return NutritionBarModel(
            key: def.key, label: def.label, unit: def.unit, color: def.color,
            consumed: def.consumed, target: def.target, range: range,
            scaleMax: rawMax > 0 ? rawMax : nil,
            rangeText: nutritionRangeText(range, def.target)
        )
    }
}

private func nutritionRangeText(_ range: NutritionMacroRange?, _ target: Double?) -> String {
    func n(_ value: Double) -> String { String(Int(value.rounded())) }
    if let min = range?.min, let max = range?.max { return "\(n(min)) – \(n(max))" }
    if let min = range?.min { return "≥ \(n(min))" }
    if let max = range?.max { return "≤ \(n(max))" }
    if let target { return "cible \(n(target))" }
    return "sans cible"
}

private func nutritionInRange(_ bar: NutritionBarModel) -> Bool {
    guard let value = bar.consumed, let range = bar.range else { return false }
    if range.min == nil && range.max == nil { return false }
    if let min = range.min, value < min { return false }
    if let max = range.max, value > max { return false }
    return true
}

private func nutritionValueText(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(Int(value.rounded()))
}

private func nutritionFormatted(_ value: Double, decimals: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "fr_FR")
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = decimals
    formatter.maximumFractionDigits = decimals
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(decimals)f", value)
}

/// Jauge horizontale : trace de fond, zone de fourchette (translucide),
/// remplissage jusqu'à la valeur consommée, repère de cible — équivalent
/// simplifié de `app-range-gauge` (Angular).
private struct NutritionGaugeBar: View {
    let value: Double?
    let range: NutritionMacroRange?
    let target: Double?
    let scaleMax: Double?
    let tint: Color
    var compact: Bool = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let maxValue = scaleMax ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.pulseSurfaceAlt)
                if maxValue > 0, let range {
                    let lo = position(range.min ?? 0, max: maxValue, width: width)
                    let hi = position(range.max ?? maxValue, max: maxValue, width: width)
                    Capsule()
                        .fill(tint.opacity(0.16))
                        .frame(width: max(hi - lo, 0))
                        .offset(x: lo)
                }
                if maxValue > 0, let value {
                    Capsule()
                        .fill(tint)
                        .frame(width: position(value, max: maxValue, width: width))
                }
                if maxValue > 0, let target {
                    Rectangle()
                        .fill(Color.pulseTextPrimary)
                        .frame(width: 2)
                        .offset(x: position(target, max: maxValue, width: width) - 1)
                }
            }
        }
        .frame(height: compact ? 6 : 8)
        .clipShape(Capsule())
    }

    private func position(_ value: Double, max maxValue: Double, width: CGFloat) -> CGFloat {
        let ratio = min(max(value / maxValue, 0), 1)
        return CGFloat(ratio) * width
    }
}

// MARK: - Carte objectif du jour

private struct NutritionObjectiveCard: View {
    let target: NutritionTargetInfo
    let weekly: NutritionWeekly?

    var body: some View {
        PulseCard {
            SectionHeader("Objectif du jour") {
                Text(sourceLabel)
                    .font(.caption2)
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            if target.auto.status == "ok" {
                HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.xs) {
                    Text(nutritionValueText(target.auto.targetKcal))
                        .font(PulseFont.metricValue)
                    Text("kcal")
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(Color.pulseTextSecondary)
                }

                HStack(spacing: PulseSpacing.xl) {
                    NutritionFigure(label: "Dépense", value: target.auto.expenditureKcal)
                    NutritionFigure(label: "Actifs", value: target.auto.detail.activeKcal)
                }

                HStack(spacing: PulseSpacing.sm) {
                    NutritionPill(text: deficitPillText, tone: target.auto.guardStatus == "none" ? .neutral : .warn)
                    if let weekly {
                        NutritionPill(text: weeklyPillText(weekly), tone: weekly.alert ? .warn : .neutral)
                    }
                }
            } else {
                HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.xs) {
                    Text(nutritionValueText(target.targets.kcal))
                        .font(PulseFont.metricValue)
                    Text("kcal")
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                if let weekly {
                    NutritionPill(text: weeklyPillText(weekly), tone: weekly.alert ? .warn : .neutral)
                }
            }
        }
    }

    private var sourceLabel: String {
        guard target.mode == "auto", target.auto.status == "ok" else { return "valeur fixe" }
        switch target.auto.source {
        case "watch": return "mesuré par la montre"
        case "watch-sessions": return "montre · séances"
        default: return "estimé, montre absente"
        }
    }

    private var deficitPillText: String {
        if target.auto.guardStatus == "none", let deficit = target.auto.deficitKcal {
            return "−\(Int(deficit.rounded())) kcal"
        }
        return "plancher atteint"
    }

    private func weeklyPillText(_ weekly: NutritionWeekly) -> String {
        guard let avg = weekly.avgDeficitKcal else { return "7 j incomplets" }
        let sign = avg > 0 ? "−" : "+"
        return "7 j · \(sign)\(Int(abs(avg).rounded())) kcal/j"
    }
}

private struct NutritionFigure: View {
    let label: String
    let value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(nutritionValueText(value))
                .font(.system(.body, design: .monospaced)).fontWeight(.semibold)
            Text(label.uppercased())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

private enum NutritionPillTone {
    case neutral, warn
}

private struct NutritionPill: View {
    let text: String
    let tone: NutritionPillTone

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, PulseSpacing.sm)
            .padding(.vertical, 4)
            .background(tone == .warn ? Color.pulseDanger.opacity(0.14) : Color.pulseSurfaceAlt)
            .foregroundStyle(tone == .warn ? Color.pulseDanger : Color.pulseTextSecondary)
            .clipShape(Capsule())
    }
}

// MARK: - Journal de la journée

private struct NutritionJournalCard: View {
    let day: NutritionDay
    let isMutating: Bool
    let onDelete: (Int) -> Void

    var body: some View {
        PulseCard {
            SectionHeader("Journée") {
                Text("\(day.entries.count) entrée\(day.entries.count > 1 ? "s" : "") · \(nutritionValueText(day.totals.kcal)) kcal")
                    .font(.caption2)
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            if day.entries.isEmpty {
                Text("Aucune saisie — la journée reste vide, elle ne compte pas comme un zéro.")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                    HStack(alignment: .top, spacing: PulseSpacing.md) {
                        Text(entry.ts.map(nutritionClock) ?? "—:—")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                            .frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.name) · \(nutritionPortion(grams: entry.grams, units: entry.unitQty, label: entry.unitLabel))")
                                .font(.subheadline.weight(.medium))
                            Text("\(nutritionValueText(entry.kcal)) kcal · \(nutritionValueText(entry.protein)) P · \(nutritionValueText(entry.carbs)) G · \(nutritionValueText(entry.fiber)) F")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            onDelete(entry.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(isMutating)
                    }
                    .padding(.vertical, PulseSpacing.xs)
                    if index < day.entries.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }
}

private func nutritionClock(_ ts: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ts))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let components = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
}

private func nutritionPortion(grams: Double, units: Double?, label: String?) -> String {
    if let units, units > 0 {
        let qty = units.rounded() == units ? String(Int(units)) : nutritionFormatted(units, decimals: 1)
        let trimmed = label?.trimmingCharacters(in: .whitespaces) ?? ""
        let unitName = trimmed.isEmpty ? "unité" : trimmed
        return "\(qty) \(unitName) · \(Int(grams.rounded())) g"
    }
    return "\(Int(grams.rounded())) g"
}

// MARK: - Ajout rapide (aliments fréquents)

private struct NutritionFrequentCard: View {
    let items: [NutritionFrequentFood]
    let isMutating: Bool
    let onAdd: (NutritionFrequentFood) -> Void

    var body: some View {
        PulseCard {
            SectionHeader("Ajout rapide")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PulseSpacing.sm) {
                    ForEach(items) { food in
                        Button {
                            onAdd(food)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(food.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.pulseTextPrimary)
                                    .lineLimit(1)
                                Text(nutritionFrequentPortion(food))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.pulseTextSecondary)
                            }
                            .padding(PulseSpacing.sm)
                            .frame(width: 150, alignment: .leading)
                            .background(Color.pulseSurfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isMutating)
                    }
                }
            }
        }
    }
}

private func nutritionFrequentPortion(_ food: NutritionFrequentFood) -> String {
    let base = nutritionPortion(grams: food.grams, units: food.units, label: food.unitLabel)
    guard let kcalPer100 = food.kcal else { return base }
    let scaled = kcalPer100 * food.grams / 100
    return "\(base) · \(Int(scaled.rounded())) kcal"
}

// MARK: - Timing des repas

private struct NutritionTimingCard: View {
    let timing: NutritionMealTiming

    var body: some View {
        PulseCard {
            SectionHeader("Timing")
            HStack(spacing: PulseSpacing.lg) {
                NutritionTimingRow(label: "Dernier repas", value: nutritionClock(timing.lastMealTs))
                NutritionTimingRow(label: "Fin de digestion", value: nutritionClock(timing.digestionEndTs))
                NutritionTimingRow(label: "Prochain repas", value: nutritionClock(timing.nextMealTs))
            }
            if let stress = timing.avgStress {
                Text("Stress moyen pendant la digestion : \(stress)")
                    .font(.caption)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }
}

private struct NutritionTimingRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.body, design: .monospaced)).fontWeight(.semibold)
            Text(label.uppercased())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Suggestions pour finir la journée

private struct NutritionSuggestionsCard: View {
    let items: [NutritionSuggestionItem]
    let isMutating: Bool
    let onAdd: (NutritionSuggestionItem) -> Void

    var body: some View {
        PulseCard {
            SectionHeader("Pour finir la journée")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: PulseSpacing.sm) {
                ForEach(items.prefix(4)) { item in
                    Button {
                        onAdd(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(item.name) · \(nutritionPortion(grams: item.grams, units: item.units, label: item.unitLabel))")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.pulseTextPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text("\(Int(item.kcal.rounded())) kcal · \(Int(item.protein.rounded())) P")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                        .padding(PulseSpacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.pulseSurfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isMutating)
                }
            }
        }
    }
}

#Preview {
    NutritionView()
}
