//
//  SleepOptimum.swift
//  all (bridge-connect)
//
//  Durée idéale de sommeil — portage Swift de la spec commune
//  `all/docs/duree-ideale-sommeil.md`, écrite en parallèle côté serveur
//  (`custom-connect/server/src/stats/sleep-optimum.ts`, pas encore présent au
//  moment de ce portage — implémentation faite directement depuis la spec,
//  normative). Les deux doivent produire le même résultat sur la fixture dorée
//  partagée (§8) — `allTests/SleepOptimumTests.swift`.
//
//  Tout ce fichier est PUR (aucune E/S, aucun accès `LocalDb`) : il prend des
//  nuits DÉJÀ AGRÉGÉES (`SleepOptimumNightInput` — S, issues, covariables
//  BRUTES, cf. spec §2-4) et produit l'idéal + l'intervalle + le tirage de ce
//  soir. La construction de ces nuits agrégées depuis `LocalDb` (requêtes,
//  fenêtres temporelles, fuseaux) vit dans `Local/SleepRecommendationLocal.swift`.
//

import Foundation

// MARK: - PRNG déterministe (spec §8)

/// mulberry32 — arithmétique 32 bits NON SIGNÉE. Même algorithme que la
/// référence JS canonique (`a = a + 0x6D2B79F5 | 0; t = Math.imul(a ^ a>>>15,
/// 1|a); t = t + Math.imul(t ^ t>>>7, 61|t) | 0; return (t ^ t>>>14) >>> 0`) :
/// `&+`/`&*` sur `UInt32` enroulent identiquement à `Math.imul`/`|0` côté JS
/// (même troncature 32 bits), `>>` sur `UInt32` est déjà un décalage non
/// signé (pas de distinction `>>`/`>>>` nécessaire côté Swift).
struct Mulberry32 {
    private var state: UInt32

    init(seed: UInt32) { state = seed }

    mutating func nextUInt32() -> UInt32 {
        state = state &+ 0x6D2B_79F5
        let a = state
        var t = (a ^ (a >> 15)) &* (a | 1)
        t = (t &+ ((t ^ (t >> 7)) &* (t | 61))) ^ t
        return t ^ (t >> 14)
    }

    /// Uniforme ∈ [0, 1) — `next() / 2^32` (spec §8).
    mutating func nextUniform() -> Double {
        Double(nextUInt32()) / 4_294_967_296.0
    }

    /// Box–Muller : `u1 = 1 − uniform() ∈ (0,1]`, `u2 = uniform()`,
    /// `z = sqrt(−2 ln u1) · cos(2π u2)` — UNE normale par paire d'uniformes,
    /// pas de cache du sinus (spec §8).
    mutating func nextNormal() -> Double {
        let u1 = 1 - nextUniform()
        let u2 = nextUniform()
        return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * Double.pi * u2)
    }

    /// `p` normales CONSÉCUTIVES — un tirage complet de `w̃` (spec §8 : « pour
    /// chaque tirage, p normales consécutives »).
    mutating func nextNormals(_ p: Int) -> [Double] {
        (0..<p).map { _ in nextNormal() }
    }
}

/// FNV-1a 32 bits sur les octets UTF-8 (spec §8) — graine du soir,
/// `fnv1a32(todayKey)`.
func fnv1a32(_ s: String) -> UInt32 {
    var hash: UInt32 = 0x811C_9DC5
    for byte in s.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 0x0100_0193
    }
    return hash
}

// MARK: - Algèbre linéaire minimale (p = 14, implémentée à la main — spec §5)

enum SleepOptimumLinAlg {
    /// Cholesky d'une matrice symétrique définie positive : `A = L·Lᵀ`, `L`
    /// triangulaire inférieure.
    static func cholesky(_ a: [[Double]]) -> [[Double]] {
        let p = a.count
        var l = Array(repeating: Array(repeating: 0.0, count: p), count: p)
        for i in 0..<p {
            for j in 0...i {
                var sum = a[i][j]
                for k in 0..<j { sum -= l[i][k] * l[j][k] }
                l[i][j] = (i == j) ? sum.squareRoot() : sum / l[j][j]
            }
        }
        return l
    }

    /// Résout `L v = b` (`L` triangulaire inférieure) par substitution avant.
    static func forwardSolve(_ l: [[Double]], _ b: [Double]) -> [Double] {
        let p = l.count
        var v = Array(repeating: 0.0, count: p)
        for i in 0..<p {
            var sum = b[i]
            for k in 0..<i { sum -= l[i][k] * v[k] }
            v[i] = sum / l[i][i]
        }
        return v
    }

