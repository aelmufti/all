//
//  ActivityEditService.swift
//  all (bridge-connect)
//
//  Routes d'écriture de la modification et de la fusion d'activités du backend local —
//  contrat `custom-connect/docs/activity-edits-contract.md` §5 : `PUT`/`DELETE
//  activities/:id/edit`, `POST activities/merge`, `POST activities/:id/split`. Valide,
//  écrit `activity_edits` puis rejoue la matérialisation (`ActivityEditMaterializer`),
//  le tout dans une transaction : une erreur ne laisse rien.
//
//  Erreurs : `LocalActivityNotFoundError` (404) et `LocalActivityEditValidationError` (400),
//  les formes de `LocalActivityNotFoundError` / `LocalWeightValidationError` des autres routes.
//

import Foundation

/// `400` des routes de modification d'activité — miroir du `BadRequestException` côté Nest.
struct LocalActivityEditValidationError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

final class ActivityEditService {
    static let maxSportLength = 40
    static let maxNameLength = 80
    static let maxNoteLength = 2000

    private let db: LocalDb
    private let locator: ActivityFitLocator

    init(db: LocalDb, locator: ActivityFitLocator) {
        self.db = db
        self.locator = locator
    }

    // MARK: - Corps de `PUT`

    private enum Field {
        case absent
        case null
        case value(String)
    }

    private static func field(_ object: [String: Any], _ key: String) throws -> Field {
        guard let raw = object[key] else { return .absent }
        if raw is NSNull { return .null }
        guard let s = raw as? String else { throw LocalActivityEditValidationError(reason: "\(key) invalide") }
        return .value(s)
    }

    /// Valide les champs de `PUT` (§5) sur une copie de la modification courante.
    /// Les bornes d'une même modification (`start < end`) sont vérifiées ici ; les
    /// bornes d'origine et la fenêtre vide, par `validateWindow`.
    static func apply(body: Data?, to current: ActivityEdit) throws -> ActivityEdit {
        guard let body, !body.isEmpty,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw LocalActivityEditValidationError(reason: "Corps invalide")
        }
        var edit = current
        func time(_ key: String) throws -> String?? {
            switch try field(object, key) {
            case .absent: return .none
            case .null: return .some(nil)
            case .value(let s):
                guard let unix = ActivityEditTime.parse(s) else { throw LocalActivityEditValidationError(reason: "\(key) invalide") }
                return .some(ActivityEditTime.format(unix))
            }
        }
        if let v = try time("startAt") { edit.startAt = v }
        if let v = try time("endAt") { edit.endAt = v }
        if let s = edit.startAt.flatMap(ActivityEditTime.parse), let e = edit.endAt.flatMap(ActivityEditTime.parse), s >= e {
            throw LocalActivityEditValidationError(reason: "startAt doit précéder endAt")
        }

