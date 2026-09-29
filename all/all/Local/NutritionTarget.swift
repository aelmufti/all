//
//  NutritionTarget.swift
//  all (bridge-connect)
//
//  Portage Swift du moteur d'objectif nutritionnel —
//  `custom-connect/server/src/nutrition/target.ts` (incrément
//  L5-Nutrition-analytics, cf. `docs/stockage-local.md`). Câblé depuis
//  `RealLocalPulseBackend` (routes `nutrition/targets`, `nutrition/weekly`,
//  `nutrition/timing/:date`, `nutrition/suggestions/:date`, et les champs
//  `targets`/`remaining`/`targetRanges` de `nutrition/day/:date`), qui
//  remplace les STUBS neutres de l'incrément L5-Nutrition précédent.
//
//  Portée : `basalMetabolicRate`, `fatFreeMassKg`, `ageOn`, `dailyDeficitFor`,
//  `missingProfileFields`, `isResistanceSession`, `computeMacros`,
//  `computeDayTarget`, `computeWeekly`, `isCompleteDay`,
//  `DEFAULT_TARGET_SETTINGS`, `clampSetting` — même constantes, mêmes
//  arrondis, mêmes gardes que le TS.
//
//  NON porté (décision assumée de cet incrément) : le moteur « programme »
//  (`programmePlan`/`declaredBounds`/`MacroConstraints`/`ProgrammeBound` côté
//  TS) — `RealLocalPulseBackend` n'a pas de table `programme_state` locale et
//  n'appelle donc JAMAIS `computeMacros`/`computeDayTarget` avec des
//  contraintes non-`nil` : le paramètre `constraints` de `computeMacros` côté
//  TS est donc simplement absent ici (toujours équivalent à `null`), et les
//  branches qui en dépendent (bornes de `computeMacros`, `macros.programme`,
//  `programmeFor`) sont mortes par construction plutôt que portées puis
//  jamais exercées. `targetRanges`/`programme` de `day/:date` retombent donc
//  TOUJOURS sur `manualRanges()`/`nil`, jamais un cadre de programme — cf.
//  section dédiée de `RealLocalPulseBackend`.
//
//  Champs de `MacroPlan` gardés (`bonuses`, `proteinPerMealG`,
//  `proteinIntakes`, `fatFloorG`, `fatFromFloor`, `fatCutForCarbs`,
//  `carbsFloorG`, `carbsBelowFloor`, `shares`) : calculés fidèlement (la
//  formule les produit "gratuitement") mais NON encodés côté JSON — mêmes
//  champs déjà explicitement omis du modèle `NutritionMacroPlan` côté écran,
//  cf. l'en-tête de `Pulse/Screens/Nutrition/NutritionModels.swift` (« détail
//  de calcul de l'objectif… non consommés par cet écran »).
//

import Foundation

// MARK: - Types d'entrée (miroir `TargetProfile`/`TargetSettings`/`DaySession`/`WatchDay`)

struct NutritionEngineProfile {
    let birthYear: Int?
    /// `"male"` | `"female"` | `nil`.
    let sex: String?
    let weightKg: Double?
    let heightCm: Double?
}

enum NutritionEngineSettingKey: String {
    case weeklyLossPct, deficitKcal, sportFactor, proteinPerKg, floorKcal, weeklyAlertKcal
}

struct NutritionEngineSettings {
    var weeklyLossPct: Double
    var deficitKcal: Double
    var sportFactor: Double
    var proteinPerKg: Double
    var floorKcal: Double
    var weeklyAlertKcal: Double

    /// Miroir de `DEFAULT_TARGET_SETTINGS` (TS).
    static let defaults = NutritionEngineSettings(
        weeklyLossPct: 0.7, deficitKcal: 500, sportFactor: 1, proteinPerKg: 1.9,
        floorKcal: 1500, weeklyAlertKcal: 600)
}

struct NutritionEngineSession {
    let sport: String?
    let subSport: String?
    let durationS: Double?
    let calories: Double?
}

struct NutritionEngineWatchDay {
    let restingKcal: Double?
    let activeKcal: Double?
}

// MARK: - Types de sortie (miroir `MacroPlan`/`TargetResult`)

struct NutritionEngineSessionBreakdown {
    let sport: String?
    let durationS: Double
    let rawKcal: Double
}