    /// Résout `Lᵀ x = v` (`Lᵀ` triangulaire supérieure, `Lᵀ[i][k] = L[k][i]`)
    /// par substitution arrière — utilisé pour `mn` (depuis `Λn mn = rhs`,
    /// après `forwardSolve`) ET pour les tirages (`w̃ = mn + σ̂·L⁻ᵀz`).
    static func backwardSolveTranspose(_ l: [[Double]], _ v: [Double]) -> [Double] {
        let p = l.count
        var x = Array(repeating: 0.0, count: p)
        for i in stride(from: p - 1, through: 0, by: -1) {
            var sum = v[i]
            for k in (i + 1)..<p { sum -= l[k][i] * x[k] }
            x[i] = sum / l[i][i]
        }
        return x
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }

    static func matVec(_ m: [[Double]], _ v: [Double]) -> [Double] {
        m.map { dot($0, v) }
    }

    static func quadForm(_ v: [Double], _ m: [[Double]]) -> Double {
        dot(v, matVec(m, v))
    }
}

// MARK: - Nuit agrégée en entrée (spec §2-4) — c'est elle que la fixture dorée exerce

/// Une nuit DÉJÀ agrégée : durée + 3 issues du lendemain + 7 covariables
/// BRUTES (pas encore z-scorées — cf. `SleepOptimumFeatures.build`). Valeur
/// manquante = `nil`. Mêmes clés que la fixture dorée (spec §8).
struct SleepOptimumNightInput {
    let date: String
    /// `(deep+light+rem)/3600`, déjà filtrée dans `[3, 12]` h par l'appelant.
    let S: Double
    let bbMorning: Double?
    let bbEvening: Double?
    let wakeStress: Double?
    let bbBed: Double?
    let stressPrevDay: Double?
    let sportPrev: Double?
    let sportNext: Double?
    let workdayNext: Double?
    let onsetShift: Double?
    let priorSleep: Double?

    init(
        date: String, S: Double, bbMorning: Double? = nil, bbEvening: Double? = nil, wakeStress: Double? = nil,
        bbBed: Double? = nil, stressPrevDay: Double? = nil, sportPrev: Double? = nil, sportNext: Double? = nil,
        workdayNext: Double? = nil, onsetShift: Double? = nil, priorSleep: Double? = nil
    ) {
        self.date = date
        self.S = S
        self.bbMorning = bbMorning
        self.bbEvening = bbEvening
        self.wakeStress = wakeStress
        self.bbBed = bbBed
        self.stressPrevDay = stressPrevDay
        self.sportPrev = sportPrev
        self.sportNext = sportNext
        self.workdayNext = workdayNext
        self.onsetShift = onsetShift
        self.priorSleep = priorSleep
    }
}

// MARK: - Construction Y / X (spec §3-4)

enum SleepOptimumFeatures {
    /// `X`/`y` prêts pour `SleepOptimumModel.fit`, restreints aux nuits
    /// RETENUES (après exclusion §3.3 — moins de 2 issues présentes).
    struct Built {
        let X: [[Double]]
        let y: [Double]
        let nightsUsed: [SleepOptimumNightInput]
        /// Moyenne / écart-type (population) de chacune des 7 covariables sur
        /// les nuits RETENUES, valeurs présentes seulement — exactement ceux
        /// qui ont servi au z-score de `X` (ordre spec §4). Exposés pour la
        /// couche contextuelle (`SleepOptimumContext`), qui doit z-scorer une
        /// nuit hors modèle de la même façon. N'influencent ni `X` ni `y`.
        let covariateStats: [CovariateStat]
    }

    struct CovariateStat: Equatable {
        let mean: Double
        let sd: Double

        /// z-score d'une valeur brute : manquant → 0, écart-type nul → 0
        /// (mêmes règles que `build`, spec §4).
        func z(_ raw: Double?) -> Double {
            guard let raw, sd > 0 else { return 0 }
            return (raw - mean) / sd
        }
    }

