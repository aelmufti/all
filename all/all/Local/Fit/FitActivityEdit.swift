//
//  FitActivityEdit.swift
//  all (bridge-connect)
//
//  Calcul d'une activité MODIFIÉE (fenêtre rognée et/ou fusion) — miroir côté
//  téléphone du §4 de `custom-connect/docs/activity-edits-contract.md` (le serveur
//  l'implémente dans `custom-connect/server/src/activities/`). Les deux côtés doivent
//  sortir les mêmes chiffres à partir des mêmes `.fit` et des mêmes modifications.
//
//  Fonction PURE : messages FIT décodés + fenêtre → résumé + détail, aucune E/S. Le
//  `.fit` n'est jamais modifié, la surcouche est rejouée à chaque calcul. Une
//  activité sans fenêtre ni fusion ne passe PAS ici (elle garde `extractSummary` /
//  `extractDetail`, inchangés) ; avec une fenêtre qui couvre tout, le résultat est le
//  même que `extractDetail` pour les courbes et la trace.
//
//  Temps : tout est calculé en secondes FIT (epoch Garmin) ; la fenêtre arrive en
//  secondes Unix (`Window`) et est convertie à l'entrée.
//
//  Choix là où le contrat laisse du jeu :
//   - un intervalle actif de longueur nulle est écarté ; sans intervalle exploitable
//     (aucun événement timer, ou tous nuls) on retombe sur [premier record, dernier
//     record] ;
//   - un record à la frontière de deux intervalles n'est compté que dans le premier ;
//   - le flux `distance` reste la valeur brute de chaque record (non recalée d'un
//     membre à l'autre) ; seule la distance du RÉSUMÉ est la somme des différences ;
//   - arrondis alignés sur le serveur : durées à 3 décimales, distances à 2, `time` à 3,
//     `avgHr` à l'entier, secondes de zone au dixième ; borne de DÉBUT stricte pour la
//     distance (§4.4, `d⁻`).
//

import Foundation

enum FitActivityEdit {
    /// Fenêtre gardée, en secondes UNIX ; `nil` = pas de borne.
    struct Window: Equatable {
        var start: Double?
        var end: Double?
        static let open = Window(start: nil, end: nil)
        var isOpen: Bool { start == nil && end == nil }
    }

    struct Result {
        let summary: FitActivityExtractor.Summary
        let detail: FitActivityExtractor.Detail
    }

    /// Bornes d'origine (secondes Unix) : début du premier intervalle actif, fin du
    /// dernier, tous membres confondus.
    struct Span: Equatable {
        let start: Double
        let end: Double
    }

    // MARK: - Types internes

    private struct Iv: Equatable {
        var lo: Double
        var hi: Double
        var length: Double { hi - lo }
    }

    private struct Rec {
        let ts: Double
        let hr: Double?
        let dist: Double?
        let msg: FitMessage
    }

    private struct Member {
        let messages: [FitMessage]
        let recs: [Rec]
        let original: [Iv]
        var kept: [Iv] = []
        init(messages: [FitMessage]) {
            self.messages = messages
            recs = FitActivityEdit.records(messages)
            original = FitActivityEdit.activeIntervals(messages, recs: recs)
        }
    }

    /// `w(hr)` de la forme de Keytel (contrat §4.6).
    private static func weight(_ hr: Double?) -> Double {
        guard let hr else { return 1 }
        return max(0.6309 * hr - 34, 1)
    }

    // MARK: - Intervalles actifs (§4.1)

    private static func records(_ messages: [FitMessage]) -> [Rec] {
        messages.compactMap { m in
            guard m.globalMessageNumber == FitProfile.mesgRecord, let ts = m.double(253) else { return nil }
            return Rec(ts: ts, hr: m.double(3), dist: m.double(5), msg: m)
        }
    }