struct NutritionEngineProteinBonus {
    /// `"deficit"` | `"strength"` | `"endurance"` | `"age"`.
    let key: String
    let perKg: Double
}

struct NutritionEngineMacroShares {
    let protein: Double
    let fat: Double
    let carbs: Double
}

/// Miroir de `MacroPlan` (TS) — SANS le champ `programme` (moteur programme
/// non porté, cf. en-tête de fichier) : toujours implicitement `nil` côté
/// appelant.
struct NutritionEngineMacroPlan {
    var proteinG: Double?
    var fatG: Double?
    var carbsG: Double?
    var fiberG: Double?
    var proteinPerKg: Double?
    var basePerKg: Double
    var bonuses: [NutritionEngineProteinBonus] = []
    var proteinCapped: Bool = false
    var proteinCutFloor: Bool = false
    var proteinPerMealMinG: Double?
    var proteinPerMealMaxG: Double?
    var proteinIntakes: Double?
    var fatFloorG: Double?
    var fatFromFloor: Bool = false
    var fatCutForCarbs: Bool = false
    var carbsFloorG: Double?
    var carbsBelowFloor: Bool = false
    var shares: NutritionEngineMacroShares?
}

struct NutritionEngineTargetDetail {
    let restingKcal: Double?
    let watchActiveKcal: Double?
    let sessionKcal: Double
    let activeKcal: Double?
    let sessions: [NutritionEngineSessionBreakdown]
}

/// Miroir de `TargetResult` (TS).
struct NutritionEngineTargetResult {
    /// `"ok"` | `"unavailable"`.
    let status: String
    /// `"watch"` | `"watch-sessions"` | `"formula"`.
    let source: String
    let missing: [String]
    let targetKcal: Double?
    let expenditureKcal: Double?
    let deficitKcal: Double?
    let plannedDeficitKcal: Double?
    let deficitFromRate: Bool
    let weeklyLossKg: Double?
    let fatFreeMassKg: Double?
    let availabilityFloorKcal: Double?
    let energyAvailability: Double?
    let proteinG: Double?
    let macros: NutritionEngineMacroPlan
    /// `"none"` | `"availability"` | `"resting"` | `"absolute"`.
    let guardStatus: String
    let detail: NutritionEngineTargetDetail
}

// MARK: - Moyenne 7 j (miroir `WeeklyDay`/`WeeklyResult`/`isCompleteDay`/`computeWeekly`)

struct NutritionEngineWeeklyDay {
    let date: String
    let intakeKcal: Double?
    let expenditureKcal: Double?
    let targetKcal: Double?
    let balanceKcal: Double?
}

struct NutritionEngineWeeklyResult {
    let days: [NutritionEngineWeeklyDay]
    let loggedDays: Int
    let partialDays: Int
    let emptyDays: Int
    let avgDeficitKcal: Double?
    let avgIntakeKcal: Double?
    let avgExpenditureKcal: Double?
    let alert: Bool
    let thresholdKcal: Double
}

// MARK: - Moteur (fonctions pures, miroir `target.ts`)

enum NutritionTargetEngine {
    private static let SEDENTARY_FACTOR = 1.2
    private static let KCAL_PER_KG_BW = 7700.0
    private static let AVAILABILITY_MALE = 25.0
    private static let AVAILABILITY_FEMALE = 30.0
    private static let RESTING_FLOOR_FACTOR = 1.1
    private static let MINUTES_PER_DAY = 1440.0
    private static let COMPLETE_RATIO = 0.6
    private static let FALLBACK_COMPLETE_KCAL = 1200.0

    private static let PROTEIN_MAX_PER_KG = 2.6
    private static let PROTEIN_CUT_MIN_PER_KG = 2.2
    private static let PROTEIN_MEAL_MIN_PER_KG = 0.4
    private static let PROTEIN_MEAL_MAX_PER_KG = 0.55
    private static let PROTEIN_INTAKES_MIN = 3.0
    private static let PROTEIN_INTAKES_MAX = 6.0
    private static let PROTEIN_MAX_SHARE = 0.45
    private static let PROTEIN_DEFICIT_BONUS = 0.3
    private static let DEFICIT_FULL_RATIO = 0.25
    private static let PROTEIN_STRENGTH_BONUS = 0.2
    private static let PROTEIN_ENDURANCE_BONUS = 0.1
    private static let ENDURANCE_MINUTES = 60.0
    private static let PROTEIN_AGE_BONUS = 0.1
    private static let AGE_THRESHOLD = 60.0

