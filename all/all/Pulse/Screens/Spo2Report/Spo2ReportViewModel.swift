//
//  Spo2ReportViewModel.swift
//  all (bridge-connect)
//
//  État + logique réseau de l'écran Rapport SpO2 — miroir de
//  `Spo2ReportComponent` (Angular, `custom-connect/web/src/app/pages/
//  spo2-report/spo2-report.component.ts`) adapté au style vue-modèle iOS.
//  Un seul point d'entrée `load()` : l'endpoint ne prend aucun paramètre de
//  requête, il renvoie l'historique complet des nuits déjà filtrées côté
//  serveur.
//
//  Champs Angular volontairement omis (calculés côté composant mais jamais
//  lus par le template — `weekday`/`t90Pct` de `NightView`, cf. lignes
//  51/512/628 du composant) : pas de raison de les reporter ici.
//

import Foundation
import Observation

@MainActor
@Observable
final class Spo2ReportViewModel {

    private(set) var report: Spo2Report?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    private let client: PulseAPIClient

    init(client: PulseAPIClient = .shared) {
        self.client = client
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            report = try await client.get("api/wellness/spo2-report")
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func retry() async {
        await load()
    }

    // MARK: - Vues dérivées (miroir des `computed()` Angular)

    var nights: [Spo2NightView] {
        (report?.nights ?? []).map(Self.makeNightView)
    }

    var totals: Spo2ReportTotals {
        Self.makeTotals(nights: report?.nights ?? [])
    }

    /// Miroir de `periodLabel` — une seule date ou une plage « du … au … ».
    var periodLabel: String {
        let views = nights
        guard let first = views.first, let last = views.last else { return "" }
        return views.count == 1 ? first.dayLabel : "du \(first.dayLabel) au \(last.dayLabel)"
    }

    /// Miroir de `generatedLabel`.
    var generatedLabel: String {
        guard let ts = report?.generatedAt else { return "" }
        return Self.generatedFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Miroir de `intervalLabel` — cadence d'échantillonnage de la première
    /// nuit (toutes les nuits partagent en pratique le même intervalle).
    var intervalLabel: String {
        guard let s = report?.nights.first?.intervalS, s > 0 else { return "—" }
        guard s % 60 == 0 else { return "\(s) secondes" }
        let minutes = s / 60
        return "\(minutes) minute\(minutes > 1 ? "s" : "")"
    }

    var minCoverageMinutes: Int {
        (report?.minCoverageS ?? 0) / 60
    }

    var excludedNights: Int {
        report?.excludedNights ?? 0
    }

    // MARK: - Construction des vues de nuit

    private static func makeNightView(_ night: Spo2Night) -> Spo2NightView {
        func minutesBelow(_ count: Int) -> Int {
            Int((Double(count) * Double(night.intervalS) / 60).rounded())
        }
        // Miroir de `buildChart` (Angular) : borne basse arrondie au multiple
        // de 5 inférieur, plafonnée à 80, pour que le seuil 90 % reste visible
        // même par nuit calme.
        let lo = min(80, Int((night.min / 5).rounded(.down)) * 5)
        return Spo2NightView(
            night: night,
            dayLabel: dayLabel(night.date),
            window: "\(clock(night.startTs)) → \(clock(night.endTs))",
            coverageLabel: duration(night.coverageS),
            t90Min: minutesBelow(night.below90),
            t88Min: minutesBelow(night.below88),
            t85Min: minutesBelow(night.below85),
            chartDomain: Double(lo)...100
        )
    }

    private static func makeTotals(nights: [Spo2Night]) -> Spo2ReportTotals {
        guard !nights.isEmpty else {
            return Spo2ReportTotals(mean: 0, min: 0, t90Min: 0, t88Min: 0, t85Min: 0, coverageLabel: "—")
        }
        var sampleCount = 0
        var weightedSum = 0.0
        var minValue = 100.0
        var s90 = 0.0
        var s88 = 0.0
        var s85 = 0.0
        var coverage = 0
        for night in nights {
            sampleCount += night.sampleCount
            weightedSum += night.mean * Double(night.sampleCount)
            minValue = min(minValue, night.min)
            s90 += Double(night.below90 * night.intervalS) / 60
            s88 += Double(night.below88 * night.intervalS) / 60
            s85 += Double(night.below85 * night.intervalS) / 60
            coverage += night.coverageS
        }
        let mean = sampleCount > 0 ? (weightedSum / Double(sampleCount) * 10).rounded() / 10 : 0
        return Spo2ReportTotals(
            mean: mean,
            min: minValue,
            t90Min: Int(s90.rounded()),
            t88Min: Int(s88.rounded()),
            t85Min: Int(s85.rounded()),
            coverageLabel: duration(coverage)
        )
    }

    // MARK: - Formatage (calendaire UTC, comme le serveur — jamais `Date` dans les modèles)

    /// Miroir de `dayLabel` (Angular) — recomposition littérale de la chaîne
    /// `YYYY-MM-DD`, pas un vrai formatage calendaire.
    private static func dayLabel(_ date: String) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return date }
        return "\(parts[2])/\(parts[1])/\(parts[0])"
    }

    /// Miroir de `clock` (Angular) — `startTs`/`endTs` sont déjà décalés au
    /// fuseau d'affichage côté serveur, donc on les relit en UTC.
    private static func clock(_ ts: Int) -> String {
        clockFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Miroir de `duration` (Angular).
    private static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = Int((Double(seconds % 3600) / 60).rounded())
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m) min"
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let generatedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func message(for error: Error) -> String {
        (error as? PulseAPIError)?.errorDescription ?? "Erreur inattendue."
    }
}

/// Une nuit enrichie des libellés/bornes de graphique dérivés — miroir de
/// `NightView` (Angular), sans les champs `weekday`/`t90Pct` inutilisés par
/// le template d'origine.
struct Spo2NightView: Identifiable {
    let night: Spo2Night
    let dayLabel: String
    let window: String
    let coverageLabel: String
    let t90Min: Int
    let t88Min: Int
    let t85Min: Int
    let chartDomain: ClosedRange<Double>

    var id: String { night.date }
}

/// Synthèse sur l'ensemble de la période — miroir de `totals` (Angular).
struct Spo2ReportTotals {
    let mean: Double
    let min: Double
    let t90Min: Int
    let t88Min: Int
    let t85Min: Int
    let coverageLabel: String
}