    /// `event` timer (champ 0 == 0) : `start` (0) ouvre, `stop` (1) / `stopAll` (4) ferme.
    private static func activeIntervals(_ messages: [FitMessage], recs: [Rec]) -> [Iv] {
        let timerEvents = messages.filter { $0.globalMessageNumber == FitProfile.mesgEvent && $0.double(0) == 0 && $0.double(253) != nil }
        var out: [Iv] = []
        if !timerEvents.isEmpty {
            var open: Double?
            for event in timerEvents {
                guard let ts = event.double(253), let type = event.double(1) else { continue }
                if type == 0 {
                    if open == nil { open = ts }
                } else if type == 1 || type == 4 || type == 8 || type == 9, let start = open {  // stop, stopAll, stopDisable(All)
                    if ts > start { out.append(Iv(lo: start, hi: ts)) }
                    open = nil
                }
            }
            if let start = open, let last = recs.last?.ts, last > start { out.append(Iv(lo: start, hi: last)) }
        }
        if out.isEmpty, let first = recs.first?.ts, let last = recs.last?.ts, last > first {
            out = [Iv(lo: first, hi: last)]
        }
        return out
    }

    private static func clip(_ ivs: [Iv], to window: (lo: Double, hi: Double)) -> [Iv] {
        ivs.compactMap { iv in
            let lo = max(iv.lo, window.lo), hi = min(iv.hi, window.hi)
            return hi > lo ? Iv(lo: lo, hi: hi) : nil
        }
    }

    // MARK: - Records gardés et `dt` (§4.2)

    /// Records tombant dans un intervalle, avec leur `dt` : `min(ts(r+1) − ts(r), fin
    /// de l'intervalle − ts(r))`, borné à 0. Un record n'appartient qu'au premier
    /// intervalle qui le contient.
    private static func weighted(_ recs: [Rec], in ivs: [Iv]) -> [(index: Int, dt: Double)] {
        var out: [(Int, Double)] = []
        for (i, rec) in recs.enumerated() {
            guard let iv = ivs.first(where: { $0.lo <= rec.ts && rec.ts <= $0.hi }) else { continue }
            let next = i + 1 < recs.count ? recs[i + 1].ts : Double.infinity
            out.append((i, max(0, min(next - rec.ts, iv.hi - rec.ts))))
        }
        return out
    }

    /// `d_k(t)` : `distance` du dernier record avec `ts ≤ t` qui en porte une (0 sinon) ;
    /// `strict` : `d_k⁻(t)`, avec `ts < t` (borne de DÉBUT, contrat §4.4).
    private static func distanceAt(_ recs: [Rec], _ t: Double, strict: Bool = false) -> Double {
        var value = 0.0
        for rec in recs where strict ? rec.ts < t : rec.ts <= t {
            if let d = rec.dist { value = d }
        }
        return value
    }

    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    private struct PieceStats {
        let durationS: Double
        let distanceM: Double?
        let avgHr: Double?
        let maxHr: Double?
    }

    /// Durée, distance (différence), FC moyenne (pondérée par `dt`, arrondie) et max
    /// d'un ensemble de morceaux d'un membre.
    private static func stats(_ recs: [Rec], pieces: [Iv]) -> PieceStats {
        let duration = pieces.reduce(0) { $0 + $1.length }
        var distance: Double?
        if recs.contains(where: { $0.dist != nil }), let lo = pieces.map(\.lo).min(), let hi = pieces.map(\.hi).max() {
            distance = round2(distanceAt(recs, hi) - distanceAt(recs, lo, strict: true))
        }
        var sum = 0.0, total = 0.0, maxHr: Double?
        var plain: [Double] = []
        for (i, dt) in weighted(recs, in: pieces) {
            guard let hr = recs[i].hr else { continue }
            sum += hr * dt
            total += dt
            plain.append(hr)
            maxHr = max(maxHr ?? hr, hr)
        }
        var avg: Double?
        if total > 0 {
            avg = (sum / total).rounded()
        } else if !plain.isEmpty {
            avg = (plain.reduce(0, +) / Double(plain.count)).rounded()
        }
        return PieceStats(durationS: round3(duration), distanceM: distance, avgHr: avg, maxHr: maxHr)
    }

