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

    init(activityId: Int, client: PulseAPIClient = .shared) {
        self.activityId = activityId
        self.client = client
    }

    func load() async {
        state = .loading
        do {
            let detail: ActivityDetail = try await client.get("api/activities/\(activityId)")
            state = .loaded(detail)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