    private static let FAT_SHARE = 0.27
    private static let FAT_FLOOR_PER_KG = 0.8
    private static let FAT_HARD_FLOOR_PER_KG = 0.5
    private static let FAT_MAX_PER_KG = 1.0
    private static let FAT_MAX_SHARE = 0.3
    private static let CARBS_FLOOR_PER_KG = 2.0

    private static let FIBER_PER_1000_KCAL = 14.0
    private static let FIBER_MIN = 20.0
    private static let FIBER_MAX = 50.0

    private static let RESISTANCE_SPORTS: Set<String> = ["training", "rockClimbing", "floorClimbing"]
    private static let RESISTANCE_SUB_SPORTS: Set<String> = ["strengthTraining"]

    private static func round(_ v: Double) -> Double { v.rounded() }
    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    static func ageOn(date: String, birthYear: Int) -> Int {
        (Int(date.prefix(4)) ?? 0) - birthYear
    }

    static func basalMetabolicRate(profile: NutritionEngineProfile, ageYears: Double) -> Double? {
        guard let sex = profile.sex, let weightKg = profile.weightKg, let heightCm = profile.heightCm else { return nil }
        guard ageYears.isFinite else { return nil }
        let base = 10 * weightKg + 6.25 * heightCm - 5 * ageYears
        return sex == "male" ? base + 5 : base - 161
    }

    static func fatFreeMassKg(profile: NutritionEngineProfile, ageYears: Double?) -> Double? {
        guard let sex = profile.sex, let weightKg = profile.weightKg, let heightCm = profile.heightCm, let ageYears
        else { return nil }
        guard weightKg > 0, heightCm > 0 else { return nil }
        let bmi = weightKg / pow(heightCm / 100, 2)
        let bodyFatPct = clamp(1.2 * bmi + 0.23 * ageYears - 10.8 * (sex == "male" ? 1 : 0) - 5.4, 5, 60)
        return round2(weightKg * (1 - bodyFatPct / 100))
    }

    static func dailyDeficitFor(settings: NutritionEngineSettings, weightKg: Double?) -> (kcal: Double, fromRate: Bool) {
        guard let weightKg, weightKg > 0, settings.weeklyLossPct > 0 else {
            return (settings.deficitKcal, false)
        }
        let weeklyKcal = weightKg * (settings.weeklyLossPct / 100) * KCAL_PER_KG_BW
        return (round(weeklyKcal / 7), true)
    }

    static func missingProfileFields(_ profile: NutritionEngineProfile) -> [String] {
        var missing: [String] = []
        if profile.birthYear == nil { missing.append("birthYear") }
        if profile.sex == nil { missing.append("sex") }
        if profile.weightKg == nil { missing.append("weightKg") }
        if profile.heightCm == nil { missing.append("heightCm") }
        return missing
    }

    static func isResistanceSession(_ session: NutritionEngineSession) -> Bool {
        if let subSport = session.subSport, RESISTANCE_SUB_SPORTS.contains(subSport) { return true }
        if let sport = session.sport { return RESISTANCE_SPORTS.contains(sport) }
        return false
    }

    /// Miroir de `EMPTY_MACROS` (TS, constante — `fiberG`/`basePerKg` toujours
    /// au repli par défaut, jamais calculés) : utilisé UNIQUEMENT par
    /// `unavailable()` (calcul totalement impossible), à distinguer de `base`
    /// dans `computeMacros` (où `fiberG` EST calculé depuis `targetKcal`).
    private static var emptyMacros: NutritionEngineMacroPlan {
        NutritionEngineMacroPlan(
            proteinG: nil, fatG: nil, carbsG: nil, fiberG: nil, proteinPerKg: nil,
            basePerKg: NutritionEngineSettings.defaults.proteinPerKg)
    }

