//
//  RecordsViewModel.swift
//  all (bridge-connect)
//
//  Charge `GET api/stats/records` (un seul appel, tous sports : le filtre
//  sport est appliqué côté écran sur `payload.sessions`). Même contrat
//  « 3 états » et même garde de rechargement que `DashboardViewModel`.
//

import Foundation

@MainActor
@Observable
final class RecordsViewModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: LoadState = .loading
    private(set) var payload: RecordsPayload?
    /// Filtre sport ; `nil` = Tous.
    private(set) var sport: String?

    private let client: PulseAPIClient
    private var hasStartedLoad = false
    private let gate = ReloadGate()
    private var loadGeneration = 0

    init(client: PulseAPIClient = .shared) {
        self.client = client
    }

    /// Séances du filtre courant (retombe sur « Tous » si le sport a disparu
    /// après un rechargement).
    var sessions: RecordsSessions? {
        payload?.sessions(for: sport) ?? payload?.sessions(for: nil)
    }

    func selectSport(_ sport: String?) {
        self.sport = sport
    }

    func loadIfNeeded() async {
        guard !hasStartedLoad else { return }
        hasStartedLoad = true
        await reload()
    }

    func reload(trailing: Bool = false) async {
        await gate.run(trailing: trailing) { [self] in await self.load() }
    }

    func retry() {
        Task { await reload() }
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        // Contenu déjà affiché : on le garde pendant un rechargement.
        if payload == nil { state = .loading }
        do {
            let result: RecordsPayload = try await client.get("api/stats/records")
            guard generation == loadGeneration else { return }
            payload = result
            if let sport, !result.sports.contains(sport) { self.sport = nil }
            state = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
