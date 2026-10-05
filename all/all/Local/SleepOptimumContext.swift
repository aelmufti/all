//
//  SleepOptimumContext.swift
//  all (bridge-connect)
//
//  Couche CONTEXTUELLE de la durée idéale (v1.2, cf. `docs/duree-ideale-sommeil.md`
//  §10 ; portée côté serveur dans `custom-connect/server/src/stats/
//  sleep-optimum-context.ts`, parité vérifiée par la fixture dorée
//  `allTests/Fixtures/sleep-optimum-context.golden.json`). Le modèle global
//  (`SleepOptimumModel.fit`, p = 21) donne UNE durée idéale : ses covariables
//  sont additives, elles ne déplacent pas l'optimum. Ici on ajoute, par-dessus
//  et sans le modifier, un second ajustement p = 25 dont 4 colonnes
//  d'INTERACTION `z_j · (clamp(S, 5, 9.5) − 7.5)` : le contexte connu AVANT le
//  coucher (énergie au coucher, stress de la veille, sport récent, sommeil des
//  nuits précédentes) peut alors déplacer la durée idéale de CETTE nuit.
//
//  Tout ce fichier est PUR (aucune E/S) : les échantillons nécessaires au calcul
//  d'une nuit À VENIR sont requêtés par `DashboardStatsBackend`
//  (`Local/DashboardStats.swift`) et passés ici.
//

import Foundation

enum SleepOptimumContext {
    // MARK: - Constantes (a priori, garde-fous)

    /// Covariables d'interaction, par leur rang dans les 7 covariables de la
    /// spec §4 : `bbBed` (0), `stressPrevDay` (1), `sportPrev` (2), `priorSleep`
    /// (6) — les seules connues AVANT le coucher.
    static let interactionIndices = [0, 1, 2, 6]
    static let interactionCount = interactionIndices.count
    /// `p = 21 + 4`.
    static let p = SleepOptimumModel.p + interactionCount
    /// A priori des 4 coefficients d'interaction γ : moyenne 0, écart-type 0,15
    /// (précision 1/0,15²) — assez serré pour qu'un contexte n'écrase pas la
    /// courbe sans données, assez lâche pour la déplacer quand elles parlent.
    static let gammaPriorSd = 0.15
    /// Sous ce nombre de nuits retenues, l'idéal de la nuit = idéal global.
    static let minNights = 30
    /// Écart maximal toléré à l'idéal brut global (heures), avant bornage
    /// [7 ; 9,5] puis arrondi à 5 min.
    static let maxDeviationHours = 1.0

    /// Variable d'interaction : `clamp(S, 5, 9.5) − 7.5` (heures).
    static func centeredHours(_ s: Double) -> Double {
        min(max(s, 5), 9.5) - 7.5
    }

    /// `Λ0` étendue : `Λ0` (p = 21) inchangée en bloc, puis diagonale
    /// `1/0,15²` pour les 4 γ.
    static let lambda0: [[Double]] = {
        let base = SleepOptimumModel.lambda0
        let n = SleepOptimumModel.p
        var m = Array(repeating: Array(repeating: 0.0, count: p), count: p)
        for i in 0..<n { for j in 0..<n { m[i][j] = base[i][j] } }
        for k in 0..<interactionCount { m[n + k][n + k] = 1.0 / (gammaPriorSd * gammaPriorSd) }
        return m
    }()

    /// `μ0` étendue : `μ0` inchangée, γ = 0.
    static let mu0: [Double] = SleepOptimumModel.mu0 + Array(repeating: 0.0, count: interactionCount)

    // MARK: - Covariables BRUTES d'une nuit (avant z-score)

    /// Les 4 covariables d'interaction, brutes ; `nil` = absente.
    struct Covariates: Equatable {
        var bbBed: Double?
        var stressPrevDay: Double?
        var sportPrev: Double?
        var priorSleep: Double?

        init(bbBed: Double? = nil, stressPrevDay: Double? = nil, sportPrev: Double? = nil, priorSleep: Double? = nil) {
            self.bbBed = bbBed
            self.stressPrevDay = stressPrevDay
            self.sportPrev = sportPrev
            self.priorSleep = priorSleep
        }

        init(night: SleepOptimumNightInput) {
            self.init(bbBed: night.bbBed, stressPrevDay: night.stressPrevDay,
                      sportPrev: night.sportPrev, priorSleep: night.priorSleep)
        }