    // MARK: - Bornes d'origine

    /// Bornes d'origine d'une activité (ou d'une fusion), en secondes Unix.
    static func sourceSpan(_ members: [[FitMessage]]) -> Span? {
        let all = members.map { Member(messages: $0) }.flatMap(\.original)
        guard let lo = all.map(\.lo).min(), let hi = all.map(\.hi).max() else { return nil }
        let epoch = FitWellnessExtractor.fitEpochS
        return Span(start: lo + epoch, end: hi + epoch)
    }

    // MARK: - Calcul (§4)

    /// `principal` : le `.fit` de l'activité principale ; `others` : ceux des membres
    /// absorbés. `sport`/`subSport` : la modification de la principale (`nil` = celui
    /// du `.fit` de la principale). `nil` en sortie : aucun record gardé (fenêtre vide).
    static func compute(
        principal: [FitMessage], others: [[FitMessage]] = [], window: Window = .open,
        sport: String? = nil, subSport: String? = nil
    ) -> Result? {
        let epoch = FitWellnessExtractor.fitEpochS
        let win = (lo: (window.start ?? -.infinity) - epoch, hi: (window.end ?? .infinity) - epoch)

        var members = ([principal] + others).map { Member(messages: $0) }
        members.sort { ($0.original.first?.lo ?? .infinity) < ($1.original.first?.lo ?? .infinity) }
        for i in members.indices { members[i].kept = clip(members[i].original, to: win) }
        let active = members.filter { !$0.kept.isEmpty }
        guard let firstStart = active.first?.kept.first?.lo else { return nil }
        // Fenêtre vide : aucun record dans les intervalles gardés.
        guard active.contains(where: { m in m.recs.contains { r in m.kept.contains { $0.lo <= r.ts && r.ts <= $0.hi } } }) else {
            return nil
        }

        // Courbes (§4.8) : records gardés à la suite, `time` sans les trous entre membres.
        struct Kept { let rec: Rec; let time: Double }
        var keptRecords: [Kept] = []
        var offset = 0.0
        for m in active {
            let start = m.kept.first!.lo, end = m.kept.last!.hi
            for (i, _) in weighted(m.recs, in: m.kept) {
                keptRecords.append(Kept(rec: m.recs[i], time: m.recs[i].ts - start + offset))
            }
            offset += end - start
        }
        let sampled = FitActivityExtractor.downsample(keptRecords, max: FitActivityExtractor.maxStreamPoints)
        var track: [[Double]] = []
        var time: [Double?] = [], hr: [Double?] = [], speed: [Double?] = [], altitude: [Double?] = [], distance: [Double?] = []
        for item in sampled {
            let r = item.rec.msg
            if let lat = r.double(0), let lng = r.double(1) {
                track.append([lat * FitActivityExtractor.semicircleToDegree, lng * FitActivityExtractor.semicircleToDegree])
            }
            time.append(round3(item.time))
            hr.append(r.double(3))
            speed.append(r.double(73) ?? r.double(6))
            altitude.append(r.double(78) ?? r.double(2))
            distance.append(r.double(5))
        }

        // Résumé : durée, distance, FC, calories (§4.3-4.6).
        let duration = active.reduce(0) { $0 + $1.kept.reduce(0) { $0 + $1.length } }
        var distanceSum: Double?
        var calorieSum: Double?
        var hrSum = 0.0, hrTotal = 0.0, hrMax: Double?
        var plainHr: [Double] = []
        for m in active {
            let s = stats(m.recs, pieces: m.kept)
            if let d = s.distanceM { distanceSum = (distanceSum ?? 0) + d }
            if let c = sessionCalories(m.messages) {
                calorieSum = (calorieSum ?? 0) + c * calorieRatio(m)
            }
            for (i, dt) in weighted(m.recs, in: m.kept) {
                guard let h = m.recs[i].hr else { continue }
                hrSum += h * dt
                hrTotal += dt
                plainHr.append(h)
                hrMax = max(hrMax ?? h, h)
            }
        }
        var avgHr: Double?
        if hrTotal > 0 { avgHr = (hrSum / hrTotal).rounded() }
        else if !plainHr.isEmpty { avgHr = (plainHr.reduce(0, +) / Double(plainHr.count)).rounded() }

        // Sport : modification de la principale, sinon `.fit` de la principale.
        let principalSession = principal.first { $0.globalMessageNumber == FitProfile.mesgSession }
        let summary = FitActivityExtractor.Summary(
            sport: sport ?? principalSession?.double(5).map(FitProfile.sportName),
            subSport: sport != nil ? subSport : principalSession?.double(6).map(FitProfile.subSportName),
            startTime: FitActivityExtractor.isoDateTime(firstStart),
            durationS: round3(duration),
            distanceM: distanceSum.map(round2),
            calories: calorieSum?.rounded(),
            avgHr: avgHr,
            maxHr: hrMax)

        // Tours, séries, découpes (§4.9-4.10).
        var laps: [FitActivityExtractor.Lap] = []
        var sets: [FitActivityExtractor.SetRow] = []
        var splits: [FitActivityExtractor.Split] = []
        for m in active {
            laps += lapsKept(m)
            let setMsgs = m.messages.filter { msg in
                guard msg.globalMessageNumber == FitProfile.mesgSet else { return false }
                guard let start = msg.double(6) else { return true }
                return win.lo <= start && start <= win.hi
            }
            sets += FitActivityExtractor.extractSets(setMsgs)
            let splitMsgs = m.messages.filter { msg in
                guard msg.globalMessageNumber == FitProfile.mesgSplit, let start = msg.double(9) else {
                    return msg.globalMessageNumber == FitProfile.mesgSplit
                }
                let end = msg.double(27) ?? (start + (msg.double(1) ?? 0))
                return win.lo <= start && end <= win.hi
            }
            splits += FitActivityExtractor.extractSplits(splitMsgs)
        }
        laps = laps.enumerated().map { FitActivityExtractor.Lap(index: $0 + 1, durationS: $1.durationS, distanceM: $1.distanceM, avgHr: $1.avgHr, maxHr: $1.maxHr) }
        sets = sets.enumerated().map { FitActivityExtractor.SetRow(index: $0 + 1, durationS: $1.durationS, category: $1.category, repetitions: $1.repetitions) }
        splits = splits.enumerated().map {
            FitActivityExtractor.Split(
                index: $0 + 1, type: $1.type, durationS: $1.durationS, ascentM: $1.ascentM, descentM: $1.descentM,
                calories: $1.calories, avgVertSpeedMs: $1.avgVertSpeedMs)
        }

        let detail = FitActivityExtractor.Detail(
            track: track,
            streams: FitActivityExtractor.Streams(time: time, hr: hr, speed: speed, altitude: altitude, distance: distance),
            laps: laps, sets: sets, splits: splits, hrZones: hrZones(active))
        return Result(summary: summary, detail: detail)
    }

