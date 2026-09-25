//
//  NutritionAddFoodSheet.swift
//  all (bridge-connect)
//
//  Feuille « Ajouter un aliment », ouverte depuis le bouton flottant « + »
//  de `NutritionView`. Miroir du sous-arbre mobile de `NutritionComponent`
//  (`app-sheet` + `sheetView` : `menu` → `frequent` | `manual`) —
//  `custom-connect/web/src/app/pages/nutrition/nutrition.component.ts`.
//
//  Trois écrans, empilés dans une seule `NavigationStack` propre à la
//  feuille (titre + bouton retour/fermer dans la barre) :
//    - `.menu`     : recherche (bibliothèque locale, débounce 250 ms) +
//                    accès à la recherche en ligne / aux aliments fréquents /
//                    à la saisie manuelle — miroir du bloc `@case`/`sfind`.
//    - `.frequent` : liste complète des aliments fréquents, « + » = portion
//                    habituelle — miroir de `freqList`.
//    - `.manual`   : formulaire (aliment repéré ou saisie libre) — miroir de
//                    `pendingForm`.
//
//  Non repris : scan de code-barres (caméra — hors périmètre de cette passe)
//  et modification d'une entrée déjà journalisée (`editEntry`, non demandée).
//  Conteneurs visuels alignés sur le socle natif (`PulseCard`) plutôt que sur
//  le CSS `.srow`/`.sfind` du web, qui n'a pas d'équivalent direct en SwiftUI
//  — libellés et comportement, eux, sont repris à l'identique.
//

import SwiftUI

struct NutritionAddFoodSheet: View {
    @Bindable var viewModel: NutritionViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.sheetView {
                case .menu:
                    NutritionAddMenu(viewModel: viewModel)
                case .scan:
                    NutritionScanView(viewModel: viewModel)
                case .frequent:
                    NutritionAddFrequentList(viewModel: viewModel)
                case .manual:
                    NutritionAddManualForm(viewModel: viewModel)
                }
            }
            .background(Color.pulseBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.sheetView != .menu {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            viewModel.sheetGoBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") {
                        viewModel.closeAddSheet()
                    }
                    .tint(Color.pulseAccent)
                }
            }
        }
    }

    /// Miroir de `SHEET_TITLES`/`sheetTitle()` (Angular) — toujours « Ajouter
    /// au journal » sur `.manual` puisque l'édition d'une entrée existante
    /// n'est pas reprise.
    private var title: String {
        switch viewModel.sheetView {
        case .menu: return "Ajouter un aliment"
        case .scan: return "Scanner un code-barres"
        case .frequent: return "Aliments fréquents"
        case .manual: return "Ajouter au journal"
        }
    }
}

// MARK: - Menu (recherche + entrées)

private struct NutritionAddMenu: View {
    @Bindable var viewModel: NutritionViewModel