        var allAbsent: Bool {
            bbBed == nil && stressPrevDay == nil && sportPrev == nil && priorSleep == nil
        }

        /// Dans l'ordre de `interactionIndices`.
        var values: [Double?] { [bbBed, stressPrevDay, sportPrev, priorSleep] }
    }

    // MARK: - Ajustement étendu

    struct Model {
        /// Nuits retenues du modèle étendu (= celles du modèle global).
        let n: Int
        let alpha: Double
        let d: [Double]
        let gamma: [Double]
        /// Moyenne/écart-type des 4 covariables d'interaction (mêmes que le
        /// z-score de `SleepOptimumFeatures.build`).
        let stats: [SleepOptimumFeatures.CovariateStat]
        /// Idéal brut / arrondi du modèle GLOBAL (repli et bornage).
        let globalIdealRaw: Double
        let globalIdealHours: Double
    }

    /// Ajuste le modèle p = 25 sur les mêmes nuits que le modèle global : mêmes
    /// 21 colonnes (déjà dans `built.X`) + 4 colonnes d'interaction
    /// `z_j · centeredHours(S)`, `z_j` étant la colonne z-scorée déjà présente
    /// dans `built.X` (indice `14 + rang`). Pas de tirages d'intervalle ici :
    /// seul `mn` sert.
    static func fit(built: SleepOptimumFeatures.Built, globalFit: SleepOptimumModel.Fit) -> Model {
        var X: [[Double]] = []
        X.reserveCapacity(built.X.count)
        for (row, night) in zip(built.X, built.nightsUsed) {
            let c = centeredHours(night.S)
            var ext = row
            for idx in interactionIndices { ext.append(row[14 + idx] * c) }
            X.append(ext)
        }
        let post = SleepOptimumModel.posterior(X: X, y: built.y, lambda0: lambda0, mu0: mu0)
        let base = SleepOptimumModel.p
        return Model(
            n: post.n, alpha: post.mn[1], d: Array(post.mn[2...13]),
            gamma: Array(post.mn[base..<(base + interactionCount)]),
            stats: interactionIndices.map { built.covariateStats[$0] },
            globalIdealRaw: globalFit.idealRaw, globalIdealHours: globalFit.idealHours)
    }

    // MARK: - Idéal d'une nuit

    /// 5 minutes en heures.
    static func round5min(_ hours: Double) -> Double {
        (hours * 12).rounded() / 12
    }

    /// Idéal brut (non borné) d'une nuit de contexte `z` : règle des 95 % du
    /// gain sur `g(S | z) = α·h0(S) + Σ d_k·r_k(S) + (Σ γ_j z_j)·centeredHours(S)`.
    static func idealRaw(model: Model, z: [Double]) -> Double {
        var shift = 0.0
        for k in 0..<interactionCount { shift += model.gamma[k] * z[k] }
        return SleepOptimumModel.idealFromCurve { s in
            var sum = model.alpha * SleepOptimumModel.h0(s)
            for i in SleepOptimumModel.knots.indices { sum += SleepOptimumModel.ramp(s, SleepOptimumModel.knots[i]) * model.d[i] }
            return sum + shift * centeredHours(s)
        }
    }

    /// Durée idéale (heures) d'UNE nuit pour ce contexte. Garde-fous : modèle
    /// étendu sur < 30 nuits, ou 4 covariables toutes absentes → idéal global.
    /// Sinon : borne à ± 1 h autour de l'idéal brut global, puis à [7 ; 9,5],
    /// puis arrondi à 5 min.
    static func nightIdealHours(model: Model, covariates: Covariates) -> Double {
        guard model.n >= minNights, !covariates.allAbsent else { return model.globalIdealHours }
        let z = zip(model.stats, covariates.values).map { $0.z($1) }
        let raw = idealRaw(model: model, z: z)
        let bounded = min(max(raw, model.globalIdealRaw - maxDeviationHours), model.globalIdealRaw + maxDeviationHours)
        return round5min(SleepOptimumModel.clampHours(bounded))
    }

    // MARK: - Covariables d'une nuit À VENIR (ou pas encore synchronisée)

