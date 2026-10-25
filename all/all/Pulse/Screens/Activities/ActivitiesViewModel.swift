//
//  ActivitiesViewModel.swift
//  all (bridge-connect)
//
//  État de la liste `ActivitiesView` — `GET api/activities`. Même esprit que
//  `ActivitiesComponent.refresh()` (Angular) mais sans le split desktop ni
//  l'upload `.fit` (hors périmètre de cet écran) : la limite haute (500)
//  reprend celle du front, le regroupement par jour se fait côté vue.
//

import Foundation
import Observation

@MainActor
@Observable
final class ActivitiesViewModel {
    enum State {
        case loading
        case loaded([Activity])
        case failed(String)
    }

    private(set) var state: State = .loading
    /// Pour animer le fondu loading → contenu (la vue ne compare pas `State`).
    var stateTag: Int {
        switch state {
        case .loading: return 0
        case .loaded: return 1
        case .failed: return 2
        }
    }
    private let client: PulseAPIClient
    /// Fusionne les rechargements (synchro, changement de source, pull-to-refresh)
    /// — cf. `ReloadGate`.
    private let gate = ReloadGate()

    init(client: PulseAPIClient = .shared) {
        self.client = client
    }

    /// Rechargement fusionné : un déclencheur pendant un rechargement en cours
    /// le rejoint au lieu de relancer la requête. `trailing` : la donnée vient
    /// de changer (synchro, changement de source) — un seul rechargement est
    /// rejoué après le courant.
    func reload(trailing: Bool = false) async {
        await gate.run(trailing: trailing) { [self] in await self.load() }
    }

    /// Garde la liste affichée pendant le rechargement (plein écran de
    /// chargement seulement tant qu'il n'y a rien) ; un échec ne la vide pas
    /// (pas de bandeau d'erreur sur cet écran : on garde simplement la liste).
    func load() async {
        if case .loaded = state {} else { state = .loading }
        let query = ["limit": "500"]
        if case .loading = state, let stale: ActivityListResponse = await client.cachedValue("api/activities", query: query),
           case .loading = state {
            state = .loaded(stale.items)
        }
        do {
            let response: ActivityListResponse = try await client.getCached("api/activities", query: query)
            state = .loaded(response.items)
        } catch {
            if case .loaded = state {} else { state = .failed(error.localizedDescription) }
        }
    }

    // MARK: - Sélection et fusion

    private(set) var isSelecting = false
    private(set) var selected: Set<Int> = []
    private(set) var isMerging = false
    /// Erreur de fusion (400 chevauchement…) ; la sélection est conservée.
    var mergeError: String?
    /// Incrémenté à chaque fusion réussie (haptique de succès).
    private(set) var mergeSuccessCount = 0

    /// Écart maximal entre la fin d'une activité et le début de la suivante
    /// pour proposer « Fusionner avec la suivante ».
    static let nextMergeMaxGap: TimeInterval = 30 * 60

    var activities: [Activity] {
        if case .loaded(let items) = state { return items }
        return []
    }

    func startSelecting() { isSelecting = true; selected = []; mergeError = nil }
    func cancelSelecting() { isSelecting = false; selected = []; mergeError = nil }

    func toggle(_ id: Int) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// ≥ 2 activités sélectionnées, toutes du même sport.
    var canMerge: Bool {
        let chosen = activities.filter { selected.contains($0.id) }
        guard chosen.count >= 2, !isMerging else { return false }
        return Set(chosen.map { $0.sport ?? "" }).count == 1
    }

    var selectedCount: Int { selected.count }

    /// Fusionne la sélection. Succès : sortie du mode sélection + rechargement ;
    /// échec : message, sélection conservée.
    @discardableResult
    func mergeSelected() async -> Bool {
        guard canMerge else { return false }
        return await performMerge(ids: Array(selected))
    }

    /// Activité chronologiquement suivante, si elle est du même sport et commence
    /// entre 0 et 30 min après la fin de `activity` (fin = début + durée).
    func nextMergeCandidate(after activity: Activity) -> Activity? {
        guard let start = ActivityDateFormatting.date(from: activity.startTime) else { return nil }
        var next: (activity: Activity, start: Date)?
        for other in activities where other.id != activity.id {
            guard let s = ActivityDateFormatting.date(from: other.startTime), s > start else { continue }
            if next == nil || s < next!.start { next = (other, s) }
        }
        guard let next, next.activity.sport == activity.sport else { return nil }
        let end = start.addingTimeInterval(activity.durationS ?? 0)
        let gap = next.start.timeIntervalSince(end)
        return gap >= 0 && gap < Self.nextMergeMaxGap ? next.activity : nil
    }

    @discardableResult
    func mergeWithNext(_ activity: Activity) async -> Bool {
        guard !isMerging, let next = nextMergeCandidate(after: activity) else { return false }
        return await performMerge(ids: [activity.id, next.id])
    }

    private func performMerge(ids: [Int]) async -> Bool {
        isMerging = true
        mergeError = nil
        defer { isMerging = false }
        do {
            _ = try await client.mergeActivities(ids: ids)
        } catch {
            mergeError = ActivityEditErrors.message(error)
            return false
        }
        mergeSuccessCount += 1
        isSelecting = false
        selected = []
        await load()
        return true
    }
}
