//
//  BodyBattery.swift
//  all (bridge-connect)
//
//  Portage Swift de `custom-connect/server/src/wellness/body-battery.ts` —
//  simulateur physiologique du pivot d'énergie corporelle (« body battery »),
//  utilisé par `LocalDb.pivotSeries`/`bodyBatteryStart` pour servir
//  `bodyBatteryPivot` dans `GET api/wellness/day/:date` (incrément L2, cf.
//  `docs/stockage-local.md`). Port ligne à ligne des fonctions pures
//  (`mealRechargeRate`, `levelScale`, `activityStress`, `simulateBodyBatteryPivot`)
//  — seule `timeline` est spécialisée : côté TS elle prend une fabrique de
//  valeur d'activité en paramètre, mais `simulateBodyBatteryPivot` ne
//  l'appelle jamais qu'avec UNE fabrique (`activityStress`), donc portée
//  directement inline ici plutôt que généralisée pour rien.
//
//  `activityDrain` (TS) n'est utilisée nulle part ailleurs dans le serveur —
//  code mort dans la source d'origine, non porté.
//
//  Activités et repas : en L2, `activities`/`food_log` n'existent pas encore
//  dans `LocalDb` (respectivement L3+ et Nutrition/L5+) — `LocalDb.pivotSeries`
//  appelle toujours `simulatePivot` avec `activities: []`/`meals: []`. Le
//  code ci-dessous reste générique (accepte les deux) pour ne pas avoir à
//  reporter cette logique le jour où ces tables arrivent — mais n'a été
//  exercé, en pratique, qu'avec ces deux paramètres vides (cf. rapport
//  d'incrément : pas de cas de test avec activités/repas non vides).
//

import Foundation

/// Point `{ts, value}` — mesure (FC/stress/SpO2/respiration) OU pivot simulé.
/// `ts` en secondes epoch (déjà décalées au fuseau d'affichage par
/// l'appelant, cf. `LocalDb.samplesBetween`).
struct LocalSample: Equatable {
    let ts: Double
    let value: Double
}

struct BBSleepInterval {
    let from: Double
    let to: Double
}

struct BBActivityLoad {
    let from: Double
    let to: Double
    let avgHr: Double?
}

struct BBMealEnergy {
    let ts: Double
    let kcal: Double
}

struct BBPivotParams {
    var k: Double
    var pivot: Double
    var sleepBoost: Double
    var start: Double
    var maxStepMin: Double
}

enum BodyBattery {
    /// `DEFAULT_PIVOT_PARAMS` (TS).
    static let defaultParams = BBPivotParams(k: 0.004, pivot: 27.2, sleepBoost: 2.5, start: 50, maxStepMin: 10)

    /// Miroir de `mealRechargeRate` (TS).
    static func mealRechargeRate(ts: Double, meals: [BBMealEnergy]) -> Double {
        var rate = 0.0
        for m in meals {
            guard m.kcal > 0 else { continue }
            let tauMin = (ts - m.ts) / 60
            guard tauMin >= 0 else { continue }
            let windowMin = min(max(90 + (m.kcal / 400) * 60, 90), 240)
            guard tauMin <= windowMin else { continue }
            let peak = 0.3 * windowMin
            let shape = tauMin <= peak ? tauMin / peak : (windowMin - tauMin) / (windowMin - peak)
            let total = m.kcal / 120
            rate += shape * ((2 * total) / windowMin)
        }
        return rate
    }

    /// Miroir de `levelScale` (TS).
    static func levelScale(bb: Double, charging: Bool) -> Double {
        let headroom = charging ? 100 - bb : bb
        return (2 * min(max(headroom, 0), 100)) / 100
    }

    /// Miroir de `activityStress` (TS).
    static func activityStress(_ avgHr: Double?) -> Double {
        guard let avgHr, avgHr > 0 else { return 75 }
        let frac = min(max((avgHr - 100) / 70, 0), 1)
        return (55 + frac * 40).rounded()
    }

    private struct Point {
        let ts: Double
        let stress: Double?
    }

    /// Miroir spécialisé de `timeline` (TS) — cf. en-tête de fichier.
    private static func timeline(stress: [LocalSample], activities: [BBActivityLoad]) -> [Point] {
        func inActivity(_ ts: Double) -> Bool {
            activities.contains { ts >= $0.from && ts < $0.to }
        }
        var points: [Point] = []
        for s in stress where !inActivity(s.ts) {
            points.append(Point(ts: s.ts, stress: s.value))
        }
        for a in activities {
            let stressValue = activityStress(a.avgHr)
            var t = a.from
            while t < a.to {
                points.append(Point(ts: t, stress: stressValue))
                t += 60
            }
            points.append(Point(ts: a.to, stress: stressValue))
        }
        points.sort { $0.ts < $1.ts }
        return points
    }

    /// Miroir de `simulateBodyBatteryPivot` (TS) — même intégration pas à
    /// pas (delta de temps borné par `maxStepMin`), même ordre d'opérations
    /// (charge de repas, boost sommeil, mise à l'échelle par la marge
    /// restante avant d'intégrer).
    static func simulatePivot(
        stress: [LocalSample],
        sleep: [BBSleepInterval] = [],
        activities: [BBActivityLoad] = [],
        params: BBPivotParams = defaultParams,
        meals: [BBMealEnergy] = []
    ) -> [LocalSample] {
        let points = timeline(stress: stress, activities: activities)
        func asleepAt(_ ts: Double) -> Bool {
            sleep.contains { ts >= $0.from && ts < $0.to }
        }
        var bb = params.start
        var prevTs: Double?
        var out: [LocalSample] = []
        for p in points {
            let dtMin: Double
            if let prev = prevTs {
                dtMin = min(max((p.ts - prev) / 60, 0), params.maxStepMin)
            } else {
                dtMin = 1
            }
            prevTs = p.ts
            let s = min(max(p.stress ?? 0, 0), 100)
            var rate = params.k * (params.pivot - s)
            if rate > 0 && asleepAt(p.ts) { rate *= params.sleepBoost }
            rate += mealRechargeRate(ts: p.ts, meals: meals)
            rate *= levelScale(bb: bb, charging: rate > 0)
            bb = min(100, max(0, bb + rate * dtMin))
            out.append(LocalSample(ts: p.ts, value: bb.rounded()))
        }
        return out
    }
}
