//
//  ActivityEditUITests.swift
//  allTests
//
//  Logique des écrans de modification / fusion d'activités (view models) : patch
//  minimal, échec qui garde la feuille, éligibilité de la fusion, raccourci
//  « suivante », séparation qui prévient la liste. Backend FACTICE, données
//  SYNTHÉTIQUES, aucun réseau.
//

import Testing
import Foundation
@testable import all

final class ActivityEditStubBackend: LocalPulseBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: String] = [:]
    private var failures: [String: (Int, String)] = [:]
    private(set) var requests: [(key: String, body: String?)] = []

    func respond(_ key: String, _ json: String) { lock.withLock { responses[key] = json } }
    func fail(_ key: String, status: Int, body: String = "") { lock.withLock { failures[key] = (status, body) } }
    func bodies(_ key: String) -> [String] { lock.withLock { requests.filter { $0.key == key }.compactMap(\.body) } }
    func count(_ key: String) -> Int { lock.withLock { requests.filter { $0.key == key }.count } }

    func handle(method: String, path: String, query: [String: String], body: Data?) async throws -> Data {
        let key = "\(method) \(path)"
        let (failure, response): ((Int, String)?, String?) = lock.withLock {
            requests.append((key, body.flatMap { String(data: $0, encoding: .utf8) }))
            return (failures[key], responses[key])
        }
        if let failure { throw PulseAPIError.http(status: failure.0, body: Data(failure.1.utf8)) }
        guard let response else { throw LocalPulseUnavailableError() }
        return Data(response.utf8)
    }
}

private func client(_ backend: ActivityEditStubBackend) -> PulseAPIClient {
    PulseAPIClient(baseURLProvider: { nil }, localBackend: backend, modeProvider: { .phone })
}

private func detailJSON(id: Int = 1, sport: String = "running", name: String? = nil, edited: Bool = false,
                        merged: Int = 0) -> String {
    let nameJSON = name.map { "\"\($0)\"" } ?? "null"
    return """
    {"id":\(id),"fileName":"a.fit","sport":"\(sport)","subSport":null,"startTime":"2026-10-01T08:00:00.000Z",
     "durationS":3600,"distanceM":10000,"calories":600,"avgHr":140,"maxHr":170,"track":[],"streams":null,
     "laps":[],"sets":[],"splits":[],"hrZones":[],"name":\(nameJSON),"note":null,"edited":\(edited),
     "mergedCount":\(merged),"source":{"startTime":"2026-10-01T08:00:00.000Z","endTime":"2026-10-01T17:00:00.000Z"},
     "edit":null,"members":[]}
    """
}

private func decodeDetail(_ json: String) throws -> ActivityDetail {
    try JSONDecoder().decode(ActivityDetail.self, from: Data(json.utf8))
}

@MainActor
private func activity(_ id: Int, sport: String = "running", start: String, durationS: Double = 1800) throws -> Activity {
    let json = """
    {"id":\(id),"fileName":"f\(id).fit","sport":"\(sport)","subSport":null,"startTime":"\(start)",
     "durationS":\(durationS),"distanceM":null,"calories":null,"avgHr":null,"maxHr":null}
    """
    return try JSONDecoder().decode(Activity.self, from: Data(json.utf8))
}

@MainActor
@Suite("Édition d'activité : feuille")
struct ActivityEditSheetLogicTests {
    @Test func rienNeChangeEnregistrerInactif() throws {
        let vm = ActivityEditViewModel(detail: try decodeDetail(detailJSON()), client: client(ActivityEditStubBackend()))
        #expect(!vm.hasChanges)
        #expect(!vm.canSave)
    }

