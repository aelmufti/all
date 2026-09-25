//
//  NutritionView.swift
//  all (bridge-connect)
//
//  Écran Nutrition natif — équivalent SwiftUI de la page Angular `/nutrition`
//  (`custom-connect/web/src/app/pages/nutrition/nutrition.component.ts`).
//
//  bridge-connect étant une app plein-écran sur téléphone, la mise en page
//  suivie est celle du gabarit **mobile** du composant Angular (`@else` du
//  `@if (desktop())`, largeur < 900px) : carte macros (`ng-template #macros`,
//  PAS `#hero`), carte Timing (`#frise`), carte Journée — la carte « Objectif
//  du jour », le widget « Ajout rapide » et « Pour finir la journée »
//  n'existent, côté Angular, que dans le gabarit desktop (`@if (desktop())`).
//  Ils sont malgré tout **conservés** ici (le natif les avait déjà et la
//  consigne était de ne rien retirer sans qu'Angular ne le fasse) : ordre
//  réaligné sur le DOM desktop réduit à une colonne (hero, ajout rapide,
//  objectif, journal, timing, suggestions), vocabulaire visuel (mono/labels
//  `.lab`) unifié avec le reste de l'écran. Voir le rendu de l'agent pour le
//  détail des écarts maquette/Angular tranchés (jauge, ligne d'en-tête macros,
//  frise, journal).
//
//  Toutes les déclarations de ce fichier sont `private` (fileprivate) ou
//  préfixées `Nutrition*` pour ne rien exposer qui puisse entrer en
//  collision avec les autres écrans (`Screens/Home`, `Screens/Health`…)
//  compilés dans la même cible.
//

import SwiftUI

struct NutritionView: View {
    @State private var viewModel = NutritionViewModel()
    /// Incrémenté par le FAB « + » de la coquille pour ouvrir la feuille
    /// d'ajout. Le FAB vit dans `PulseShellView` (hors barre d'onglets) afin
    /// de flotter AU-DESSUS de la barre — équivalent natif du `.fab` web en
    /// `position:fixed; z-index:90`. Posé ici en overlay du `ScrollView`, il
    /// passait derrière la barre (le `ScrollView` s'étend sous le
    /// `safeAreaInset` de la coquille), d'où l'impossibilité de le toucher.
    var addTrigger: Int = 0

    var body: some View {
        NavigationStack {
            content
                .background(Color.pulseBackground)
                .navigationTitle("Nutrition")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            await viewModel.load()
        }
        .onChange(of: addTrigger) { _, _ in
            viewModel.openAddSheet()
        }
        .sheet(isPresented: Binding(
            get: { viewModel.addSheetOpen },
            set: { open in if !open { viewModel.closeAddSheet() } }
        )) {
            NutritionAddFoodSheet(viewModel: viewModel)
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

    /// Ordre = DOM desktop d'Angular ramené à une colonne : `#hero`
    /// (`macros` ici), `#quickAdd`, `#objective`, `#journal`, `#timing`,
    /// `#suggestions` (lignes 736-779 de `nutrition.component.ts`).
    private var loadedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseSpacing.md) {
                NutritionDayHeader(viewModel: viewModel)

                if let day = viewModel.day {
                    NutritionMacrosCard(day: day)
                }

                if !viewModel.frequent.isEmpty {
                    NutritionFrequentCard(items: viewModel.frequent, isMutating: viewModel.isMutating) { food in
                        Task { await viewModel.quickAdd(food) }
                    }
                }

                if let target = viewModel.targetInfo {
                    NutritionObjectiveCard(target: target, weekly: viewModel.weekly)
                }

                if let day = viewModel.day {
                    NutritionJournalCard(
                        day: day,
                        isMutating: viewModel.isMutating,
                        onEdit: { entry in viewModel.editEntry(entry) },
                        onDelete: { id in Task { await viewModel.deleteEntry(id) } }
                    )
                }

                if let day = viewModel.day {
                    NutritionTimingCard(day: day, isToday: viewModel.isToday)
                }

                if !viewModel.suggestions.isEmpty {
                    NutritionSuggestionsCard(day: viewModel.day, items: viewModel.suggestions, isMutating: viewModel.isMutating) { item in
                        Task { await viewModel.addSuggestion(item) }
                    }
                }
            }
            .padding(.horizontal, PulseSpacing.lg)
            .padding(.top, PulseSpacing.sm)
            // Espace pour ne pas laisser le FAB recouvrir la dernière carte.
            .padding(.bottom, PulseSpacing.xxl)
        }
    }
}