    /// Endormissement HABITUEL : médiane des endormissements locaux recentrés
    /// autour de midi des 7 dernières nuits (même formule que
    /// `SleepRecommendationLocal.computeSleepRecommendation`), en minutes
    /// depuis minuit local. `nil` sans nuit.
    static func habitualOnsetMin(nights: [SleepRecommendationLocal.ModelRawNight]) -> Double? {
        guard !nights.isEmpty else { return nil }
        let last7 = nights.sorted { $0.startTs < $1.startTs }.suffix(7)
        let recentered = last7.map { n -> Double in
            let onsetMin = SleepRecommendationLocal.mod(n.startTs + n.offsetS, 86400) / 60
            return SleepRecommendationLocal.mod(onsetMin - 720, 1440)
        }
        return SleepRecommendationLocal.mod(SleepRecommendationLocal.median(recentered) + 720, 1440)
    }

    /// `onsetRef = min(maintenant, endormissement habituel de la nuit qui finit
    /// le jour `date`)`. La nuit de réveil `date` commence la veille : on ancre
    /// l'endormissement habituel (recentré autour de midi) sur midi local de
    /// `date − 1`, ce qui couvre aussi les coucher après minuit. `offsetS` =
    /// décalage fuseau local à cette date (`LocalDb.localOffsetSeconds`).
    /// Sans endormissement habituel : `nowS`.
    static func onsetReference(date: String, nowS: Double, habitualOnsetMin: Double?, offsetS: Double) -> Double {
        guard let habitualOnsetMin else { return nowS }
        let localNoonEve = DashboardStatsTime.dayStartUnixUTC(date) - 86400 + 12 * 3600
        let recentered = SleepRecommendationLocal.mod(habitualOnsetMin - 720, 1440)
        let habitualTs = localNoonEve + recentered * 60 - offsetS
        return min(nowS, habitualTs)
    }

    /// `priorSleep` (§4.7) d'une nuit de réveil `date` : moyenne pondérée des
    /// `S` des nuits `d−1 … d−7` présentes, poids `0.5^(k−1)` ; `nil` si aucune.
    static func priorSleep(date: String, sleepByDate: [String: Double]) -> Double? {
        var weightedSum = 0.0
        var weightTotal = 0.0
        for k in 1...7 {
            let candidateDate = FitWellnessExtractor.isoDate(
                DashboardStatsTime.dayStartUnixUTC(date) - Double(k) * 86400)
            guard let s = sleepByDate[candidateDate] else { continue }
            let weight = pow(0.5, Double(k - 1))
            weightedSum += weight * s
            weightTotal += weight
        }
        return weightTotal > 0 ? weightedSum / weightTotal : nil
    }

    /// Covariables brutes d'une nuit pour laquelle on n'a pas de sommeil mesuré,
    /// avec un endormissement de référence `onsetRef` (cf. `onsetReference`) et
    /// les MÊMES fenêtres que la spec §4 : `bbBed` = dernier `bb` dans
    /// `[onsetRef − 60 min ; onsetRef]` ; `stressPrevDay` = moyenne du stress
    /// sur `[onsetRef − 14 h ; onsetRef − 30 min]` (≥ 60 échantillons, sinon
    /// absente) ; `sportPrev` = minutes d'activité commencées dans
    /// `[onsetRef − 24 h ; onsetRef]` (0 si aucune) ; `priorSleep` sur `d−1…d−7`.
    static func upcomingNightCovariates(
        date: String, onsetRef: Double,
        bbSamples: [SleepRecommendationLocal.Sample],
        stressSamples: [SleepRecommendationLocal.Sample],
        activities: [SleepRecommendationLocal.ActivityWindow],
        sleepByDate: [String: Double]
    ) -> Covariates {
        let bbBed = bbSamples
            .filter { $0.ts >= onsetRef - 3600 && $0.ts <= onsetRef }
            .max { $0.ts < $1.ts }?.value

        let stressWindow = stressSamples.filter { $0.ts >= onsetRef - 14 * 3600 && $0.ts <= onsetRef - 1800 }
        let stressPrevDay = stressWindow.count >= 60 ? DashboardStatsMath.mean(stressWindow.map(\.value)) : nil

        let sportPrev = activities
            .filter { $0.startTs >= onsetRef - 24 * 3600 && $0.startTs <= onsetRef }
            .reduce(0) { $0 + $1.durationMin }

        return Covariates(
            bbBed: bbBed, stressPrevDay: stressPrevDay, sportPrev: sportPrev,
            priorSleep: priorSleep(date: date, sleepByDate: sleepByDate))
    }
}