    @Test func seulsLesChampsModifiesPartent() async throws {
        let backend = ActivityEditStubBackend()
        backend.respond("PUT api/activities/1/edit", detailJSON(name: "Sortie", edited: true))
        let vm = ActivityEditViewModel(detail: try decodeDetail(detailJSON()), client: client(backend))
        vm.name = "Sortie"
        vm.end = vm.end.addingTimeInterval(-3 * 3600)
        #expect(vm.canSave)
        let saved = await vm.save()
        #expect(saved?.name == "Sortie")
        let body = try #require(backend.bodies("PUT api/activities/1/edit").first)
        let object = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["name", "endAt"])
        #expect(object["name"] as? String == "Sortie")
    }

    @Test func effacerLeNomEnvoieNull() throws {
        let vm = ActivityEditViewModel(detail: try decodeDetail(detailJSON(name: "Sortie")), client: client(ActivityEditStubBackend()))
        vm.name = "  "
        #expect(vm.patch.name == .clear)
        #expect(vm.patch.note == .unchanged)
    }

    @Test func changerDeSportEnvoieLeSport() throws {
        let vm = ActivityEditViewModel(detail: try decodeDetail(detailJSON()), client: client(ActivityEditStubBackend()))
        vm.sport = "walking"
        #expect(vm.patch.sport == .set("walking"))
        #expect(vm.patch.startAt == .unchanged)
    }

    @Test func sportInconnuConserveDansLaListe() throws {
        let vm = ActivityEditViewModel(detail: try decodeDetail(detailJSON(sport: "kayaking")), client: client(ActivityEditStubBackend()))
        #expect(vm.sportOptions.contains("kayaking"))
    }

    @Test func finAvantDebutInvalide() throws {
        let vm = ActivityEditViewModel(detail: try decodeDetail(detailJSON()), client: client(ActivityEditStubBackend()))
        vm.end = vm.start.addingTimeInterval(-60)
        #expect(!vm.isValid)
        #expect(!vm.canSave)
    }

    @Test func echecGardeLaFeuilleEtExpliqueLErreur() async throws {
        let backend = ActivityEditStubBackend()
        backend.fail("PUT api/activities/1/edit", status: 400, body: "{\"message\":\"bornes hors de l'activité\"}")
        let vm = ActivityEditViewModel(detail: try decodeDetail(detailJSON()), client: client(backend))
        vm.name = "X"
        let saved = await vm.save()
        #expect(saved == nil)
        #expect(vm.errorMessage == "bornes hors de l'activité")
        #expect(vm.name == "X")
        #expect(vm.canSave)
    }

    @Test func retablirAppelleLeDelete() async throws {
        let backend = ActivityEditStubBackend()
        backend.respond("DELETE api/activities/1/edit", detailJSON())
        let vm = ActivityEditViewModel(detail: try decodeDetail(detailJSON(name: "Sortie", edited: true)), client: client(backend))
        #expect(vm.canReset)
        let result = await vm.resetOriginal()
        #expect(result?.name == nil)
        #expect(backend.count("DELETE api/activities/1/edit") == 1)
    }
}

@MainActor
@Suite("Édition d'activité : détail et séparation")
struct ActivityDetailActionsTests {
    @Test func applyRemplaceLeDetailEtPrevientLaListe() async throws {
        var notified = 0
        let vm = ActivityDetailViewModel(activityId: 1, client: client(ActivityEditStubBackend()), onChanged: { notified += 1 })
        vm.apply(try decodeDetail(detailJSON(name: "Neuf")))
        guard case .loaded(let d) = vm.state else { Issue.record("pas chargé"); return }
        #expect(d.name == "Neuf")
        #expect(notified == 1)
    }

    @Test func separationPrevientLaListe() async throws {
        let backend = ActivityEditStubBackend()
        backend.respond("POST api/activities/1/split", "{\"ids\":[1,2]}")
        var notified = 0
        let vm = ActivityDetailViewModel(activityId: 1, client: client(backend), onChanged: { notified += 1 })
        await vm.split()
        #expect(vm.didSplit)
        #expect(notified == 1)
        #expect(vm.actionError == nil)
    }

    @Test func separationEnEchecGardeLEcran() async throws {
        let backend = ActivityEditStubBackend()
        backend.fail("POST api/activities/1/split", status: 404)
        var notified = 0
        let vm = ActivityDetailViewModel(activityId: 1, client: client(backend), onChanged: { notified += 1 })
        await vm.split()
        #expect(!vm.didSplit)
        #expect(vm.actionError != nil)
        #expect(notified == 0)
    }
}

@MainActor
@Suite("Fusion d'activités : liste")
struct ActivityMergeLogicTests {
    private func loadedVM(_ backend: ActivityEditStubBackend, _ items: [Activity]) async throws -> ActivitiesViewModel {
        let list = try items.map { a -> String in
            """
            {"id":\(a.id),"fileName":"\(a.fileName)","sport":"\(a.sport ?? "")","subSport":null,"startTime":"\(a.startTime ?? "")",
             "durationS":\(a.durationS ?? 0),"distanceM":null,"calories":null,"avgHr":null,"maxHr":null}
            """
        }.joined(separator: ",")
        backend.respond("GET api/activities", "{\"total\":\(items.count),\"items\":[\(list)]}")
        let vm = ActivitiesViewModel(client: client(backend))
        await vm.load()
        return vm
    }