// MARK: - En-tête (titre + navigation de jour)
//
// Miroir de `.head`/`.head-id`/`.nav-day`/`.sq`/`.picker` (Angular, lignes
// 973-982 du CSS) : titre 24pt semibold tracking -0.2, 3 pastilles 40×40
// rayon 11 (‹ / libellé du jour / ›), la pastille suivante pâlie quand
// désactivée (déjà aujourd'hui). Le libellé central n'ouvre pas de
// calendrier (pas d'équivalent natif à `app-date-picker` repris ici) : texte
// seul, la navigation se fait via les deux pastilles ‹ ›.

private struct NutritionDayHeader: View {
    var viewModel: NutritionViewModel

    var body: some View {
        HStack(alignment: .center, spacing: PulseSpacing.md) {
            Text("Nutrition")
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(Color.pulseTextPrimary)
            Spacer()
            HStack(spacing: 6) {
                Button {
                    viewModel.shiftDay(by: -1)
                } label: {
                    Text("‹").font(.system(size: 14, design: .monospaced))
                }
                .buttonStyle(NutritionDayPillStyle())

                Text(nutritionShortDateLabel(isToday: viewModel.isToday, date: viewModel.date))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.pulseTextPrimary)
                    .padding(.horizontal, PulseSpacing.md)
                    .frame(height: 40)
                    .background(Color.pulseSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.pulseBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                Button {
                    viewModel.shiftDay(by: 1)
                } label: {
                    Text("›").font(.system(size: 14, design: .monospaced))
                }
                .buttonStyle(NutritionDayPillStyle())
                .disabled(viewModel.isToday)
            }
        }
    }
}

private struct NutritionDayPillStyle: ButtonStyle {
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

private func nutritionParseDay(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)
}

private func nutritionShortDateLabel(isToday: Bool, date: String) -> String {
    if isToday { return "aujourd'hui" }
    guard let parsed = nutritionParseDay(date) else { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "fr_FR")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "d MMM"
    return formatter.string(from: parsed)
}

// MARK: - Libellé de section (mono UPPERCASE) — équivalent `.lab`
//
// Chaque en-tête de carte Angular (« Aujourd'hui », « Objectif du jour »,
// « Journée », « Timing », « Pour finir la journée »…) partage la même
// classe `.lab` (mono 11pt, tracking .12em, `--text-dim`) — PAS le style
// `.headline` gras que fournit le `SectionHeader` partagé de
// `DesignSystem.swift` (utilisé par les autres écrans). On ne touche pas ce
// composant partagé (risque de régression ailleurs) : un équivalent local,
// `Nutrition`-préfixé, reproduit `.lab` pour cet écran seulement.
private struct NutritionSectionLabel<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(Color.pulseTextSecondary)
            Spacer()
            trailing
        }
    }
}

// MARK: - Carte macros (kcal + protéines/lipides/glucides/fibres)
//
// Miroir de `ng-template #macros` (Angular, lignes 535-591) — PAS `#hero`
// (`.hero{display:none}` par défaut, réservé au desktop). Structure : ligne
// du haut = fourchette kcal seule, alignée à droite (aucun libellé
// « Aujourd'hui »/programme sur cette ligne — la maquette lignes 870-872 n'en
// montre pas non plus, contrairement au `.lab` du `.between` Angular ; la
// maquette l'emporte ici sur ce détail de mise en page) ; grande valeur kcal
// mono 44pt semibold ; jauge ; séparateur ; grille 2 colonnes des 4 macros
// (ordre Angular : protéines, lipides, glucides, fibres).
private struct NutritionMacrosCard: View {
    let day: NutritionDay

    private var bars: [NutritionBarModel] { nutritionBars(for: day) }
    private var kcalBar: NutritionBarModel? { bars.first { $0.key == "kcal" } }
    private var macroBars: [NutritionBarModel] { bars.filter { $0.key != "kcal" } }

    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                if let kcalBar {
                    HStack {
                        Spacer()
                        Text(nutritionKcalRangeLabel(kcalBar))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }

                    HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
                        Text(nutritionValueText(kcalBar.consumed))
                            .font(.system(size: 44, weight: .semibold, design: .monospaced))
                            .foregroundStyle(kcalBar.consumed == nil ? Color.pulseTextSecondary : Color.pulseTextPrimary)
                        Spacer()
                        Text("kcal")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }

