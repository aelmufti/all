//
//  NutritionWeightCard.swift
//  all (bridge-connect)
//
//  Carte Poids de l'écran Nutrition (saisie, courbe, historique, statut
//  d'écriture vers la montre) — déplacée depuis l'écran Santé. `WeightViewModel`
//  porte son propre état : une panne `api/weight` ne touche pas le reste de
//  l'écran hôte, et la série est indépendante de la date affichée (seule la
//  pesée « du jour » en dépend).
//
//  Servi en mode Téléphone par `RealLocalPulseBackend` (`weight_log`, cf.
//  `docs/stockage-local.md`) ; l'écriture vers la montre passe par
//  `BLEManager.requestWatchWeightWrite`, indépendante du mode de stockage.
//

import Charts
import Observation
import SwiftUI

@MainActor
@Observable
final class WeightViewModel {
    /// Jour affiché par l'écran hôte — celui de la pesée saisie/effacée.
    private(set) var date: String
    private(set) var weight: WeightData?

    var weightInputText: String = ""
    private(set) var weightMessage: String?
    private(set) var isSavingWeight = false

    private let client: PulseAPIClient

    init(client: PulseAPIClient = .shared, date: String) {
        self.client = client
        self.date = date
    }

    func selectDate(_ newDate: String) {
        guard newDate != date else { return }
        date = newDate
        weightMessage = nil
        weightInputText = Self.formatKg(shownWeight)
    }

    func load() async {
        do {
            // Fenêtre max serveur : la série/l'historique/la courbe démarrent à
            // la toute première pesée saisie (et non 90 jours en arrière avec du
            // vide avant la 1ʳᵉ saisie).
            let data: WeightData = try await client.get("api/weight", query: ["days": "3660"])
            weight = data
            weightInputText = Self.formatKg(shownWeight)
        } catch {
            // Le poids est secondaire à l'écran — une panne ici ne doit pas
            // empêcher d'afficher le reste, donc pas de propagation d'erreur.
        }
    }

    /// Poids du jour affiché s'il existe, sinon le dernier connu — miroir de
    /// `dayWeight`/`shownWeight` (Angular).
    var dayWeight: Double? {
        weight?.series.first { $0.date == date }?.kg
    }

    var shownWeight: Double? {
        dayWeight ?? weight?.current
    }

    var weightDelta: Double? { weight?.deltaKg }

    var weighLabel: String {
        guard let weight, weight.entries > 0 else { return "aucune pesée" }
        if dayWeight != nil { return "pesée du jour" }
        guard let currentDate = weight.currentDate else { return "aucune pesée" }
        return "dernière : \(HealthViewModel.shortDateLabel(currentDate))"
    }

    var watchNote: String? {
        guard let push = weight?.push, push.status != "idle" else { return nil }
        guard let pushKg = push.kg, let current = weight?.current else { return nil }
        guard abs(pushKg - current) < 0.05 else { return nil }
        switch push.status {
        case "sent": return "poids transmis à la montre"
        case "pending": return "poids en attente de la montre"
        default: return "poids non transmis à la montre"
        }
    }

    func saveWeight() async {
        guard let kg = Double(weightInputText.replacingOccurrences(of: ",", with: ".")) else { return }
        isSavingWeight = true
        weightMessage = nil
        defer { isSavingWeight = false }
        do {
            let _: WeightSaveResult = try await client.post(
                "api/weight",
                body: WeightSaveRequest(date: date, kg: kg)
            )
            await load()
            // Écriture auto vers la montre : le téléphone pousse le poids dans le
            // profil de la montre (le seul réglage qu'il pousse). Part tout de
            // suite si la montre est liée, sinon au prochain lien BLE (cf.
            // `BLEManager.requestWatchWeightWrite`). La pesée reste par ailleurs
            // stockée côté Pulse quoi qu'il arrive.
            BLEManager.shared.requestWatchWeightWrite(kg: kg)
            weightMessage = "Pesée enregistrée pour le \(HealthViewModel.shortDateLabel(date))."
        } catch {
            weightMessage = "Poids refusé : vérifie la valeur (entre 25 et 300 kg)."
        }
    }

    func removeWeight() async {
        weightMessage = nil
        do {
            try await client.delete("api/weight/\(date)")
            await load()
            weightMessage = "Pesée effacée."
        } catch {
            weightMessage = "Suppression impossible."
        }
    }

    private static func formatKg(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.1f", value)
    }
}

// MARK: - Poids