    /// Spec §3 (composite `Y`) + §4 (7 covariables) — fonction PURE, exercée
    /// directement par la fixture dorée.
    static func build(nights: [SleepOptimumNightInput]) -> Built {
        // §3.1-2 : z-score POPULATION de chaque issue présente (moyenne/écart-type
        // sur les nuits où elle est présente) ; écart-type nul → issue ignorée
        // PARTOUT (pas seulement mise à 0) ; `wakeStress` nié (z → −z).
        func zColumn(_ values: [Double?], negate: Bool = false) -> [Double?] {
            let present = values.compactMap { $0 }
            let sd = DashboardStatsMath.stdev(present)
            guard sd > 0 else { return values.map { _ in nil } }
            let m = DashboardStatsMath.mean(present)
            return values.map { v in
                guard let v else { return nil }
                let z = (v - m) / sd
                return negate ? -z : z
            }
        }
        let zBbMorning = zColumn(nights.map(\.bbMorning))
        let zBbEvening = zColumn(nights.map(\.bbEvening))
        let zWakeStress = zColumn(nights.map(\.wakeStress), negate: true)

        // §3.3 : Yraw = moyenne des z présents ; nuit exclue si < 2 présents.
        var yraw: [Double?] = []
        for i in nights.indices {
            let zs = [zBbMorning[i], zBbEvening[i], zWakeStress[i]].compactMap { $0 }
            yraw.append(zs.count >= 2 ? DashboardStatsMath.mean(zs) : nil)
        }

        // §3.4 : Y = z-score de Yraw SUR LES NUITS RETENUES.
        let retainedIdx = nights.indices.filter { yraw[$0] != nil }
        let yrawRetained = retainedIdx.map { yraw[$0]! }
        let yrawMean = DashboardStatsMath.mean(yrawRetained)
        let yrawSd = DashboardStatsMath.stdev(yrawRetained)

        // §4 : covariables — z-scorées SUR LES NUITS RETENUES ; manquant → 0
        // après standardisation (imputation par la moyenne, calculée sur les
        // valeurs présentes SEULEMENT) ; écart-type nul → colonne à 0.
        var covStats: [CovariateStat] = []
        func covColumn(_ values: [Double?]) -> [Double] {
            let retainedValues = retainedIdx.compactMap { values[$0] }
            let sd = DashboardStatsMath.stdev(retainedValues)
            let m = DashboardStatsMath.mean(retainedValues)
            covStats.append(CovariateStat(mean: m, sd: sd))
            guard sd > 0 else { return retainedIdx.map { _ in 0 } }
            return retainedIdx.map { idx in
                guard let raw = values[idx] else { return 0 }
                return (raw - m) / sd
            }
        }
        let covBbBed = covColumn(nights.map(\.bbBed))
        let covStressPrevDay = covColumn(nights.map(\.stressPrevDay))
        let covSportPrev = covColumn(nights.map(\.sportPrev))
        let covSportNext = covColumn(nights.map(\.sportNext))
        let covWorkdayNext = covColumn(nights.map(\.workdayNext))
        let covOnsetShift = covColumn(nights.map(\.onsetShift))
        let covPriorSleep = covColumn(nights.map(\.priorSleep))

        var X: [[Double]] = []
        var y: [Double] = []
        var used: [SleepOptimumNightInput] = []
        for (row, idx) in retainedIdx.enumerated() {
            let night = nights[idx]
            let yi = yrawSd > 0 ? (yrawRetained[row] - yrawMean) / yrawSd : 0
            let covariates = [
                covBbBed[row], covStressPrevDay[row], covSportPrev[row], covSportNext[row],
                covWorkdayNext[row], covOnsetShift[row], covPriorSleep[row],
            ]
            X.append(SleepOptimumModel.featureRow(S: night.S, covariates: covariates))
            y.append(yi)
            used.append(night)
        }
        return Built(X: X, y: y, nightsUsed: used, covariateStats: covStats)
    }
}

// MARK: - Modèle bayésien (spec §5-6, v1.1 — forme × amplitude + écarts locaux)
//
// v1.1 (2026-10-02) remplace les pentes absolues par tranche d'1 h de la v1
// (biaisées de ≈ +1 h en simulation : le lissage propageait le gain des
// nuits courtes vers la queue 7-9 h) par une décomposition « forme × amplitude
// + écarts » : `h0(S)` = forme a priori FIXE (littérature, `SHAPE`), mise à
// l'échelle par une amplitude personnelle `α` (apprise), plus des écarts
// locaux `d_k` par demi-heure. Là où il n'y a pas de données, `d_k` reste à 0
// et la courbe suit `α · h0(S)` — jamais tirée vers l'habitude.