                    NutritionGaugeBar(
                        value: kcalBar.consumed, range: kcalBar.range,
                        target: kcalBar.target, scaleMax: kcalBar.scaleMax, tint: .pulseTextPrimary
                    )

                    NutritionHairline()
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    ForEach(macroBars) { bar in
                        NutritionMacroCell(bar: bar)
                    }
                }

                if let proteinPerKg = day.proteinPerKg {
                    Text("\(nutritionFormatted(proteinPerKg, decimals: 1)) g de protéines par kg")
                        .font(.caption)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
        }
    }
}

/// Séparateur fin — équivalent `border-top:1px solid var(--line)` (Angular).
private struct NutritionHairline: View {
    var body: some View {
        Rectangle().fill(Color.pulseBorder).frame(height: 0.5)
    }
}

private struct NutritionMacroCell: View {
    let bar: NutritionBarModel

    var body: some View {
        let hit = nutritionInRange(bar)
        VStack(alignment: .leading, spacing: 6) {
            Text(bar.label.uppercased())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Color.pulseTextSecondary)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(nutritionValueText(bar.consumed))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(hit ? Color.pulseSuccess : Color.pulseTextPrimary)
                Text(bar.unit)
                    .font(.system(size: 11, design: .monospaced))
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
    // Couleurs alignées sur `NutritionComponent.bars()` (Angular) — pas sur
    // une intuition : kcal reste en texte neutre (déjà mis en avant par sa
    // taille), protéines en `--accent`, mais lipides/glucides/fibres
    // reprennent volontairement des teintes d'autres métriques du thème
    // (`--m-sleep`/`--m-cal`/`--m-steps`), fidèlement reportées ici.
    let defs: [(key: String, label: String, unit: String, color: Color, consumed: Double?, target: Double?)] = [
        ("kcal", "Calories", "kcal", .pulseTextPrimary, logged ? day.totals.kcal : nil, day.targets.kcal),
        ("protein", "Protéines", "g", .pulseAccent, logged ? day.totals.protein : nil, day.targets.protein),
        ("fat", "Lipides", "g", .pulseSleep, logged ? day.totals.fat : nil, day.targets.fat),
        ("carbs", "Glucides", "g", .pulseCalories, logged ? day.totals.carbs : nil, day.targets.carbs),
        ("fiber", "Fibres", "g", .pulseSteps, logged ? day.totals.fiber : nil, day.targets.fiber),
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

/// « fourchette X – Y » si une fourchette existe (miroir du `@if (k.range)`
/// Angular, ligne 541 : préfixe uniquement quand une fourchette est connue,
/// jamais pour « cible X »/« sans cible »).
private func nutritionKcalRangeLabel(_ bar: NutritionBarModel) -> String {
    bar.range != nil ? "fourchette \(bar.rangeText)" : bar.rangeText
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

/// Jauge horizontale — piste 4pt + zone de fourchette translucide + un seul
/// repère (3pt, pleine hauteur du conteneur, coins arrondis 2).
///
/// Écart maquette/Angular tranché ici : la maquette légende ce repère
/// « repère de cible » et lui donne toujours `pulseTextPrimary` (kcal). Le
/// vrai composant Angular (`shared/range-gauge.component.ts`, lu pour
/// vérifier) distingue en réalité deux éléments — un `marker` positionné sur
/// la **valeur consommée** (coloré par macro, viré au vert quand dans la
/// fourchette) et un `tick`, plus fin et discret, positionné sur la
/// **cible**. En recalculant la position du repère de la maquette à partir
/// des valeurs affichées (ex. protéines : 62 g consommés vs repère à ≈31 %
/// d'une échelle ≈216 ≈ 67 g — colle à la valeur consommée, pas à la cible),
/// le repère unique de la maquette correspond à la valeur consommée, pas à
/// la cible. Retenu : repère = valeur consommée (coloré comme demandé :
/// `pulseTextPrimary` pour kcal, teinte de la macro sinon) ; pas de `tick`
/// de cible séparé (absent de la maquette, et la grille de macros affiche
/// déjà la fourchette via la zone translucide).
private struct NutritionGaugeBar: View {
    let value: Double?
    let range: NutritionMacroRange?
    let target: Double?
    let scaleMax: Double?
    let tint: Color
    var compact: Bool = false

    private var containerHeight: CGFloat { compact ? 10 : 14 }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let maxValue = scaleMax ?? 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.pulseSkeletonShape)
                    .frame(width: width, height: 4)
                if maxValue > 0, let range, range.min != nil || range.max != nil {
                    let lo = position(range.min ?? 0, max: maxValue, width: width)
                    let hi = position(range.max ?? maxValue, max: maxValue, width: width)
                    Capsule()
                        .fill(Color.pulseEmpty)
                        .frame(width: max(hi - lo, 2), height: 4)
                        .offset(x: lo)
                }
                if maxValue > 0, let value {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint)
                        .frame(width: 3, height: containerHeight)
                        .offset(x: position(value, max: maxValue, width: width) - 1.5)
                }
            }
            .frame(width: width, height: containerHeight)
        }
        .frame(height: containerHeight)
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
            NutritionSectionLabel("Objectif du jour") {
                Text(sourceLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            if target.auto.status == "ok" {
                HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.xs) {
                    Text(nutritionValueText(target.auto.targetKcal))
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
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
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
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
//
// Miroir de `ng-template #journal` (Angular, lignes 593-635). Sur mobile,
// l'en-tête n'affiche PAS le nombre d'entrées (`.head-only{display:none}`
// par défaut, réservé au desktop) : seulement le total kcal. Chaque ligne :
// heure (largeur fixe 38) + nom/portion + sous-ligne macros (P·G·F, SANS le
// kcal — déplacé en colonne de fin, cf. rendu de l'agent pour l'arbitrage
// maquette/Angular) + kcal en fin de ligne + bouton supprimer discret
// (le bouton modifier n'est pas repris, cf. en-tête du fichier).
private struct NutritionJournalCard: View {
    let day: NutritionDay
    let isMutating: Bool
    let onEdit: (NutritionEntry) -> Void
    let onDelete: (Int) -> Void

    var body: some View {
        PulseCard {
            NutritionSectionLabel("Journée") {
                Text("\(nutritionValueText(day.totals.kcal)) kcal")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            if day.entries.isEmpty {
                Text("Aucun repas saisi — la journée reste vide, elle ne compte pas comme un zéro.")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            NutritionHairline()
                        }
                        HStack(alignment: .top, spacing: PulseSpacing.md) {
                            // Toucher la ligne édite l'entrée (formulaire
                            // pré-rempli → PUT log/:id) — miroir de `editEntry`.
                            Button {
                                onEdit(entry)
                            } label: {
                                HStack(alignment: .top, spacing: PulseSpacing.md) {
                                    Text(entry.ts.map(nutritionClock) ?? "—:—")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Color.pulseTextSecondary)
                                        .frame(width: 38, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(entry.name) · \(nutritionPortion(grams: entry.grams, units: entry.unitQty, label: entry.unitLabel))")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(Color.pulseTextPrimary)
                                            .multilineTextAlignment(.leading)
                                        Text("\(nutritionValueText(entry.protein)) P · \(nutritionValueText(entry.carbs)) G · \(nutritionValueText(entry.fiber)) F")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(Color.pulseTextSecondary)
                                    }
                                    Spacer(minLength: PulseSpacing.sm)
                                    Text(nutritionValueText(entry.kcal))
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundStyle(Color.pulseTextPrimary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isMutating)

                            Button {
                                onDelete(entry.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.pulseTextSecondary)
                            .disabled(isMutating)
                        }
                        .padding(.vertical, 13)
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
//
// Angular (`ng-template #quickAdd`, desktop uniquement) propose un widget à
// un seul aliment à la fois (chips + saisie de quantité + bascule
// unité/grammes) — interaction sensiblement différente du défilement de
// cartes ci-dessous. Repris tel quel (interaction déjà fonctionnelle et non
// spécifiée pixel par pixel dans la consigne) : seul le vocabulaire visuel
// de l'en-tête (`.lab`) est aligné.
private struct NutritionFrequentCard: View {
    let items: [NutritionFrequentFood]
    let isMutating: Bool
    let onAdd: (NutritionFrequentFood) -> Void

    var body: some View {
        PulseCard {
            NutritionSectionLabel("Ajout rapide")
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
//
// Miroir de `ng-template #frise` (Angular, lignes 722-734) : rail de la
// journée (06:00→00:00), point de progression, un repère par repas saisi,
// graduations horaires, légende. `bedtimeSummary()` (Angular) dépend de
// données de sommeil non chargées par `NutritionViewModel` (pas de champ
// « bedtime » exposé) : en-tête sans texte de fin plutôt qu'un
// « sommeil inconnu » figé qui ne refléterait pas le vrai calcul.
private struct NutritionTimingCard: View {
    let day: NutritionDay
    let isToday: Bool

    var body: some View {
        PulseCard {
            NutritionSectionLabel("Timing")
            NutritionFriseView(
                progress: nutritionDayProgress(isToday: isToday),
                marks: nutritionMealMarks(day: day),
                note: nutritionFriseNote(day: day, isToday: isToday)
            )
        }
    }
}

private let nutritionDayFromH: Double = 6
private let nutritionDaySpanH: Double = 18

private struct NutritionFriseView: View {
    let progress: Double
    let marks: [Double]
    let note: String

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .topLeading) {
                HStack {
                    Text("06:00")
                    Spacer()
                    Text("14:00")
                    Spacer()
                    Text("00:00")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
                .frame(width: width)

                ZStack(alignment: .leading) {
                    Capsule().fill(Color.pulseSurfaceAlt).frame(width: width, height: 6)
                    Capsule().fill(Color.pulseTextPrimary).frame(width: width * CGFloat(progress / 100), height: 6)
                }
                .offset(y: 22)

                ForEach(Array(marks.enumerated()), id: \.offset) { _, pct in
                    Circle()
                        .fill(Color.pulseAccent)
                        .overlay(Circle().strokeBorder(Color.pulseSurface, lineWidth: 3))
                        .frame(width: 16, height: 16)
                        .offset(x: width * CGFloat(pct / 100) - 8, y: 17)
                }

                Text(note)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.pulseTextSecondary)
                    .offset(y: 40)
            }
        }
        .frame(height: 52)
    }
}

private func nutritionDayProgress(isToday: Bool) -> Double {
    guard isToday else { return 100 }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let comps = calendar.dateComponents([.hour, .minute], from: Date())
    let h = Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60
    return min(max(((h - nutritionDayFromH) / nutritionDaySpanH) * 100, 0), 100)
}

private func nutritionMealMarks(day: NutritionDay) -> [Double] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return day.entries.compactMap { entry -> Double? in
        guard let ts = entry.ts else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let h = Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60
        return min(max(((h - nutritionDayFromH) / nutritionDaySpanH) * 100, 0), 100)
    }
}

private func nutritionFriseNote(day: NutritionDay, isToday: Bool) -> String {
    let entries = day.entries
    let n = entries.count
    guard n > 0 else { return "aucune prise saisie" }
    let count = "\(n) prise\(n > 1 ? "s" : "")"
    guard let last = entries.compactMap({ $0.ts }).max() else { return count }
    if !isToday {
        return "\(count) · dernier repas \(nutritionClock(last))"
    }
    let mins = max(Int((Date().timeIntervalSince1970 - Double(last)) / 60), 0)
    let ago = mins < 60 ? "\(mins) min" : "\(mins / 60) h \(String(format: "%02d", mins % 60))"
    return "\(count) · dernier repas il y a \(ago)"
}

// MARK: - Suggestions pour finir la journée

private struct NutritionSuggestionsCard: View {
    let day: NutritionDay?
    let items: [NutritionSuggestionItem]
    let isMutating: Bool
    let onAdd: (NutritionSuggestionItem) -> Void

    private var top: [NutritionSuggestionItem] { Array(items.prefix(4)) }

    var body: some View {
        PulseCard {
            NutritionSectionLabel("Pour finir la journée") {
                Text(nutritionSuggestSummary(count: top.count, remainingProtein: day?.remaining.protein))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: PulseSpacing.sm) {
                ForEach(top) { item in
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

private func nutritionSuggestSummary(count: Int, remainingProtein: Double?) -> String {
    let base = count > 0 ? "\(count) idée\(count > 1 ? "s" : "")" : "aucune idée"
    guard let remainingProtein else { return base }
    return "\(base) · reste \(Int(remainingProtein.rounded())) g de protéines"
}

#Preview {
    NutritionView()
}