    /// Miroir de `computeMacros` (TS). `constraints` (bornes de programme)
    /// n'est PAS un paramètre ici : toujours `null` côté appelant réel (cf.
    /// en-tête de fichier), donc les branches qui en dépendent (clamp de
    /// `fiberG`/`proteinPerKg`/`carbsG` sur les bornes du programme) sont
    /// omises plutôt que portées mortes.
    static func computeMacros(
        targetKcal: Double, deficitKcal: Double, expenditureKcal: Double,
        weightKg: Double?, ageYears: Double?, sessions: [NutritionEngineSession], settings: NutritionEngineSettings
    ) -> NutritionEngineMacroPlan {
        let fiberG = round(clamp(targetKcal / 1000 * FIBER_PER_1000_KCAL, FIBER_MIN, FIBER_MAX))
        var base = emptyMacros
        base.fiberG = fiberG
        base.basePerKg = settings.proteinPerKg
        guard let weightKg, weightKg > 0, targetKcal > 0 else { return base }

        var bonuses: [NutritionEngineProteinBonus] = []
        let deficitRatio = expenditureKcal > 0 ? max(deficitKcal, 0) / expenditureKcal : 0
        let deficitBonus = round2(PROTEIN_DEFICIT_BONUS * clamp(deficitRatio / DEFICIT_FULL_RATIO, 0, 1))
        if deficitBonus > 0 { bonuses.append(.init(key: "deficit", perKg: deficitBonus)) }
        if sessions.contains(where: isResistanceSession) {
            bonuses.append(.init(key: "strength", perKg: PROTEIN_STRENGTH_BONUS))
        }
        let sessionMinutes = sessions.reduce(0.0) { $0 + ($1.durationS ?? 0) } / 60
        if sessionMinutes >= ENDURANCE_MINUTES { bonuses.append(.init(key: "endurance", perKg: PROTEIN_ENDURANCE_BONUS)) }
        if let ageYears, ageYears >= AGE_THRESHOLD { bonuses.append(.init(key: "age", perKg: PROTEIN_AGE_BONUS)) }

        let inDeficit = deficitKcal > 0
        let asked = settings.proteinPerKg + bonuses.reduce(0.0) { $0 + $1.perKg }
        let lifted = inDeficit ? max(asked, PROTEIN_CUT_MIN_PER_KG) : asked
        let proteinCutFloor = inDeficit && lifted > asked
        let wanted = min(lifted, PROTEIN_MAX_PER_KG)
        let proteinCap = (targetKcal * PROTEIN_MAX_SHARE / 4).rounded(.down)
        let wantedG = round(weightKg * wanted)
        let proteinCapped = wantedG > proteinCap
        let proteinG = min(wantedG, proteinCap)

        let fatFloorG = round(weightKg * FAT_FLOOR_PER_KG)
        let fatHardFloorG = round(weightKg * FAT_HARD_FLOOR_PER_KG)
        let fatShareG = round(targetKcal * FAT_SHARE / 9)
        let fatMaxG = min((targetKcal * FAT_MAX_SHARE / 9).rounded(.down), (weightKg * FAT_MAX_PER_KG).rounded(.down))
        var fatG = min(max(fatFloorG, fatShareG), fatMaxG)
        let fatFromFloor = fatG > fatShareG

        let carbsFloorG = round(weightKg * CARBS_FLOOR_PER_KG)
        func remaining() -> Double { max(round((targetKcal - proteinG * 4 - fatG * 9) / 4), 0) }
        var fatCutForCarbs = false
        if remaining() < carbsFloorG, fatG > fatHardFloorG {
            let spare = ((carbsFloorG - remaining()) * 4 / 9).rounded(.up)
            let reduced = max(fatG - spare, fatHardFloorG)
            fatCutForCarbs = reduced < fatG
            fatG = reduced
        }
        let carbsG = remaining()
        let carbsBelowFloor = carbsG < carbsFloorG

        let proteinPerMealMax = weightKg * PROTEIN_MEAL_MAX_PER_KG
        return NutritionEngineMacroPlan(
            proteinG: proteinG, fatG: fatG, carbsG: carbsG, fiberG: fiberG,
            proteinPerKg: proteinCapped ? round2(proteinG / weightKg) : round2(wanted),
            basePerKg: settings.proteinPerKg, bonuses: bonuses,
            proteinCapped: proteinCapped, proteinCutFloor: proteinCutFloor,
            proteinPerMealMinG: round(weightKg * PROTEIN_MEAL_MIN_PER_KG),
            proteinPerMealMaxG: round(proteinPerMealMax),
            proteinIntakes: proteinPerMealMax > 0
                ? clamp((proteinG / proteinPerMealMax).rounded(), PROTEIN_INTAKES_MIN, PROTEIN_INTAKES_MAX)
                : PROTEIN_INTAKES_MIN,
            fatFloorG: fatFloorG, fatFromFloor: fatFromFloor, fatCutForCarbs: fatCutForCarbs,
            carbsFloorG: carbsFloorG, carbsBelowFloor: carbsBelowFloor,
            shares: .init(
                protein: round2(proteinG * 4 / targetKcal), fat: round2(fatG * 9 / targetKcal),
                carbs: round2(carbsG * 4 / targetKcal)))
    }

