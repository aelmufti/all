//
//  DashboardSummary.swift
//  all (bridge-connect)
//
//  Calcule les 4 `DashboardDomainSummary` de l'aperçu Statistiques (Sommeil,
//  Entraînement, Santé, Nutrition) à partir des données déjà chargées par
//  `DashboardViewModel` — aucun nouvel appel réseau, aucune donnée inventée.
//  Défensif partout : une donnée absente donne un résumé au tiret plutôt
//  qu'un crash ou une valeur fictive.
//

import SwiftUI

/// Résumé compact d'un domaine, affiché par `DashboardSummaryCard` sur
/// l'aperçu. `spark` alimente `DashboardSparkline` (courbe muette, juste une
/// forme — moins de 2 points affiche un espace vide, jamais une erreur).
struct DashboardDomainSummary {
    enum Tone {
        case good, bad, flat

        var color: Color {
            switch self {
            case .good: return .pulseSuccess
            case .bad: return .pulseDanger
            case .flat: return .pulseTextSecondary
            }
        }
    }

    enum FlagLevel {
        case ok, warn, bad

        var color: Color {
            switch self {
            case .ok: return .pulseTextSecondary
            case .warn: return .pulseStress
            case .bad: return .pulseDanger
            }
        }
    }

    struct Delta {
        let text: String
        let tone: Tone
    }

    struct Flag {
        let text: String
        let level: FlagLevel
    }

    let title: String
    let sfSymbol: String
    let tint: Color
    let heroValue: String
    let heroUnit: String
    let spark: [Double]
    let delta: Delta?
    let footNote: String
    let flag: Flag?
}

// MARK: - Delta signé générique

/// Construit un `Delta` affiché « ▲ +X » / « ▼ −X » à partir d'une magnitude
/// déjà mise en forme (l'appelant choisit l'unité : min, %, bpm, kcal/j…) —
/// `goodWhenPositive` encode le sens sémantique du domaine (ex. la FC de repos
/// qui baisse est une bonne nouvelle, donc `false` pour la santé).
private func dashboardDelta(magnitude: String, isPositive: Bool, isZero: Bool, goodWhenPositive: Bool) -> DashboardDomainSummary.Delta {
    if isZero {
        return DashboardDomainSummary.Delta(text: "stable", tone: .flat)
    }
    let arrow = isPositive ? "▲ +" : "▼ −"
    let tone: DashboardDomainSummary.Tone = (isPositive == goodWhenPositive) ? .good : .bad
    return DashboardDomainSummary.Delta(text: "\(arrow)\(magnitude)", tone: tone)
}

/// Séparateur de milliers façon FR (« 2 100 kcal ») — seul le kcal/jour de la
/// nutrition en a besoin parmi les valeurs héros des 4 domaines.
private let dashboardThousandsFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = " "
    formatter.locale = Locale(identifier: "fr_FR")
    return formatter
}()

extension DashboardViewModel {
    // MARK: Sommeil

    var sleepSummary: DashboardDomainSummary {
        // `nights == 0` : `avgHours`/`debtHours` n'ont pas de sens (rien à
        // moyenner) — traité comme une absence de donnée, pas comme un zéro.
        guard let sleepDebt, sleepDebt.nights > 0 else {
            return DashboardDomainSummary(
                title: "Sommeil", sfSymbol: "moon.fill", tint: .pulseSleep,
                heroValue: "—", heroUnit: "", spark: [], delta: nil,
                footNote: "aucune nuit mesurée", flag: nil
            )
        }

        let totalMinutes = Int((sleepDebt.avgHours * 60).rounded())
        let hero = "\(totalMinutes / 60):\(String(format: "%02d", totalMinutes % 60))"

        let deltaHours = weekDeltaHours
        let delta = dashboardDelta(
            magnitude: "\(Int((abs(deltaHours) * 60).rounded())) min",
            isPositive: deltaHours > 0,
            isZero: abs(deltaHours) < 0.05,
            goodWhenPositive: true // plus de sommeil que la cible = bonne nouvelle.
        )

        let debtPart = sleepDebt.debtHours > 0
            ? "dette −\(dashboardFormatHM(Int(sleepDebt.debtHours * 3600)))"
            : "à jour"
        let footNote = "\(debtPart) · \(sleepDebt.deficitNights) nuit\(sleepDebt.deficitNights > 1 ? "s" : "") < 6 h"

        let flag: DashboardDomainSummary.Flag = sleepDebt.deficitNights > 0
            ? .init(text: "\(sleepDebt.deficitNights) nuits déficitaires", level: .warn)
            : .init(text: dashboardDebtLevel(debtHours: sleepDebt.debtHours), level: .ok)

        return DashboardDomainSummary(
            title: "Sommeil", sfSymbol: "moon.fill", tint: .pulseSleep,
            heroValue: hero, heroUnit: "moy / nuit",
            spark: wellnessSleepHours.compactMap { $0 },
            delta: delta, footNote: footNote, flag: flag
        )
    }

    // MARK: Entraînement