struct WeightCard: View {
    @Bindable var viewModel: WeightViewModel
    /// Tap sur une pesée de l'historique : l'écran hôte se place sur ce jour.
    let onSelectDate: (String) -> Void
    /// Pesée enregistrée/effacée : l'écran hôte recharge ce qui en dépend.
    let onChange: () async -> Void
    /// État de l'écriture du poids vers la montre par le téléphone (upload FIT,
    /// cf. `BLEManager.requestWatchWeightWrite`) — distinct du statut de push
    /// côté serveur (`viewModel.watchNote`, qui ne concerne que le pont homelab).
    @ObservedObject private var ble = BLEManager.shared
    /// Focus du champ de saisie — sert à refermer le pavé numérique dès qu'on
    /// enregistre (le `.decimalPad` iOS n'a pas de touche « retour »).
    @FocusState private var weightFieldFocused: Bool
    /// Pesée survolée sur la courbe de tendance — remplace la grosse valeur du
    /// jour par la pesée pointée (comme les graphes de Santé).
    @State private var weightHover: WeightSeriesPoint?

    private var canSaveWeight: Bool {
        !viewModel.weightInputText.isEmpty && !viewModel.isSavingWeight
    }

    var body: some View {
        PulseCard {
            HStack {
                Text("POIDS")
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
                    .tracking(0.6)
                Spacer()
                Text(weightHover.map { HealthViewModel.shortDateLabel($0.date) } ?? viewModel.weighLabel)
                    .font(PulseFont.metricUnit)
                    .foregroundStyle(weightHover != nil ? Color.pulseTextPrimary : Color.pulseTextSecondary)
            }
            HStack(alignment: .lastTextBaseline) {
                // Maquette / SCSS Pulse : classe `.weigh .n44` (44px), même
                // jeton que la durée de sommeil — pas `PulseFont.metricValue`.
                // Au survol de la courbe : la pesée pointée prime sur celle du jour.
                if let shown = weightHover?.kg ?? viewModel.shownWeight {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", shown))
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .foregroundStyle(
                                (weightHover == nil && viewModel.dayWeight == nil) ? Color.pulseTextSecondary : Color.pulseTextPrimary
                            )
                            .contentTransition(.numericText())
                        Text("kg")
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pulseTextPrimary)
                }
                Spacer()
                if let delta = viewModel.weightDelta {
                    // Miroir `.delta.down` (perte → succès) / `.delta.up`
                    // (prise → teinte calories, `--m-cal`) — jamais neutre.
                    Text("\(delta > 0 ? "+" : "")\(String(format: "%.1f", delta)) kg")
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(
                            delta < 0 ? Color.pulseSuccess
                                : delta > 0 ? Color.pulseCalories
                                : Color.pulseTextSecondary
                        )
                }
            }

            if let series = viewModel.weight?.series, series.count > 1 {
                WeightLineChart(series: series, hover: $weightHover)
                    .frame(height: 110)
            }

            // Historique des pesées réellement stockées (`weight_log`, via
            // `weight.series`) — au-delà de la courbe de tendance : chaque
            // pesée saisie, la plus récente en tête, tap = aller à ce jour
            // (pour la corriger / l'effacer). Ajout demandé (le web n'a que la
            // courbe) pour « voir les pesées stockées dans la bdd ».
            if let series = viewModel.weight?.series, !series.isEmpty {
                let recent = Array(series.reversed())
                VStack(spacing: 0) {
                    ForEach(recent.prefix(8), id: \.date) { point in
                        Button {
                            onSelectDate(point.date)
                        } label: {
                            HStack {
                                Text(HealthViewModel.shortDateLabel(point.date))
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(
                                        point.date == viewModel.date ? Color.pulseTextPrimary : Color.pulseTextSecondary
                                    )
                                Spacer()
                                Text("\(String(format: "%.1f", point.kg)) kg")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.pulseTextPrimary)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Color.pulseBorder).frame(height: 0.5)
                        }
                    }
                    if recent.count > 8 {
                        Text("+ \(recent.count - 8) pesée\(recent.count - 8 > 1 ? "s" : "") plus ancienne\(recent.count - 8 > 1 ? "s" : "") — navigue les jours")
                            .font(.caption2)
                            .foregroundStyle(Color.pulseTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, PulseSpacing.xs)
                    }
                }
            }