    /// Miroir de `unavailable()` (TS, privée) — profil incomplet ou aucun
    /// repli montre : AUCUNE cible, `macros` neutre.
    private static func unavailable(missing: [String], sessions: [NutritionEngineSession]) -> NutritionEngineTargetResult {
        let sessionKcal = sessions.reduce(0.0) { $0 + ($1.calories ?? 0) }
        return NutritionEngineTargetResult(
            status: "unavailable", source: "formula", missing: missing,
            targetKcal: nil, expenditureKcal: nil, deficitKcal: nil, plannedDeficitKcal: nil, deficitFromRate: false,
            weeklyLossKg: nil, fatFreeMassKg: nil, availabilityFloorKcal: nil, energyAvailability: nil, proteinG: nil,
            macros: emptyMacros, guardStatus: "none",
            detail: .init(restingKcal: nil, watchActiveKcal: nil, sessionKcal: round(sessionKcal), activeKcal: nil, sessions: []))
    }

    /// Miroir de `computeDayTarget` (TS). `constraints` omis (cf. en-tête de
    /// fichier) : `macros.programme` reste toujours `nil` côté DTO
    /// d'encodage, jamais calculé ici.
    static func computeDayTarget(
        date: String, profile: NutritionEngineProfile, watch: NutritionEngineWatchDay,
        sessions: [NutritionEngineSession], settings: NutritionEngineSettings
    ) -> NutritionEngineTargetResult {
        let ageYears: Double? = profile.birthYear.map { Double(ageOn(date: date, birthYear: $0)) }
        let formulaBmr: Double? = ageYears.flatMap { basalMetabolicRate(profile: profile, ageYears: $0) }

        // Miroir de `fromWatch` (TS) — repos venant de la montre, PAS calculé
        // depuis le profil (indépendant de `formulaBmr`).
        let watchRestingOk = (watch.restingKcal != nil) && watch.restingKcal! > 0
        if !watchRestingOk && formulaBmr == nil {
            return unavailable(missing: missingProfileFields(profile), sessions: sessions)
        }

        let restingBasis = watchRestingOk ? watch.restingKcal! : formulaBmr!
        let resting = watchRestingOk ? restingBasis : restingBasis * SEDENTARY_FACTOR
        let restingPerMinute = restingBasis / MINUTES_PER_DAY

        var breakdown: [NutritionEngineSessionBreakdown] = []
        var sessionKcal = 0.0
        var sessionActive = 0.0
        for session in sessions {
            let rawKcal = session.calories ?? 0
            if rawKcal <= 0 { continue }
            let durationS = session.durationS ?? 0
            let restingShare = min(restingPerMinute * (durationS / 60), rawKcal)
            sessionKcal += rawKcal
            sessionActive += rawKcal - restingShare
            breakdown.append(.init(sport: session.sport, durationS: durationS, rawKcal: round(rawKcal)))
        }

        let watchActive = watch.activeKcal
        let active = max(watchActive ?? 0, sessionActive)
        let source: String
        if !watchRestingOk {
            source = "formula"
        } else if let watchActive, watchActive >= sessionActive {
            source = "watch"
        } else {
            source = "watch-sessions"
        }

        let adjustedActive = active * settings.sportFactor
        let expenditure = resting + adjustedActive

        let deficit = dailyDeficitFor(settings: settings, weightKg: profile.weightKg)
        let ffmKg = fatFreeMassKg(profile: profile, ageYears: ageYears)
        let availabilityFloor: Double? = ffmKg.map {
            $0 * (profile.sex == "female" ? AVAILABILITY_FEMALE : AVAILABILITY_MALE) + adjustedActive
        }

        var guardStatus = "none"
        var target = expenditure - deficit.kcal
        if let availabilityFloor {
            if target < availabilityFloor {
                target = availabilityFloor
                guardStatus = "availability"
            }
        } else {
            let restingFloor = restingBasis * RESTING_FLOOR_FACTOR
            if target < restingFloor {
                target = restingFloor
                guardStatus = "resting"
            }
        }
        if target < settings.floorKcal {
            target = settings.floorKcal
            guardStatus = "absolute"
        }
        if target > expenditure {
            target = expenditure
        }

        let targetKcal = round(target)
        let expenditureKcal = round(expenditure)
        let deficitKcal = expenditureKcal - targetKcal
        let macros = computeMacros(
            targetKcal: targetKcal, deficitKcal: deficitKcal, expenditureKcal: expenditureKcal,
            weightKg: profile.weightKg, ageYears: ageYears, sessions: sessions, settings: settings)

        return NutritionEngineTargetResult(
            status: "ok", source: source, missing: profile.weightKg == nil ? ["weightKg"] : [],
            targetKcal: targetKcal, expenditureKcal: expenditureKcal, deficitKcal: deficitKcal,
            plannedDeficitKcal: round(deficit.kcal), deficitFromRate: deficit.fromRate,
            weeklyLossKg: round2(deficitKcal * 7 / KCAL_PER_KG_BW),
            fatFreeMassKg: ffmKg,
            availabilityFloorKcal: availabilityFloor.map(round),
            energyAvailability: (ffmKg != nil && ffmKg! > 0) ? round2((targetKcal - adjustedActive) / ffmKg!) : nil,
            proteinG: macros.proteinG, macros: macros, guardStatus: guardStatus,
            detail: .init(
                restingKcal: round(resting), watchActiveKcal: watchActive.map(round),
                sessionKcal: round(sessionKcal), activeKcal: round(adjustedActive), sessions: breakdown))
    }

