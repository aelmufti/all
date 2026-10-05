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
        do {
            let response: ActivityListResponse = try await client.get(
                "api/activities",
                query: ["limit": "500"]
            )
            state = .loaded(response.items)
        } catch {
            if case .loaded = state {} else { state = .failed(error.localizedDescription) }
        }
    }
}
