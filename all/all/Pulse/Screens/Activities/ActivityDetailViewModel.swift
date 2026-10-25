//
//  ActivityDetailViewModel.swift
//  all (bridge-connect)
//
//  État du détail `ActivityDetailView` — `GET api/activities/:id`. Même
//  esprit que `ActivityDetailComponent.fetch()` (Angular), sans la carte
//  Leaflet ni la suppression (hors périmètre de cet écran).
//

import Foundation
import Observation

@MainActor
@Observable
final class ActivityDetailViewModel {
    enum State {
        case loading
        case loaded(ActivityDetail)
        case failed(String)
    }

    private(set) var state: State = .loading
    private let client: PulseAPIClient
    private let activityId: Int
    /// Prévient la liste qu'une écriture a réussi (elle se recharge).
    private let onChanged: @MainActor () -> Void

    /// Séparation en cours / dernière erreur d'action (fusion annulée).
    private(set) var isWorking = false
    private(set) var actionError: String?
    /// Posé après une séparation réussie : l'activité affichée n'existe plus
    /// sous cette forme, la vue revient à la liste.
    private(set) var didSplit = false
    /// Incrémenté à chaque écriture réussie (haptique de succès).
    private(set) var successCount = 0

    init(activityId: Int, client: PulseAPIClient = .shared, onChanged: @escaping @MainActor () -> Void = {}) {
        self.activityId = activityId
        self.client = client
        self.onChanged = onChanged
    }

    /// Remplace le détail affiché par la réponse d'une écriture (feuille « Modifier »).
    func apply(_ detail: ActivityDetail) {
        state = .loaded(detail)
        actionError = nil
        successCount += 1
        onChanged()
    }

    func dismissActionError() { actionError = nil }

    /// `POST …/split` ; succès → `didSplit` et liste prévenue, échec → message, détail gardé.
    func split() async {
        guard !isWorking else { return }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            _ = try await client.splitActivity(id: activityId)
            didSplit = true
            successCount += 1
            onChanged()
        } catch {
            actionError = ActivityEditErrors.message(error)
        }
    }

    /// Une activité terminée ne change pas : si elle est déjà affichée (le
    /// `.task` se relance à chaque réapparition de la vue), on la garde ; un
    /// échec de rechargement ne la vide pas.
    func load() async {
        if case .loaded = state {} else { state = .loading }
        if case .loading = state, let stale: ActivityDetail = await client.cachedValue("api/activities/\(activityId)"),
           case .loading = state {
            state = .loaded(stale)
        }
        do {
            let detail: ActivityDetail = try await client.getCached("api/activities/\(activityId)")
            state = .loaded(detail)
        } catch {
            if case .loaded = state {} else { state = .failed(error.localizedDescription) }
        }
    }
}