    /// Miroir de `isCompleteDay` (TS).
    static func isCompleteDay(_ day: NutritionEngineWeeklyDay) -> Bool {
        guard let intakeKcal = day.intakeKcal, day.expenditureKcal != nil else { return false }
        let floor = day.targetKcal.map { $0 * COMPLETE_RATIO } ?? FALLBACK_COMPLETE_KCAL
        return intakeKcal >= floor
    }

    /// Miroir de `computeWeekly` (TS).
    static func computeWeekly(_ days: [NutritionEngineWeeklyDay], settings: NutritionEngineSettings) -> NutritionEngineWeeklyResult {
        let logged = days.filter(isCompleteDay)
        let partial = days.filter { $0.intakeKcal != nil && !isCompleteDay($0) }
        let empty = days.filter { $0.intakeKcal == nil }
        guard !logged.isEmpty else {
            return NutritionEngineWeeklyResult(
                days: days, loggedDays: 0, partialDays: partial.count, emptyDays: empty.count,
                avgDeficitKcal: nil, avgIntakeKcal: nil, avgExpenditureKcal: nil, alert: false,
                thresholdKcal: settings.weeklyAlertKcal)
        }
        let avgIntake = logged.reduce(0.0) { $0 + $1.intakeKcal! } / Double(logged.count)
        let avgExpenditure = logged.reduce(0.0) { $0 + $1.expenditureKcal! } / Double(logged.count)
        let avgDeficit = avgExpenditure - avgIntake
        return NutritionEngineWeeklyResult(
            days: days, loggedDays: logged.count, partialDays: partial.count, emptyDays: empty.count,
            avgDeficitKcal: round(avgDeficit), avgIntakeKcal: round(avgIntake), avgExpenditureKcal: round(avgExpenditure),
            alert: avgDeficit > settings.weeklyAlertKcal, thresholdKcal: settings.weeklyAlertKcal)
    }

    /// Miroir de `clampSetting` (TS).
    static func clampSetting(_ key: NutritionEngineSettingKey, _ value: Double) -> Double? {
        let ranges: [NutritionEngineSettingKey: (Double, Double)] = [
            .weeklyLossPct: (0, 1.5), .deficitKcal: (0, 1500), .sportFactor: (0.2, 1.5),
            .proteinPerKg: (0.5, 4), .floorKcal: (800, 4000), .weeklyAlertKcal: (100, 2000),
        ]
        guard let (lo, hi) = ranges[key], value.isFinite, value >= lo, value <= hi else { return nil }
        switch key {
        case .sportFactor, .proteinPerKg, .weeklyLossPct:
            return (value * 100).rounded() / 100
        default:
            return round(value)
        }
    }
}