            HStack(spacing: PulseSpacing.sm) {
                TextField("kg", text: $viewModel.weightInputText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .focused($weightFieldFocused)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.pulseTextPrimary)
                    .padding(.horizontal, PulseSpacing.md)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous)
                            .fill(Color.pulseSurfaceAlt)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous)
                            .stroke(weightFieldFocused ? Color.pulseAccent : Color.pulseBorder, lineWidth: 1)
                    )

                Button {
                    // Referme le pavé numérique puis enregistre.
                    weightFieldFocused = false
                    Task {
                        await viewModel.saveWeight()
                        await onChange()
                    }
                } label: {
                    Text("Enregistrer")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.pulseOnAccent)
                        .padding(.horizontal, PulseSpacing.lg)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous)
                                .fill(canSaveWeight ? Color.pulseAccent : Color.pulseEmpty)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSaveWeight)
            }

            HStack(alignment: .firstTextBaseline) {
                if let message = viewModel.weightMessage {
                    Text(message).font(.caption).foregroundStyle(Color.pulseTextSecondary)
                } else if let series = viewModel.weight?.series, series.count > 1 {
                    Text("\(series.count) pesées · poids réel saisi")
                        .font(.caption)
                        .foregroundStyle(Color.pulseTextSecondary)
                } else {
                    Text("Deux pesées suffisent à tracer la tendance.")
                        .font(.caption)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                Spacer()
                if viewModel.dayWeight != nil {
                    Button("effacer") {
                        Task {
                            await viewModel.removeWeight()
                            await onChange()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.pulseTextSecondary)
                }
            }

            if let note = viewModel.watchNote {
                // Miroir `.watch.on` (Angular) : le statut « transmis » se lit
                // sur `push.status === 'sent'`, pas sur une sous-chaîne du
                // libellé (« non transmis » contient aussi « transmis »).
                Text(note)
                    .font(.caption)
                    .foregroundStyle(
                        viewModel.weight?.push.status == "sent" ? Color.pulseSteps : Color.pulseTextSecondary
                    )
            }

            // Écriture directe téléphone → montre (upload FIT). Ne s'affiche que
            // lorsqu'une écriture est en cours/aboutie/échouée sur ce lien.
            if ble.weightWriteState != .idle {
                HStack(spacing: PulseSpacing.xs) {
                    Image(systemName: watchWriteIcon)
                        .font(.system(size: 11))
                    Text("Montre : \(ble.weightWriteState.label)")
                        .font(.caption)
                }
                .foregroundStyle(watchWriteColor)
            }
        }
    }

    private var watchWriteIcon: String {
        switch ble.weightWriteState {
        case .sent: return "checkmark.circle.fill"
        case .refused, .failed: return "exclamationmark.triangle.fill"
        case .uploading: return "arrow.up.circle"
        default: return "clock"
        }
    }

    private var watchWriteColor: Color {
        switch ble.weightWriteState {
        case .sent: return Color.pulseSteps
        case .refused, .failed: return Color.pulseCalories
        default: return Color.pulseTextSecondary
        }
    }
}

struct WeightLineChart: View {
    let series: [WeightSeriesPoint]
    /// Pesée survolée — remontée au `WeightCard` pour que la grosse valeur
    /// affiche la pesée pointée (et sa date), comme les graphes de Santé.
    @Binding var hover: WeightSeriesPoint?

    @State private var selectedDate: Date?

    /// Domaine Y calé sur les pesées RÉELLES saisies (min → max), avec une
    /// marge, plutôt que l'échelle auto (qui écrasait la courbe en une ligne
    /// plate). On veut « voir » les kilos qui bougent, pas un 0–100.
    private var yDomain: ClosedRange<Double> {
        let values = series.map(\.kg)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if lo == hi { return (lo - 1)...(hi + 1) }
        let margin = max(0.3, (hi - lo) * 0.15)
        return (lo - margin)...(hi + margin)
    }

    var body: some View {
        // Miroir `color="var(--m-steps)"` (Angular, `health.component.ts`) —
        // la tendance de poids reprend la teinte « pas », pas l'accent bleu.
        // On trace les pesées RÉELLES (`kg`), pas la moyenne 7 j lissée.
        Chart {
            ForEach(series, id: \.date) { point in
                LineMark(
                    x: .value("Date", HealthViewModel.parseDate(point.date) ?? Date()),
                    y: .value("Poids", point.kg)
                )
                .foregroundStyle(Color.pulseSteps)
                .interpolationMethod(.monotone)

                PointMark(
                    x: .value("Date", HealthViewModel.parseDate(point.date) ?? Date()),
                    y: .value("Poids", point.kg)
                )
                .foregroundStyle(Color.pulseSteps)
                .symbolSize(18)
            }
            if let sel = selectedPoint, let date = HealthViewModel.parseDate(sel.date) {
                RuleMark(x: .value("Date", date))
                    .foregroundStyle(Color.pulseTextSecondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Date", date), y: .value("Poids", sel.kg))
                    .foregroundStyle(Color.pulseSteps)
                    .symbolSize(80)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $selectedDate)
        .onChange(of: selectedDate) { _, newValue in
            hover = newValue.flatMap { nearest(to: $0) }
        }
    }

    private var selectedPoint: WeightSeriesPoint? {
        guard let selectedDate else { return nil }
        return nearest(to: selectedDate)
    }

    private func nearest(to date: Date) -> WeightSeriesPoint? {
        let t = date.timeIntervalSince1970
        return series.min {
            let a = HealthViewModel.parseDate($0.date)?.timeIntervalSince1970 ?? 0
            let b = HealthViewModel.parseDate($1.date)?.timeIntervalSince1970 ?? 0
            return abs(a - t) < abs(b - t)
        }
    }
}