    // MARK: - Éléments du calcul

    private static func sessionCalories(_ messages: [FitMessage]) -> Double? {
        messages.first { $0.globalMessageNumber == FitProfile.mesgSession }?.double(11)
    }

    /// `ratio_k` (§4.6) : 1 si la fenêtre couvre tout `k`, sinon part des poids
    /// `w·dt` gardés ; sans aucune FC, rapport des durées actives.
    private static func calorieRatio(_ m: Member) -> Double {
        let originalLength = m.original.reduce(0) { $0 + $1.length }
        let keptLength = m.kept.reduce(0) { $0 + $1.length }
        if abs(keptLength - originalLength) < 1e-9 { return 1 }
        let byDuration = originalLength > 0 ? keptLength / originalLength : 0
        guard m.recs.contains(where: { $0.hr != nil }) else { return byDuration }
        func total(_ ivs: [Iv]) -> Double {
            weighted(m.recs, in: ivs).reduce(0) { $0 + weight(m.recs[$1.index].hr) * $1.dt }
        }
        let all = total(m.original)
        return all > 0 ? total(m.kept) / all : byDuration
    }

    /// Tour entièrement dans un intervalle gardé : repris tel quel ; à cheval :
    /// recalculé sur l'intersection ; hors des intervalles gardés : retiré.
    private static func lapsKept(_ m: Member) -> [FitActivityExtractor.Lap] {
        var out: [FitActivityExtractor.Lap] = []
        // Sans `startTime` : fin du tour précédent, sinon début du membre.
        var previousEnd = m.original.first?.lo
        for lapMsg in m.messages where lapMsg.globalMessageNumber == FitProfile.mesgLap {
            defer { previousEnd = lapMsg.double(253) ?? previousEnd }
            guard let hi = lapMsg.double(253), let lo = lapMsg.double(2) ?? previousEnd else {
                out += FitActivityExtractor.extractLaps([lapMsg])
                continue
            }
            if m.kept.contains(where: { $0.lo <= lo && hi <= $0.hi }) {
                out += FitActivityExtractor.extractLaps([lapMsg])
                continue
            }
            let pieces = clip(m.kept, to: (lo, hi))
            guard !pieces.isEmpty else { continue }
            let s = stats(m.recs, pieces: pieces)
            out.append(FitActivityExtractor.Lap(index: 0, durationS: s.durationS, distanceM: s.distanceM, avgHr: s.avgHr, maxHr: s.maxHr))
        }
        return out
    }