enum SleepOptimumModel {
    /// `p = 1 (c) + 1 (α) + 12 (d) + 7 (β)`.
    static let p = 21
    /// Nœuds des rampes, pas 0,5 h — `d[0]` correspond à `k = 4`, `d[11]` à
    /// `k = 9.5`.
    static let knots: [Double] = [4, 4.5, 5, 5.5, 6, 6.5, 7, 7.5, 8, 8.5, 9, 9.5]
    /// Forme a priori (pentes σ/h par nœud, littérature) — spec §5. FIXE, ne
    /// fait PAS partie de `w` (contrairement à `d`) : sert à construire la
    /// colonne `h0(S)` de `X`.
    static let shape: [Double] = [0.45, 0.45, 0.40, 0.40, 0.35, 0.30, 0.25, 0.15, 0.05, 0.00, -0.05, -0.05]
    static let a0 = 2.0
    static let b0 = 1.0
    /// Précision du bloc écarts locaux `d` (RW1) : `sigma0` (diagonal),
    /// `sigmaRW` (lissage entre nœuds voisins).
    static let sigma0 = 0.6
    static let sigmaRW = 1.5
    static let seedCI: UInt32 = 0x5EED_0001
    static let ciDraws = 400
    static let grid: [Double] = (0...100).map { 5 + 0.05 * Double($0) }

    /// `r_k(S) = clamp(S − k, 0, 0.5)` (en heures) — hauteur max 0,5 (pas 1,
    /// v1), un nœud couvre `[k, k+0.5]`.
    static func ramp(_ s: Double, _ k: Double) -> Double {
        min(max(s - k, 0), 0.5)
    }

    /// `h0(S) = Σ_k SHAPE_k · r_k(S)` — forme a priori, FIXE (spec §5).
    static func h0(_ s: Double) -> Double {
        var sum = 0.0
        for i in knots.indices { sum += shape[i] * ramp(s, knots[i]) }
        return sum
    }

    /// Colonnes `[1, h0(S), r4..r9.5 (12), cov1..cov7]` pour une nuit —
    /// `covariates` DÉJÀ z-scorées (7 valeurs, ordre spec §4). `p = 21`.
    static func featureRow(S: Double, covariates: [Double]) -> [Double] {
        var row: [Double] = [1, h0(S)]
        row.append(contentsOf: knots.map { ramp(S, $0) })
        row.append(contentsOf: covariates)
        return row
    }

    /// `μ0` — spec §5 : intercept nul, `α = 1` (amplitude a priori = forme
    /// littérature telle quelle), écarts/covariables nuls.
    static let mu0: [Double] = {
        var v = Array(repeating: 0.0, count: p)
        v[1] = 1 // α
        return v
    }()