    var trainingSummary: DashboardDomainSummary {
        guard let training else {
            return DashboardDomainSummary(
                title: "Entraînement", sfSymbol: "figure.run", tint: .pulseSteps,
                heroValue: "—", heroUnit: "", spark: [], delta: nil,
                footNote: "aucune séance mesurée", flag: nil
            )
        }

        let delta = training.deltaPct.map { pct in
            dashboardDelta(magnitude: "\(abs(pct)) %", isPositive: pct > 0, isZero: pct == 0, goodWhenPositive: true)
        }

        let weeksCount = training.weeks.count
        let durationPerWeekS = weeksCount > 0 ? training.totalS / Double(weeksCount) : 0
        let anyOverload = training.weeks.contains { $0.overload }
        let footNote = "charge\(anyOverload ? " ↑" : "") · \(dashboardFormatHM(Int(durationPerWeekS)))/sem"

        let flag: DashboardDomainSummary.Flag = anyOverload
            ? .init(text: "surcharge récente", level: .warn)
            : .init(text: "régulier", level: .ok)

        return DashboardDomainSummary(
            title: "Entraînement", sfSymbol: "figure.run", tint: .pulseSteps,
            heroValue: String(format: "%.1f", training.perWeek), heroUnit: "séances / sem",
            spark: training.weeks.map { Double($0.load) },
            delta: delta, footNote: footNote, flag: flag
        )
    }

    // MARK: Santé

    var healthSummary: DashboardDomainSummary {
        guard let health, let restingHr = health.restingHr else {
            return DashboardDomainSummary(
                title: "Santé", sfSymbol: "heart.fill", tint: .pulseHR,
                heroValue: "—", heroUnit: "", spark: [], delta: nil,
                footNote: "aucune mesure sur la période", flag: nil
            )
        }

        let delta = health.restingDelta.map { d in
            dashboardDelta(
                magnitude: "\(abs(Int(d.rounded()))) bpm",
                isPositive: d > 0, isZero: Int(d.rounded()) == 0,
                goodWhenPositive: false // FC de repos qui baisse = bonne nouvelle.
            )
        }

        let spo2Part = health.spo2Night.map { "SpO2 \(Int($0.rounded())) %" } ?? "SpO2 —"
        let weightPart: String
        if let weightKg = health.weightKg {
            let deltaPart = health.weightDelta.map { " (\($0 > 0 ? "+" : "")\(String(format: "%.1f", $0)))" } ?? ""
            weightPart = "poids \(String(format: "%.1f", weightKg)) kg\(deltaPart)"
        } else {
            weightPart = "poids —"
        }

        let flag: DashboardDomainSummary.Flag = {
            if let spo2 = health.spo2Night, spo2 < 90 {
                return .init(text: "SpO2 basse", level: .bad)
            }
            return .init(text: "stable", level: .ok)
        }()

        return DashboardDomainSummary(
            title: "Santé", sfSymbol: "heart.fill", tint: .pulseHR,
            heroValue: "\(Int(restingHr.rounded()))", heroUnit: "bpm · FC repos",
            spark: health.restingSeries.map(\.value),
            delta: delta, footNote: "\(spo2Part) · \(weightPart)", flag: flag
        )
    }

    // MARK: Nutrition

    var nutritionSummary: DashboardDomainSummary {
        guard let nutrition, let kcalPerDay = nutrition.kcalPerDay else {
            return DashboardDomainSummary(
                title: "Nutrition", sfSymbol: "fork.knife", tint: .pulseCalories,
                heroValue: "—", heroUnit: "", spark: [], delta: nil,
                footNote: "aucune saisie sur la période", flag: nil
            )
        }

        let heroValue = dashboardThousandsFormatter.string(from: NSNumber(value: kcalPerDay)) ?? "\(kcalPerDay)"

        let delta = nutrition.balance.map { balance in
            dashboardDelta(
                magnitude: "\(abs(balance)) kcal/j",
                isPositive: balance > 0, isZero: balance == 0,
                goodWhenPositive: false // déficit (négatif) = bonne nouvelle ici.
            )
        }

        // "X/Y j saisis" : journées complètes sur journées saisies (et non
        // "saisies sur total période", réservé au flag ci-dessous) — cohérent
        // avec `DashboardNutritionEmptyCard` qui distingue déjà les deux.
        let footNote = "\(nutrition.completeDays)/\(nutrition.daysLogged) j saisis · \(nutrition.proteinPerDay ?? 0) g prot."

        let unloggedDays = max(nutrition.days - nutrition.daysLogged, 0)
        // Seuil de « notable » non prescrit par le produit : 2 jours pris
        // arbitrairement pour éviter une alerte sur un oubli isolé.
        let flag: DashboardDomainSummary.Flag = unloggedDays > 2
            ? .init(text: "\(unloggedDays) jours non saisis", level: .warn)
            : .init(text: "suivi à jour", level: .ok)

        return DashboardDomainSummary(
            title: "Nutrition", sfSymbol: "fork.knife", tint: .pulseCalories,
            heroValue: heroValue, heroUnit: "kcal / j",
            spark: nutrition.series.compactMap { $0.kcal.map(Double.init) },
            delta: delta, footNote: footNote, flag: flag
        )
    }
}
