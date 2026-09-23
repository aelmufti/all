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

    init(client: PulseAPIClient = .shared) {
        self.client = client
    }

    func load() async {
        state = .loading
        do {
            let response: ActivityListResponse = try await client.get(
                "api/activities",
                query: ["limit": "500"]
            )
            state = .loaded(response.items)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