    /// `Λ0` — bloc diagonal : intercept / amplitude `α` (faible précision,
    /// l'amplitude vient des données) / écarts locaux `d` (lissage RW1) /
    /// covariables (`onsetShift` resserrée) — spec §5.
    static let lambda0: [[Double]] = {
        var m = Array(repeating: Array(repeating: 0.0, count: p), count: p)
        m[0][0] = 1.0 / (10.0 * 10.0)
        m[1][1] = 1.0 / (2.0 * 2.0)

        // Bloc écarts locaux `d` (indices 2...13, 12×12) : I/σ0² + DᵀD/σrw²,
        // `D` 11×12 différences premières (`D[i][i] = −1`, `D[i][i+1] = 1`).
        let n = knots.count // 12
        var d = Array(repeating: Array(repeating: 0.0, count: n), count: n - 1)
        for i in 0..<(n - 1) { d[i][i] = -1; d[i][i + 1] = 1 }
        var dtd = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                var sum = 0.0
                for row in 0..<(n - 1) { sum += d[row][i] * d[row][j] }
                dtd[i][j] = sum
            }
        }
        let invSigma0Sq = 1.0 / (sigma0 * sigma0)
        let invSigmaRWSq = 1.0 / (sigmaRW * sigmaRW)
        for i in 0..<n {
            for j in 0..<n {
                var v = dtd[i][j] * invSigmaRWSq
                if i == j { v += invSigma0Sq }
                m[2 + i][2 + j] = v
            }
        }

        // Bloc covariables (indices 14...20) : diagonal, 1/1² sauf
        // `onsetShift` (covariable #6, index 19) à 1/0.5².
        for i in 0..<7 {
            m[14 + i][14 + i] = (i == 5) ? (1.0 / 0.25) : 1.0
        }
        return m
    }()

    /// Spec §6 : plus petite durée qui atteint 95 % du gain (rendements
    /// décroissants). `g(S) = α · h0(S) + Σ_k d_k · r_k(S)`.
    static func idealFromParams(alpha: Double, d: [Double]) -> Double {
        idealFromCurve { s in
            var sum = alpha * h0(s)
            for i in knots.indices { sum += ramp(s, knots[i]) * d[i] }
            return sum
        }
    }

    /// Règle des 95 % du gain sur une courbe `g` quelconque — partagée avec la
    /// couche contextuelle (`SleepOptimumContext`), dont `g` porte en plus un
    /// terme d'interaction.
    static func idealFromCurve(_ g: (Double) -> Double) -> Double {
        let g5 = g(5)
        var gmax = g5
        for s in grid { gmax = max(gmax, g(s)) }
        let gain = gmax - g5
        guard gain >= 0.05 else { return 5 }
        let threshold = g5 + 0.95 * gain
        for s in grid where g(s) >= threshold { return s }
        return grid.last ?? 10
    }

    static func round025(_ v: Double) -> Double {
        (v / 0.25).rounded() * 0.25
    }

    static func clampHours(_ v: Double) -> Double {
        min(max(v, 7), 9.5)
    }

    /// A posteriori ajusté (`mn`/Cholesky de `Λn`/`σ̂`) + sorties dérivées
    /// (spec §6). `n = 0` n'est PAS un cas particulier codé à part : avec
    /// `X`/`y` vides, `Λn = Λ0` et `rhs = Λ0 μ0`, donc `mn = μ0` exactement —
    /// l'a posteriori collapse mathématiquement sur l'a priori (idéal 7,85 h
    /// → 7,75 h arrondi, `basis = 'prior'`), ce qui EST « pas de calcul » de la
    /// spec, obtenu par le même code plutôt que par une branche séparée.
    struct Fit {
        let n: Int
        let mn: [Double]
        let l: [[Double]]
        let sigmaHat: Double
        let idealRaw: Double
        let lowRaw: Double
        let highRaw: Double
        let idealHours: Double
        let idealLowHours: Double
        let idealHighHours: Double
        let belowFloor: Bool
        let basis: String // "modele" | "prior"
    }

    /// A posteriori conjugué d'un modèle linéaire gaussien d'a priori
    /// `(μ0, Λ0)` — mécanique COMMUNE à `fit` (p = 21) et au modèle contextuel
    /// étendu (p = 25, `SleepOptimumContext`). `p` = `mu0.count`. Ordre des
    /// opérations flottantes inchangé par rapport à l'ancien corps de `fit`
    /// (parité bit-à-bit avec le TS, fixture dorée §8).
    struct Posterior {
        let n: Int
        let mn: [Double]
        let l: [[Double]]
        let sigmaHat: Double
    }

    static func posterior(X: [[Double]], y: [Double], lambda0: [[Double]], mu0: [Double]) -> Posterior {
        let p = mu0.count
        let n = X.count
        var lambdaN = lambda0
        for row in X {
            for i in 0..<p where row[i] != 0 {
                for j in 0..<p { lambdaN[i][j] += row[i] * row[j] }
            }
        }
        // Parité bit-à-bit avec le TS (`addVec(Lambda0·mu0, Xty)`, spec §8) :
        // `Xty` est sommé À PART depuis 0, PUIS additionné à `Lambda0·mu0`.
        // L'addition flottante n'est pas associative — seeder `rhs` avec
        // `Lambda0·mu0` puis accumuler dessus décalerait `rhs[1]` (l'amplitude
        // α, seul terme non nul de `Lambda0·mu0`) d'un ULP, ce qui suffit à
        // faire basculer d'un cran de grille un tirage pile sur un seuil (bug
        // observé : `highRaw` à +0,05 h).
        let lambda0Mu0 = SleepOptimumLinAlg.matVec(lambda0, mu0)
        var xty = Array(repeating: 0.0, count: p)
        for (xi, yi) in zip(X, y) {
            for i in 0..<p { xty[i] += xi[i] * yi }
        }
        let rhs = zip(lambda0Mu0, xty).map { $0 + $1 }

        let l = SleepOptimumLinAlg.cholesky(lambdaN)
        let v = SleepOptimumLinAlg.forwardSolve(l, rhs)
        let mn = SleepOptimumLinAlg.backwardSolveTranspose(l, v)

        let an = a0 + Double(n) / 2
        let yty = y.reduce(0) { $0 + $1 * $1 }
        let mu0Lambda0Mu0 = SleepOptimumLinAlg.quadForm(mu0, lambda0)
        // `mnᵀ Λn mn == mnᵀ rhs` puisque `Λn mn = rhs` (équation normale) —
        // évite de reformer `Λn mn`.
        let mnLambdaNMn = SleepOptimumLinAlg.dot(mn, rhs)
        let bn = b0 + 0.5 * (yty + mu0Lambda0Mu0 - mnLambdaNMn)
        let sigmaHatSq = max(bn / (an - 1), 0)
        return Posterior(n: n, mn: mn, l: l, sigmaHat: sigmaHatSq.squareRoot())
    }

    static func fit(X: [[Double]], y: [Double]) -> Fit {
        let post = posterior(X: X, y: y, lambda0: lambda0, mu0: mu0)
        let n = post.n
        let mn = post.mn
        let l = post.l
        let sigmaHat = post.sigmaHat

        let idealRaw = idealFromParams(alpha: mn[1], d: Array(mn[2...13]))

        var ci = Mulberry32(seed: seedCI)
        var ideals: [Double] = []
        ideals.reserveCapacity(ciDraws)
        for _ in 0..<ciDraws {
            let z = ci.nextNormals(p)
            let x = SleepOptimumLinAlg.backwardSolveTranspose(l, z)
            let wTilde = zip(mn, x).map { $0 + sigmaHat * $1 }
            ideals.append(idealFromParams(alpha: wTilde[1], d: Array(wTilde[2...13])))
        }
        ideals.sort()
        let lowIdx = Int((0.1 * Double(ciDraws - 1)).rounded(.down))
        let highIdx = Int((0.9 * Double(ciDraws - 1)).rounded(.down))
        let lowRaw = ideals[lowIdx]
        let highRaw = ideals[highIdx]

        return Fit(
            n: n, mn: mn, l: l, sigmaHat: sigmaHat,
            idealRaw: idealRaw, lowRaw: lowRaw, highRaw: highRaw,
            idealHours: round025(clampHours(idealRaw)),
            idealLowHours: round025(clampHours(lowRaw)),
            idealHighHours: round025(clampHours(highRaw)),
            belowFloor: idealRaw < 7,
            basis: n >= 14 ? "modele" : "prior")
    }

    // MARK: - Recommandation de ce soir (spec §7)

    struct TonightDraw {
        let u: Double
        let idealTs: Double
    }

    /// Un seul tirage de `w̃` depuis le postérieur déjà ajusté, graine
    /// `fnv1a32(todayKey)` — `u` est le PREMIER uniforme tiré, puis UN tirage
    /// complet (spec §7.1 : « u = premier uniforme, puis un tirage w̃ »).
    static func tonightDraw(fit: Fit, todayKey: String) -> TonightDraw {
        var rng = Mulberry32(seed: fnv1a32(todayKey))
        let u = rng.nextUniform()
        let z = rng.nextNormals(p)
        let x = SleepOptimumLinAlg.backwardSolveTranspose(fit.l, z)
        let wTilde = zip(fit.mn, x).map { $0 + fit.sigmaHat * $1 }
        let idealTs = idealFromParams(alpha: wTilde[1], d: Array(wTilde[2...13]))
        return TonightDraw(u: u, idealTs: idealTs)
    }

    struct Recommendation {
        let targetHours: Double
        let trial: Bool
        let debtHours: Double
        let debtBonusMin: Int
    }

    /// Spec §7 — combine le tirage de ce soir (exploration Thompson dosée) et
    /// la dette (7 dernières nuits de la FENÊTRE DE L'ENDPOINT, `last7SleepHours`
    /// — pas les 180 nuits du modèle) en `targetHours`.
    static func recommendation(fit: Fit, todayKey: String, last7SleepHours: [Double]) -> Recommendation {
        let draw = tonightDraw(fit: fit, todayKey: todayKey)
        let trial = fit.basis == "modele"
            && draw.u < 0.25
            && (fit.highRaw - fit.lowRaw) >= 0.75
            && abs(clampHours(draw.idealTs) - fit.idealHours) >= 0.25
        let base = trial ? round025(clampHours(draw.idealTs)) : fit.idealHours

        let debtHours = max(0, last7SleepHours.reduce(0) { $0 + (fit.idealHours - $1) })
        let debtBonusMin = debtHours > 4 ? 30 : (debtHours > 2 ? 15 : 0)
        let targetHours = clampHours(base + Double(debtBonusMin) / 60)

        return Recommendation(targetHours: targetHours, trial: trial, debtHours: debtHours, debtBonusMin: debtBonusMin)
    }
}