    private var trimmedQuery: String {
        viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                PulseCard {
                    searchField

                    if let msg = viewModel.searchMsg {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }

                    if !viewModel.results.isEmpty {
                        Text(viewModel.searchSource == "online" ? "Open Food Facts" : "Ta bibliothèque")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(Color.pulseTextSecondary)

                        VStack(spacing: 0) {
                            ForEach(Array(viewModel.results.enumerated()), id: \.offset) { index, food in
                                if index > 0 { Divider() }
                                Button {
                                    viewModel.pick(food)
                                } label: {
                                    HStack {
                                        Text(food.name)
                                            .foregroundStyle(Color.pulseTextPrimary)
                                            .lineLimit(1)
                                        Spacer()
                                        if let kcal = food.kcal {
                                            Text("\(Int(kcal.rounded())) kcal/100 g")
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(Color.pulseTextSecondary)
                                        }
                                    }
                                    .padding(.vertical, PulseSpacing.sm)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if trimmedQuery.count >= 2 && !viewModel.onlineDone {
                        Divider()
                        Button {
                            Task { await viewModel.searchOnline() }
                        } label: {
                            HStack(spacing: PulseSpacing.sm) {
                                Image(systemName: "globe")
                                Text("Chercher « \(trimmedQuery) » en ligne")
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                            }
                            .foregroundStyle(Color.pulseAccent)
                            .padding(.vertical, PulseSpacing.sm)
                        }
                        .buttonStyle(.plain)
                    }
                }

                PulseCard {
                    Button {
                        viewModel.openScan()
                    } label: {
                        HStack(spacing: PulseSpacing.md) {
                            Image(systemName: "barcode.viewfinder")
                                .foregroundStyle(Color.pulseTextSecondary)
                            Text("Scanner un code-barres")
                                .foregroundStyle(Color.pulseTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                        .padding(.vertical, PulseSpacing.xs)
                    }
                    .buttonStyle(.plain)

                    Divider()

                    Button {
                        viewModel.openFrequentList()
                    } label: {
                        HStack(spacing: PulseSpacing.md) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(Color.pulseTextSecondary)
                            Text("Aliments fréquents")
                                .foregroundStyle(Color.pulseTextPrimary)
                            Spacer()
                            Text("\(viewModel.frequent.count)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                        .padding(.vertical, PulseSpacing.xs)
                    }
                    .buttonStyle(.plain)

                    Divider()

                    Button {
                        viewModel.openManual()
                    } label: {
                        HStack(spacing: PulseSpacing.md) {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle(Color.pulseTextSecondary)
                            Text("Saisie manuelle")
                                .foregroundStyle(Color.pulseTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                        .padding(.vertical, PulseSpacing.xs)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(PulseSpacing.lg)
        }
    }

    private var searchField: some View {
        HStack(spacing: PulseSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.pulseTextSecondary)
            TextField("Chercher un aliment", text: $viewModel.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: viewModel.query) { _, _ in
                    viewModel.onQueryChanged()
                }
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, PulseSpacing.md)
        .frame(height: 44)
        .background(Color.pulseSurfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous))
    }
}

// MARK: - Aliments fréquents (liste complète)

private struct NutritionAddFrequentList: View {
    let viewModel: NutritionViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseSpacing.md) {
                if viewModel.frequent.isEmpty {
                    Text("Tes aliments fréquents apparaîtront ici après quelques repas.")
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                } else {
                    PulseCard {
                        ForEach(Array(viewModel.frequent.enumerated()), id: \.element.id) { index, food in
                            if index > 0 { Divider() }
                            HStack(spacing: PulseSpacing.md) {
                                Button {
                                    viewModel.openFrequentItem(food)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(food.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Color.pulseTextPrimary)
                                            .lineLimit(1)
                                        Text(nutritionAddFrequentSub(food))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(Color.pulseTextSecondary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    Task { await viewModel.addFrequentFromSheet(food) }
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(Color.pulseSurface)
                                        .frame(width: 42, height: 42)
                                        .background(Color.pulseTextPrimary)
                                        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(viewModel.isMutating)
                            }
                            .padding(.vertical, PulseSpacing.xs)
                        }
                    }

                    Text("Le + enregistre la portion habituelle. Touche le nom pour changer la quantité ou l'heure.")
                        .font(.caption2)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            .padding(PulseSpacing.lg)
        }
    }
}

/// Sous-titre d'une ligne « aliment fréquent » — miroir de
/// `frequentPortion()` + kcal + nombre d'usages, tel qu'affiché dans
/// `freqList` (Angular) : `"<portion> · <kcal> kcal · <n> fois"`.
private func nutritionAddFrequentSub(_ food: NutritionFrequentFood) -> String {
    var parts: [String] = []
    if let units = food.units, units > 0, food.unitGrams != nil {
        let qty = units.rounded() == units ? String(Int(units)) : String(format: "%.1f", units)
        let label = food.unitLabel?.trimmingCharacters(in: .whitespaces)
        parts.append("\(qty) \((label?.isEmpty == false ? label! : "unité"))")
    } else {
        parts.append("\(Int(food.grams.rounded())) g")
    }
    if let kcalPer100 = food.kcal {
        parts.append("\(Int((kcalPer100 * food.grams / 100).rounded())) kcal")
    }
    parts.append("\(food.uses) fois")
    return parts.joined(separator: " · ")
}

// MARK: - Saisie manuelle (formulaire)

private struct NutritionAddManualForm: View {
    @Bindable var viewModel: NutritionViewModel

    private let labelFont = Font.system(size: 10, weight: .medium, design: .monospaced)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                PulseCard {
                    field("Aliment", placeholder: "Nom de l'aliment", text: $viewModel.pName)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: PulseSpacing.md) {
                        numberField("kcal /100 g", value: $viewModel.pKcal)
                        numberField("Protéines /100 g", value: $viewModel.pProtein)
                        numberField("Glucides /100 g", value: $viewModel.pCarbs)
                        numberField("Fibres /100 g", value: $viewModel.pFiber)
                        field("Objet", placeholder: "pièce, tranche…", text: $viewModel.pUnitLabel)
                        numberField("Poids d'1 objet", value: $viewModel.pUnitGrams, placeholder: "g")
                    }
                }

                PulseCard {
                    HStack(alignment: .top, spacing: PulseSpacing.md) {
                        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                            Text("QUANTITÉ")
                                .font(labelFont)
                                .foregroundStyle(Color.pulseTextSecondary)
                            HStack(spacing: PulseSpacing.sm) {
                                TextField("", text: amountText)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    viewModel.toggleUnit()
                                } label: {
                                    Text(viewModel.amountUnitText())
                                        .font(.system(size: 13, design: .monospaced))
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.pUnitGrams == nil)
                            }
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                            Text("HEURE")
                                .font(labelFont)
                                .foregroundStyle(Color.pulseTextSecondary)
                            DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }

                    Text(viewModel.amountHintText())
                        .font(.caption2)
                        .foregroundStyle(Color.pulseTextSecondary)

                    Toggle("Enregistrer dans ma bibliothèque", isOn: $viewModel.saveToLib)
                        .font(.footnote)
                }
            }
            .padding(PulseSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            // Ancrée hors du `ScrollView` : `safeAreaInset` remonte
            // automatiquement au-dessus du clavier, contrairement au dernier
            // élément d'un `ScrollView` (masqué / hors d'atteinte tant que le
            // clavier est affiché).
            HStack(spacing: PulseSpacing.sm) {
                Button {
                    Task { await viewModel.addPending() }
                } label: {
                    Group {
                        if viewModel.isMutating {
                            ProgressView()
                        } else {
                            Text("Ajouter")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.pulseAccent)
                .disabled(isAddDisabled)

                Button {
                    viewModel.dismissPending()
                } label: {
                    Text("Annuler")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(PulseSpacing.lg)
            .background(
                Color.pulseSurface
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.pulseBorder)
                            .frame(height: 0.5)
                    }
            )
        }
    }

    private var isAddDisabled: Bool {
        viewModel.isMutating || viewModel.pName.isEmpty || (viewModel.amount ?? 0) <= 0
    }

    private var amountText: Binding<String> {
        Binding<String>(
            get: {
                guard let value = viewModel.amount else { return "" }
                return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
            },
            set: { newValue in
                let normalized = newValue.replacingOccurrences(of: ",", with: ".")
                viewModel.amount = normalized.isEmpty ? nil : Double(normalized)
            }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding<Date>(
            get: {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "HH:mm"
                return formatter.date(from: viewModel.pTime) ?? Date()
            },
            set: { newDate in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "HH:mm"
                viewModel.pTime = formatter.string(from: newDate)
            }
        )
    }

    @ViewBuilder
    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
            Text(label.uppercased())
                .font(labelFont)
                .foregroundStyle(Color.pulseTextSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func numberField(_ label: String, value: Binding<Double?>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
            Text(label.uppercased())
                .font(labelFont)
                .foregroundStyle(Color.pulseTextSecondary)
            TextField(placeholder, text: doubleText(value))
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func doubleText(_ value: Binding<Double?>) -> Binding<String> {
        Binding<String>(
            get: {
                guard let v = value.wrappedValue else { return "" }
                return v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
            },
            set: { newValue in
                let normalized = newValue.replacingOccurrences(of: ",", with: ".")
                value.wrappedValue = normalized.isEmpty ? nil : Double(normalized)
            }
        )
    }
}