        func label(_ s: String, _ key: String, max: Int) throws -> String? {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= max else { throw LocalActivityEditValidationError(reason: "\(key) trop long") }
            return trimmed.isEmpty ? nil : trimmed
        }
        func sportName(_ s: String, _ key: String) throws -> String {
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.count <= maxSportLength else {
                throw LocalActivityEditValidationError(reason: "\(key) invalide")
            }
            return trimmed
        }
        let sport = try field(object, "sport"), sub = try field(object, "subSport")
        switch sport {
        case .null:
            edit.sport = nil
            edit.subSport = nil
        case .value(let s):
            edit.sport = try sportName(s, "sport")
            // Pris avec le sport : un sous-sport absent ou nul s'efface.
            switch sub {
            case .value(let v): edit.subSport = try sportName(v, "subSport")
            case .absent, .null: edit.subSport = nil
            }
        case .absent:
            switch sub {
            case .value(let v):
                guard edit.sport != nil else { throw LocalActivityEditValidationError(reason: "subSport sans sport") }
                edit.subSport = try sportName(v, "subSport")
            case .null: edit.subSport = nil
            case .absent: break
            }
        }
        switch try field(object, "name") {
        case .absent: break
        case .null: edit.name = nil
        case .value(let s): edit.name = try label(s, "name", max: maxNameLength)
        }
        switch try field(object, "note") {
        case .absent: break
        case .null: edit.note = nil
        case .value(let s): edit.note = try label(s, "note", max: maxNoteLength)
        }
        return edit
    }

    // MARK: - Aides

    /// Inconnu → 404 ; absorbé par une fusion → 400.
    private func requireActivity(id: Int) throws -> StoredActivity {
        guard let row = try db.storedActivity(id: id) else {
            if try db.mergedActivity(id: id) != nil { throw LocalActivityEditValidationError(reason: "Activité déjà fusionnée (\(id))") }
            throw LocalActivityNotFoundError(idString: String(id))
        }
        return row
    }

    /// Hashes de la principale et de ses membres absorbés.
    func memberHashes(of hash: String) throws -> [String] {
        let graph = ActivityEditGraph(try db.allActivityEdits())
        return [hash] + graph.members(of: hash)
    }

    /// Bornes d'origine de la principale + membres dont le `.fit` est présent.
    func sourceSpan(of hash: String) throws -> FitActivityEdit.Span? {
        let messages = try memberHashes(of: hash).compactMap { locator.messages(hash: $0) }
        return FitActivityEdit.sourceSpan(messages)
    }

    /// §5 : bornes dans l'activité d'origine, fenêtre non vide. Sans `.fit` (principale
    /// absente), rien à contrôler : la fenêtre attend le fichier.
    func validateWindow(_ edit: ActivityEdit, checkEmpty: Bool = true) throws {
        guard edit.hasWindow, let principal = locator.messages(hash: edit.fileHash) else { return }
        let hashes = try memberHashes(of: edit.fileHash).dropFirst()
        let others = hashes.compactMap { locator.messages(hash: $0) }
        if let span = FitActivityEdit.sourceSpan([principal] + others) {
            let tolerance = 1e-6
            if let s = edit.startAt.flatMap(ActivityEditTime.parse), s < span.start - tolerance || s > span.end + tolerance {
                throw LocalActivityEditValidationError(reason: "startAt hors de l'activité")
            }
            if let e = edit.endAt.flatMap(ActivityEditTime.parse), e < span.start - tolerance || e > span.end + tolerance {
                throw LocalActivityEditValidationError(reason: "endAt hors de l'activité")
            }
        }
        guard !checkEmpty || FitActivityEdit.compute(principal: principal, others: others, window: edit.window) != nil else {
            throw LocalActivityEditValidationError(reason: "Fenêtre vide")
        }
    }

    private func commit(hashes: [String], previousRoots: [String] = [], write: () throws -> Void) throws {
        try db.db.transaction {
            try write()
            let outcome = try ActivityEditMaterializer(db: db, locator: locator).rematerialize(hashes: hashes, previousRoots: previousRoots)
            if outcome.isEmptyWindow { throw LocalActivityEditValidationError(reason: "Fenêtre vide") }
        }
    }

    // MARK: - Routes

    /// `PUT activities/:id/edit`.
    func update(id: Int, body: Data?) throws {
        let row = try requireActivity(id: id)
        let edit = try Self.apply(body: body, to: try db.activityEdit(hash: row.fileHash) ?? ActivityEdit(fileHash: row.fileHash))
        try validateWindow(edit)
        try commit(hashes: [row.fileHash]) { try db.saveActivityEdit(edit) }
    }

    /// `DELETE activities/:id/edit` : retire fenêtre, sport, nom, note (garde la fusion).
    func clear(id: Int) throws {
        let row = try requireActivity(id: id)
        guard var edit = try db.activityEdit(hash: row.fileHash) else { return }
        edit.startAt = nil
        edit.endAt = nil
        edit.sport = nil
        edit.subSport = nil
        edit.name = nil
        edit.note = nil
        try commit(hashes: [row.fileHash]) { try db.saveActivityEdit(edit) }
    }

    /// `POST activities/merge` : renvoie l'id de la principale (la plus ancienne).
    func merge(body: Data?) throws -> Int {
        guard let body, let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let raw = object["ids"] as? [Any], raw.allSatisfy({ $0 is Int || $0 is Double }) else {
            throw LocalActivityEditValidationError(reason: "ids invalide")
        }
        var ids: [Int] = []
        for value in raw {
            let id = (value as? Int) ?? Int(value as? Double ?? -1)
            if !ids.contains(id) { ids.append(id) }
        }
        guard ids.count >= 2 else { throw LocalActivityEditValidationError(reason: "Au moins deux activités") }

        // 404 (inconnu) avant 400 (absorbé).
        var rows: [StoredActivity] = []
        var absorbedId: Int?
        for id in ids {
            if let row = try db.storedActivity(id: id) { rows.append(row) }
            else if (try db.mergedActivity(id: id)) != nil { absorbedId = absorbedId ?? id }
            else { throw LocalActivityNotFoundError(idString: String(id)) }
        }
        if let absorbedId { throw LocalActivityEditValidationError(reason: "Activité déjà fusionnée (\(absorbedId))") }
        guard Set(rows.map(\.sport)).count == 1 else { throw LocalActivityEditValidationError(reason: "Sports différents") }

        // Segments d'origine (un par `.fit`, membres déjà absorbés compris) ; sans `.fit`,
        // début et durée du résumé. Chevauchement testé segment par segment.
        struct Segment { let start: Double; let end: Double }
        var segments: [Segment] = []
        for row in rows {
            var found = false
            for hash in try memberHashes(of: row.fileHash) {
                if let messages = locator.messages(hash: hash), let span = FitActivityEdit.sourceSpan([messages]) {
                    segments.append(Segment(start: span.start, end: span.end))
                    found = true
                }
            }
            if !found {
                guard let start = row.startTime.flatMap(ActivityEditTime.parse) else {
                    throw LocalActivityEditValidationError(reason: "Début inconnu (\(row.id))")
                }
                segments.append(Segment(start: start, end: start + (row.durationS ?? 0)))
            }
        }
        segments.sort { $0.start < $1.start }
        for (a, b) in zip(segments, segments.dropFirst()) where b.start < a.end {
            throw LocalActivityEditValidationError(reason: "Activités qui se chevauchent")
        }

        // Principale : début effectif le plus ancien, puis id le plus petit.
        let ordered = rows.sorted {
            (($0.startTime.flatMap(ActivityEditTime.parse) ?? .infinity), $0.id) < (($1.startTime.flatMap(ActivityEditTime.parse) ?? .infinity), $1.id)
        }
        let principal = ordered[0]
        let others = Array(ordered.dropFirst())
        try commit(hashes: [principal.fileHash] + others.map(\.fileHash)) {
            for other in others {
                var edit = try db.activityEdit(hash: other.fileHash) ?? ActivityEdit(fileHash: other.fileHash)
                edit.mergedInto = principal.fileHash
                try db.saveActivityEdit(edit)
            }
        }
        return principal.id
    }

    /// `POST activities/:id/split` : rétablit les originales ; renvoie les ids (principale
    /// d'abord, puis les membres par heure de début).
    func split(id: Int) throws -> [Int] {
        let row = try requireActivity(id: id)
        let graph = ActivityEditGraph(try db.allActivityEdits())
        let members = graph.members(of: row.fileHash)
        guard !members.isEmpty else { throw LocalActivityEditValidationError(reason: "Activité non fusionnée") }
        try commit(hashes: [row.fileHash] + members) {
            for member in members {
                guard var edit = try db.activityEdit(hash: member) else { continue }
                edit.mergedInto = nil
                try db.saveActivityEdit(edit)
            }
        }
        var restored: [StoredActivity] = []
        for member in members { if let r = try db.storedActivity(hash: member) { restored.append(r) } }
        restored.sort { $0.id < $1.id }
        return [id] + restored.map(\.id)
    }

    // MARK: - Détail (`GET activities/:id`)

    struct MemberInfo {
        let id: Int
        let startTime: String?
        let durationS: Double?
    }

    /// Tout ce que le détail sert en plus du résumé (§5, réponses enrichies).
    struct DetailBundle {
        let row: StoredActivity
        /// `nil` : `.fit` introuvable (résumé seul, comme avant).
        let detail: FitActivityExtractor.Detail?
        /// Bornes d'origine, tous membres confondus ; `nil` sans `.fit`.
        let source: FitActivityEdit.Span?
        let edit: ActivityEdit?
        let members: [MemberInfo]
    }

    /// Un `.fit` illisible de la principale lève (comme avant : l'écran affiche l'erreur).
    func detail(id: Int) throws -> DetailBundle {
        let row = try requireActivity(id: id)
        let edit = try db.activityEdit(hash: row.fileHash)
        let graph = ActivityEditGraph(try db.allActivityEdits())
        var absorbed: [StoredActivity] = []
        for hash in graph.members(of: row.fileHash) {
            if let r = try db.mergedActivity(hash: hash) { absorbed.append(r) }
        }
        guard let url = locator.url(hash: row.fileHash) else {
            // Sans `.fit`, les bornes retombent sur `start_time` + `duration_s` de la ligne.
            var fallback: FitActivityEdit.Span?
            if let start = row.startTime.flatMap(ActivityEditTime.parse) {
                fallback = FitActivityEdit.Span(start: start, end: start + (row.durationS ?? 0))
            }
            return DetailBundle(row: row, detail: nil, source: fallback, edit: edit, members: members(row, nil, absorbed))
        }
        let principal = try FitDecoder.decode(Data(contentsOf: url)).messages
        let others = absorbed.compactMap { locator.messages(hash: $0.fileHash) }
        let source = FitActivityEdit.sourceSpan([principal] + others)
        var detail: FitActivityExtractor.Detail?
        if (edit?.hasWindow ?? false) || !absorbed.isEmpty {
            detail = FitActivityEdit.compute(principal: principal, others: others, window: edit?.window ?? .open)?.detail
        }
        return DetailBundle(
            row: row, detail: detail ?? FitActivityExtractor.extractDetail(messages: principal), source: source, edit: edit,
            members: members(row, principal, absorbed))
    }

    /// Principale + absorbées, par heure de début d'origine ; vide hors fusion.
    private func members(_ row: StoredActivity, _ principal: [FitMessage]?, _ absorbed: [StoredActivity]) -> [MemberInfo] {
        guard !absorbed.isEmpty else { return [] }
        let own = principal.map(FitActivityExtractor.extractSummary(messages:))
        var out = [MemberInfo(id: row.id, startTime: own?.startTime ?? row.startTime, durationS: own?.durationS ?? row.durationS)]
        out += absorbed.map { MemberInfo(id: $0.id, startTime: $0.startTime, durationS: $0.durationS) }
        return out.sorted { ($0.startTime ?? "", $0.id) < ($1.startTime ?? "", $1.id) }
    }
}