    /// Zones FC (§4.7) : bornes du `time_in_zone` de session (sinon de tour) du premier
    /// membre qui en a, non vides ; nombre de zones = `timeInHrZone.count − 1` ; FC ≤
    /// `bounds[0]` dans aucune zone ; borne absente = +∞ ; au-delà de la dernière borne,
    /// dernière zone.
    private static func hrZones(_ members: [Member]) -> [FitActivityExtractor.HrZoneRow] {
        var count = 0, bounds: [Double] = []
        for m in members {
            let all = m.messages.filter { $0.globalMessageNumber == FitProfile.mesgTimeInZone }
            let zone = [FitProfile.mesgSession, FitProfile.mesgLap].lazy
                .compactMap { ref in all.first { $0.double(0) == Double(ref) && !$0.numberList(6).isEmpty } }.first
            if let zone {
                count = zone.numberList(2).count
                bounds = zone.numberList(6)
                break
            }
        }
        guard count > 1 else { return [] }
        var seconds = [Double](repeating: 0, count: count)
        for m in members {
            for (i, dt) in weighted(m.recs, in: m.kept) {
                guard let hr = m.recs[i].hr, hr > bounds[0] else { continue }
                var zone = count - 1
                for z in 1..<count where hr <= (bounds.indices.contains(z) ? bounds[z] : .infinity) {
                    zone = z
                    break
                }
                seconds[zone] += dt
            }
        }
        var out: [FitActivityExtractor.HrZoneRow] = []
        for i in 1..<count {
            out.append(FitActivityExtractor.HrZoneRow(
                zone: i, seconds: (seconds[i] * 10).rounded() / 10,
                fromBpm: bounds.indices.contains(i - 1) ? bounds[i - 1] : nil,
                toBpm: bounds.indices.contains(i) ? bounds[i] : nil))
        }
        while let last = out.last, last.seconds == 0, last.toBpm == nil { out.removeLast() }
        return out
    }
}
