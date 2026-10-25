//
//  ActivityEditViewModel.swift
//  all (bridge-connect)
//
//  Logique de la feuille « Modifier » (`ActivityEditSheet`) : valeurs éditées,
//  patch minimal (seuls les champs changés partent), bornes de dates, aperçu de
//  la courbe de FC et appels `editActivity` / `resetActivityEdit`. Contrat :
//  `custom-connect/docs/activity-edits-contract.md` §5.
//

import Foundation
import Observation

/// Message lisible d'une erreur d'écriture (400 : le serveur explique, on relaie).
enum ActivityEditErrors {
    static func message(_ error: Error) -> String {
        if case PulseAPIError.http(let status, let body) = error {
            if let body,
               let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if let text = object["message"] as? String, !text.isEmpty { return text }
                if let list = object["message"] as? [String], let first = list.first { return first }
            }
            switch status {
            case 400: return "Modification refusée : bornes, sport ou chevauchement invalides."
            case 404: return "Activité introuvable."
            default: break
            }
        }
        return error.localizedDescription
    }
}

/// Point de la courbe d'aperçu, `time` en secondes depuis le début affiché.
struct ActivityPreviewPoint: Equatable {
    let time: Double
    let bpm: Double
}

@MainActor
@Observable
final class ActivityEditViewModel {
    static let maxName = 80
    static let maxNote = 2000

    let detail: ActivityDetail
    var name: String { didSet { if name.count > Self.maxName { name = String(name.prefix(Self.maxName)) } } }
    var note: String { didSet { if note.count > Self.maxNote { note = String(note.prefix(Self.maxNote)) } } }
    var sport: String
    var start: Date
    var end: Date
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let client: PulseAPIClient
    private let initialStart: Date
    private let initialEnd: Date

    init(detail: ActivityDetail, client: PulseAPIClient = .shared) {
        self.detail = detail
        self.client = client
        name = detail.name ?? ""
        note = detail.note ?? ""
        sport = detail.sport ?? "generic"
        let source = detail.source
        let s = ActivityDateFormatting.date(from: detail.edit?.startAt ?? source?.startTime ?? detail.startTime) ?? Date()
        let fallbackEnd = s.addingTimeInterval(detail.durationS ?? 60)
        let e = ActivityDateFormatting.date(from: detail.edit?.endAt ?? source?.endTime) ?? fallbackEnd
        initialStart = s
        initialEnd = e
        start = s
        end = e
    }

    // MARK: Lecture

    var isMerged: Bool { (detail.mergedCount ?? 0) > 0 }

    /// Libellé du sport affiché, pour le placeholder du nom.
    var currentLabel: String { ActivitySport.label(sport: detail.sport, subSport: detail.subSport) }

    /// Sports connus, plus le sport courant s'il n'y figure pas.
    var sportOptions: [String] {
        var list = ActivitySport.editable
        if !list.contains(sport) { list.insert(sport, at: 0) }
        if let original = detail.sport, !list.contains(original) { list.insert(original, at: 0) }
        return list
    }

    /// Nom, note ou fenêtre posés : de quoi proposer « Rétablir l'original ».
    var canReset: Bool {
        detail.edited == true
            || !(detail.name ?? "").isEmpty
            || !(detail.note ?? "").isEmpty
    }

    // MARK: Bornes

    var sourceRange: ClosedRange<Date>? {
        guard let source = detail.source,
              let lo = ActivityDateFormatting.date(from: source.startTime),
              let hi = ActivityDateFormatting.date(from: source.endTime), lo < hi else { return nil }
        return min(lo, initialStart)...max(hi, initialEnd)
    }

    /// Début : de l'origine jusqu'à une minute avant la fin.
    var startRange: ClosedRange<Date> {
        let lo = sourceRange?.lowerBound ?? .distantPast
        let hi = max(lo, end.addingTimeInterval(-60))
        return lo...hi
    }

    /// Fin : une minute après le début, jusqu'à la fin d'origine.
    var endRange: ClosedRange<Date> {
        let hi = sourceRange?.upperBound ?? .distantFuture
        let lo = min(hi, start.addingTimeInterval(60))
        return lo...hi
    }

    // MARK: Patch

    var patch: ActivityEditPatch {
        var p = ActivityEditPatch()
        if abs(start.timeIntervalSince(initialStart)) >= 1 {
            p.startAt = .set(ActivityEditTime.format(start.timeIntervalSince1970))
        }
        if abs(end.timeIntervalSince(initialEnd)) >= 1 {
            p.endAt = .set(ActivityEditTime.format(end.timeIntervalSince1970))
        }
        if sport != (detail.sport ?? "generic") {
            p.sport = .set(sport)
        }
        p.name = Self.textChange(new: name, old: detail.name)
        p.note = Self.textChange(new: note, old: detail.note)
        return p
    }

    private static func textChange(new: String, old: String?) -> ActivityEditValue<String> {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = (old ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if n == o { return .unchanged }
        return n.isEmpty ? .clear : .set(n)
    }

    var hasChanges: Bool { patch != ActivityEditPatch() }
    var isValid: Bool { end > start }
    var canSave: Bool { hasChanges && isValid && !isSaving }

    // MARK: Actions

    /// Envoie les champs modifiés. `nil` + `errorMessage` en cas d'échec.
    func save() async -> ActivityDetail? {
        guard canSave else { return nil }
        return await run { [client, detail, patch] in try await client.editActivity(id: detail.id, patch) }
    }

    func resetOriginal() async -> ActivityDetail? {
        guard !isSaving else { return nil }
        return await run { [client, detail] in try await client.resetActivityEdit(id: detail.id) }
    }

    private func run(_ call: () async throws -> ActivityDetail) async -> ActivityDetail? {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            return try await call()
        } catch {
            errorMessage = ActivityEditErrors.message(error)
            return nil
        }
    }

    // MARK: Aperçu

    /// Courbe de FC (activité non fusionnée avec flux de FC seulement).
    var previewPoints: [ActivityPreviewPoint] {
        guard !isMerged, let streams = detail.streams else { return [] }
        var out: [ActivityPreviewPoint] = []
        for (index, value) in streams.hr.enumerated() {
            guard let value else { continue }
            let t = streams.time.indices.contains(index) ? (streams.time[index] ?? Double(index)) : Double(index)
            out.append(ActivityPreviewPoint(time: t, bpm: value))
        }
        return out
    }

    /// Fenêtre gardée, en secondes depuis le début de l'activité affichée.
    var keptWindow: ClosedRange<Double>? {
        guard let displayed = ActivityDateFormatting.date(from: detail.startTime), end > start else { return nil }
        return start.timeIntervalSince(displayed)...end.timeIntervalSince(displayed)
    }
}