    @Test func fusionExigeDeuxActivitesDuMemeSport() async throws {
        let a = try activity(1, start: "2026-10-01T08:00:00.000Z")
        let b = try activity(2, start: "2026-10-01T09:00:00.000Z")
        let c = try activity(3, sport: "walking", start: "2026-10-01T10:00:00.000Z")
        let vm = try await loadedVM(ActivityEditStubBackend(), [c, b, a])
        vm.startSelecting()
        vm.toggle(1)
        #expect(!vm.canMerge)
        vm.toggle(2)
        #expect(vm.canMerge)
        vm.toggle(3)
        #expect(!vm.canMerge)
    }

    @Test func fusionReussieSortDeLaSelectionEtRecharge() async throws {
        let backend = ActivityEditStubBackend()
        let a = try activity(1, start: "2026-10-01T08:00:00.000Z")
        let b = try activity(2, start: "2026-10-01T09:00:00.000Z")
        let vm = try await loadedVM(backend, [b, a])
        backend.respond("POST api/activities/merge", "{\"id\":1}")
        vm.startSelecting(); vm.toggle(1); vm.toggle(2)
        let ok = await vm.mergeSelected()
        #expect(ok)
        #expect(!vm.isSelecting)
        #expect(vm.selected.isEmpty)
        #expect(backend.count("GET api/activities") == 2)
    }

    @Test func fusionRefuseeConserveLaSelection() async throws {
        let backend = ActivityEditStubBackend()
        let a = try activity(1, start: "2026-10-01T08:00:00.000Z")
        let b = try activity(2, start: "2026-10-01T09:00:00.000Z")
        let vm = try await loadedVM(backend, [b, a])
        backend.fail("POST api/activities/merge", status: 400, body: "{\"message\":\"chevauchement\"}")
        vm.startSelecting(); vm.toggle(1); vm.toggle(2)
        let ok = await vm.mergeSelected()
        #expect(!ok)
        #expect(vm.isSelecting)
        #expect(vm.selected == [1, 2])
        #expect(vm.mergeError == "chevauchement")
    }

    @Test func suivanteProposeeSousTrenteMinutes() async throws {
        // a finit à 08:30 ; b commence à 08:50 (20 min) : proposé.
        let a = try activity(1, start: "2026-10-01T08:00:00.000Z", durationS: 1800)
        let b = try activity(2, start: "2026-10-01T08:50:00.000Z")
        let vm = try await loadedVM(ActivityEditStubBackend(), [b, a])
        #expect(vm.nextMergeCandidate(after: a)?.id == 2)
        #expect(vm.nextMergeCandidate(after: b) == nil)
    }

    @Test func suivanteNonProposee() async throws {
        let a = try activity(1, start: "2026-10-01T08:00:00.000Z", durationS: 1800)
        let far = try activity(2, start: "2026-10-01T09:00:00.000Z")        // 30 min : trop loin
        let other = try activity(3, sport: "walking", start: "2026-10-02T08:10:00.000Z")
        let vm = try await loadedVM(ActivityEditStubBackend(), [other, far, a])
        #expect(vm.nextMergeCandidate(after: a) == nil)
        let overlap = try activity(4, start: "2026-10-03T08:20:00.000Z")
        let base = try activity(5, start: "2026-10-03T08:00:00.000Z", durationS: 1800)
        let vm2 = try await loadedVM(ActivityEditStubBackend(), [overlap, base])
        #expect(vm2.nextMergeCandidate(after: base) == nil)   // chevauchement
        // la suivante est d'un autre sport : pas de raccourci.
        let walk = try activity(6, sport: "walking", start: "2026-10-04T08:40:00.000Z")
        let run = try activity(7, start: "2026-10-04T08:00:00.000Z", durationS: 1800)
        let vm3 = try await loadedVM(ActivityEditStubBackend(), [walk, run])
        #expect(vm3.nextMergeCandidate(after: run) == nil)
    }

    @Test func fusionAvecLaSuivanteEnvoieLesDeuxIds() async throws {
        let backend = ActivityEditStubBackend()
        let a = try activity(1, start: "2026-10-01T08:00:00.000Z", durationS: 1800)
        let b = try activity(2, start: "2026-10-01T08:40:00.000Z")
        let vm = try await loadedVM(backend, [b, a])
        backend.respond("POST api/activities/merge", "{\"id\":1}")
        #expect(await vm.mergeWithNext(a))
        let body = try #require(backend.bodies("POST api/activities/merge").first)
        let ids = try #require((JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["ids"] as? [Int])
        #expect(Set(ids) == [1, 2])
    }
}
