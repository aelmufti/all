//
//  ActivityEditMaterializer.swift
//  all (bridge-connect)
//
//  Matérialisation des modifications d'activités — contrat
//  `custom-connect/docs/activity-edits-contract.md` §2 (la ligne `activities` et les
//  tables dérivées reflètent toujours les modifications, donc stats, santé, carte,
//  programme… n'ont rien à savoir), §3 (résolution d'une principale) et §6 (ordre
//  d'arrivée : une modification peut précéder son `.fit`, elle s'applique à l'arrivée).
//
//  Idempotent : rejouer `rematerialize` sur les mêmes données donne le même état. N'ouvre
//  AUCUNE transaction (l'appelant en tient une — ingestion, route d'écriture ou
//  application d'une réponse de synchro, qui n'admet pas de transaction imbriquée).
//
//  Pas de table de détail locale : le détail est décodé à la volée
//  (`RealLocalPulseBackend.encodeActivityDetail`) ; ici on matérialise le RÉSUMÉ
//  (`activities`) et les zones FC (`activity_zones`, remplies pour les seules activités
//  modifiées, comme `activity_zones` côté serveur).
//

import Foundation

final class ActivityEditMaterializer {
    struct Outcome: Equatable {
        /// Une fenêtre ne laisse aucun record (§4 : refusée à l'écriture, ignorée à la
        /// réception d'une synchro).
        var emptyWindowFor: [String] = []
        var isEmptyWindow: Bool { !emptyWindowFor.isEmpty }
    }

    private let db: LocalDb
    private let locator: ActivityFitLocator
    /// Plus ancienne date (`yyyy-MM-dd`, UTC) d'une activité écrite ou déplacée.
    private var earliestDate: String?

    init(db: LocalDb, locator: ActivityFitLocator) {
        self.db = db
        self.locator = locator
    }

    /// §6 : rejoue la matérialisation de chaque hash de `hashes`, de sa principale et
    /// des membres qui la désignent. `previousRoots` : principales d'avant une
    /// modification de `merged_into` (elles doivent se recalculer sans le membre parti).
    /// Invalide la Body Battery à partir de la plus ancienne date touchée.
    @discardableResult
    func rematerialize(hashes: [String], previousRoots: [String] = []) throws -> Outcome {
        let graph = ActivityEditGraph(try db.allActivityEdits())
        var outcome = Outcome()

        // Activités absorbées dont la principale n'existe plus (ou plus de lien) :
        // rétablies (même id), puis recalculées comme n'importe quelle racine.
        var restored: [String] = []
        for hash in try db.mergedActivityHashes() {
            let root = graph.root(of: hash)
            let principalPresent = try db.storedActivity(hash: root) != nil
            if root == hash || !principalPresent {
                try db.restoreActivity(hash: hash)
                if let row = try db.storedActivity(hash: hash) { touch(row.startTime) }
                restored.append(hash)
            }
        }

        var roots: [String] = []
        for hash in hashes + previousRoots + restored {
            let root = graph.root(of: hash)
            if !roots.contains(root) { roots.append(root) }
        }
        for root in roots {
            let members = graph.members(of: root)
            guard let principal = try db.storedActivity(hash: root) else {
                // Principale absente : les membres restent des activités autonomes.
                for member in members { try materialize(hash: member, absorbed: [], outcome: &outcome) }
                continue
            }
            var absorbed: [String] = []
            for member in members {
                if let row = try db.storedActivity(hash: member) {
                    touch(row.startTime)
                    try db.absorbActivity(row, into: principal.id)
                    absorbed.append(member)
                } else if (try db.mergedActivity(hash: member)) != nil {
                    absorbed.append(member)
                }
            }
            try materialize(hash: root, absorbed: absorbed, outcome: &outcome)
        }
        try db.invalidateBodyBatteryFrom(date: earliestDate)
        earliestDate = nil
        return outcome
    }

    // MARK: - Une activité

    private func touch(_ startTime: String?) {
        guard let day = startTime.map({ String($0.prefix(10)) }), day.count == 10 else { return }
        if earliestDate == nil || day < earliestDate! { earliestDate = day }
    }

    /// Recalcule la ligne active de `hash` avec ses membres absorbés (`absorbed`).
    private func materialize(hash: String, absorbed: [String], outcome: inout Outcome) throws {
        guard let row = try db.storedActivity(hash: hash) else { return }
        let edit = try db.activityEdit(hash: hash)
        let edited = (edit?.hasWindow ?? false) || edit?.sport != nil || !absorbed.isEmpty
        let sport: (String?, String?)? = edit?.sport.map { ($0, edit?.subSport) }
        let needsCompute = (edit?.hasWindow ?? false) || !absorbed.isEmpty
        let wasModified = row.edited || row.mergedCount > 0

        // Rien à appliquer ni à défaire (cas de toute ingestion ordinaire) : on ne touche à rien.
        if edit == nil && absorbed.isEmpty && !wasModified && row.name == nil && row.note == nil { return }
        // Sans fenêtre ni fusion et sans état modifié à défaire : étiquettes seulement.
        if !needsCompute && !wasModified {
            let sportSame = sport.map { row.sport == $0.0 && row.subSport == $0.1 } ?? true
            let unchanged = row.name == edit?.name && row.note == edit?.note && row.edited == edited && sportSame
            if unchanged { return }
            touch(row.startTime)
            try db.writeActivityLabels(id: row.id, sport: sport, name: edit?.name, note: edit?.note, edited: edited, mergedCount: 0)
            return
        }
        let principal = locator.messages(hash: hash)
        guard let principal else {
            // `.fit` absent : on ne sait que poser les étiquettes ; la fenêtre attend l'arrivée du fichier.
            touch(row.startTime)
            try db.writeActivityLabels(
                id: row.id, sport: sport, name: edit?.name, note: edit?.note, edited: edited, mergedCount: absorbed.count)
            return
        }
        if needsCompute {
            let others = absorbed.compactMap { locator.messages(hash: $0) }
            var computed = FitActivityEdit.compute(
                principal: principal, others: others, window: edit?.window ?? .open,
                sport: edit?.sport, subSport: edit?.subSport)
            if computed == nil {
                // Fenêtre vide : signalée, et le calcul retombe sur l'origine (fusion sans la fenêtre).
                outcome.emptyWindowFor.append(hash)
                computed = FitActivityEdit.compute(principal: principal, others: others, sport: edit?.sport, subSport: edit?.subSport)
            }
            guard let result = computed else { return }
            touch(row.startTime)
            touch(result.summary.startTime)
            try db.writeActivitySummary(
                id: row.id, result.summary, name: edit?.name, note: edit?.note, edited: edited, mergedCount: absorbed.count)
            try db.replaceActivityZones(id: row.id, result.detail.hrZones)
        } else {
            // Retour à l'origine : résumé d'origine recalculé depuis le `.fit`.
            var summary = FitActivityExtractor.extractSummary(messages: principal)
            if let edit, let s = edit.sport { summary = FitActivityExtractor.Summary(
                sport: s, subSport: edit.subSport, startTime: summary.startTime, durationS: summary.durationS,
                distanceM: summary.distanceM, calories: summary.calories, avgHr: summary.avgHr, maxHr: summary.maxHr) }
            touch(row.startTime)
            touch(summary.startTime)
            try db.writeActivitySummary(id: row.id, summary, name: edit?.name, note: edit?.note, edited: edited, mergedCount: 0)
            try db.replaceActivityZones(id: row.id, [])
        }
    }
}
