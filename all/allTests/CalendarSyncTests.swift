//
//  CalendarSyncTests.swift
//  allTests
//
//  Couvre la brique pure de la synchro calendrier (CalendarSync.swift) :
//  filtrage par fenêtre, all-day opt-in, plafond maxEvents*2, troncatures, et
//  aller-retour d'encodage/décodage protobuf via les types générés (GCal*).
//  Pas de test EventKit ici : l'accès calendrier ne se simule pas hors device ;
//  le découplage accès / synchro montre se teste via un double de
//  `CalendarEventSource` et une vraie `GarminSession` sur communicator factice.
//

import Testing
import Foundation
import SwiftProtobuf
@testable import all

struct CalendarSyncTests {
    /// Requête « large » typique : fenêtre ouverte, tous les champs inclus.
    private func request(
        begin: UInt32 = 0,
        end: UInt32 = .max,
        maxEvents: UInt32 = 100,
        includeAllDay: Bool = true,
        includeLocation: Bool = true,
        includeDescription: Bool = true,
        includeOrganizer: Bool = true,
        maxTitleLength: UInt32 = 100,
        maxLocationLength: UInt32 = 100,
        maxDescriptionLength: UInt32 = 100,
        maxOrganizerLength: UInt32 = 100
    ) -> GCalCalendarService.CalendarServiceRequest {
        var r = GCalCalendarService.CalendarServiceRequest()
        r.begin = begin
        r.end = end
        r.maxEvents = maxEvents
        r.includeAllDay = includeAllDay
        r.includeLocation = includeLocation
        r.includeDescription = includeDescription
        r.includeOrganizer = includeOrganizer
        r.maxTitleLength = maxTitleLength
        r.maxLocationLength = maxLocationLength
        r.maxDescriptionLength = maxDescriptionLength
        r.maxOrganizerLength = maxOrganizerLength
        return r
    }

    private func event(
        title: String = "Réunion",
        start: TimeInterval,
        end: TimeInterval,
        allDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        organizer: String? = nil
    ) -> CalendarEventInput {
        CalendarEventInput(
            title: title,
            location: location,
            notes: notes,
            organizer: organizer,
            start: Date(timeIntervalSince1970: start),
            end: Date(timeIntervalSince1970: end),
            isAllDay: allDay
        )
    }

    /// Décode la Data de réponse (Smart) et renvoie les événements côté montre.
    private func decode(_ data: Data) throws -> GCalCalendarService.CalendarServiceResponse {
        let smart = try GCalSmart(serializedBytes: data)
        return smart.calendarService.calendarResponse
    }

    @Test func passeUnEvenementSimpleEnSecondesUnix() throws {
        let ev = event(start: 1_700_000_000, end: 1_700_003_600)
        let data = CalendarResponder.responseData(for: request(), events: [ev])
        let resp = try decode(data)

        #expect(resp.status == .ok)
        #expect(resp.calendarEvent.count == 1)
        let e = resp.calendarEvent[0]
        #expect(e.title == "Réunion")
        #expect(e.startDate == 1_700_000_000)
        #expect(e.endDate == 1_700_003_600)
        #expect(e.allDay == false)
    }

    @Test func filtreLesEvenementsHorsFenetre() {
        let avant = event(title: "avant", start: 100, end: 200)
        let dans = event(title: "dans", start: 1_500, end: 1_600)
        let apres = event(title: "après", start: 5_000, end: 5_100)
        let out = CalendarResponder.watchEvents(
            for: request(begin: 1_000, end: 2_000),
            events: [avant, dans, apres]
        )
        #expect(out.map(\.title) == ["dans"])
    }

    @Test func evenementChevauchantLaBordureEstConserve() {
        // Commence avant la fenêtre mais finit dedans → conservé.
        let chevauche = event(title: "chevauche", start: 900, end: 1_100)
        let out = CalendarResponder.watchEvents(
            for: request(begin: 1_000, end: 2_000),
            events: [chevauche]
        )
        #expect(out.count == 1)
    }

    @Test func allDayExcluSiNonDemande() {
        let allDay = event(title: "férié", start: 1_000, end: 90_000, allDay: true)
        let normal = event(title: "normal", start: 1_000, end: 2_000)
        let out = CalendarResponder.watchEvents(
            for: request(includeAllDay: false),
            events: [allDay, normal]
        )
        #expect(out.map(\.title) == ["normal"])
    }

    @Test func plafonneAuDoubleDeMaxEvents() {
        let events = (0..<10).map { i in
            event(title: "e\(i)", start: TimeInterval(i * 10), end: TimeInterval(i * 10 + 5))
        }
        // maxEvents=2 → plafond = 4.
        let out = CalendarResponder.watchEvents(
            for: request(begin: 0, end: .max, maxEvents: 2),
            events: events
        )
        #expect(out.count == 4)
    }

    @Test func tronqueTitreLocalisationDescription() {
        let ev = event(
            title: "TitreTresLong",
            start: 100, end: 200,
            location: "LieuTresLong",
            notes: "NoteTresLongue",
            organizer: "OrganisateurLong"
        )
        let out = CalendarResponder.watchEvents(
            for: request(begin: 0, end: 1_000, maxTitleLength: 5,
                         maxLocationLength: 4, maxDescriptionLength: 4, maxOrganizerLength: 3),
            events: [ev]
        )
        let e = out[0]
        #expect(e.title == "Titre")
        #expect(e.location == "Lieu")
        #expect(e.description_p == "Note")
        #expect(e.organizer == "Org")
    }

    @Test func champsOptionnelsOmisSiNonDemandes() {
        let ev = event(start: 100, end: 200, location: "Lieu", notes: "Note", organizer: "Org")
        let out = CalendarResponder.watchEvents(
            for: request(begin: 0, end: 1_000, includeLocation: false,
                         includeDescription: false, includeOrganizer: false),
            events: [ev]
        )
        let e = out[0]
        #expect(e.hasLocation == false)
        #expect(e.hasDescription_p == false)
        #expect(e.hasOrganizer == false)
    }

    @Test func reponseVideEstOKSansEvenement() throws {
        let resp = try decode(CalendarResponder.emptyOK)
        #expect(resp.status == .ok)
        #expect(resp.calendarEvent.isEmpty)
    }

    @Test func allerRetourDepuisUneRequeteEncodee() throws {
        // Simule ce que la montre envoie : un Smart{ calendar_service{ request } }.
        var service = GCalCalendarService()
        service.calendarRequest = request(begin: 1_000, end: 2_000)
        var smart = GCalSmart()
        smart.calendarService = service
        let wire = try smart.serializedData()

        // Redécode côté « session » et vérifie l'accès aux bornes.
        let decoded = try GCalSmart(serializedBytes: wire)
        #expect(decoded.calendarService.hasCalendarRequest)
        #expect(decoded.calendarService.calendarRequest.begin == 1_000)
        #expect(decoded.calendarService.calendarRequest.end == 2_000)
    }
}

// MARK: - Accès calendrier vs synchro montre

/// Double de `CalendarEventSource` : jamais d'EventKit ni de lecture du vrai
/// calendrier (règle immuable CLAUDE.md) — accès et réglage de synchro sont
/// deux interrupteurs indépendants, comme dans l'implémentation réelle.
private final class StubCalendarSource: CalendarEventSource {
    var isAuthorized: Bool
    var syncToWatchEnabled: Bool
    private let stored: [CalendarEventInput]

    init(authorized: Bool, syncToWatch: Bool, events: [CalendarEventInput]) {
        self.isAuthorized = authorized
        self.syncToWatchEnabled = syncToWatch
        self.stored = events
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) { completion(isAuthorized) }

    func events(from: Date, to: Date) -> [CalendarEventInput] {
        isAuthorized ? stored : []
    }
}

/// Communicator GFDI FACTICE (jamais de vrai BLE) : capte les trames émises et
/// permet d'injecter une trame entrante. Copie locale, comme dans les autres
/// fichiers de test (les types voisins sont `private`).
private final class CalendarFakeCommunicator: GfdiCommunicating {
    var onGfdiFrame: ((GfdiFrame) -> Void)?
    var onGfdiChannelReady: (() -> Void)?
    private(set) var sentFrames: [Data] = []

    func start() {}

    func sendGfdiMessage(_ frame: Data, taskName: String) {
        sentFrames.append(frame)
    }

    func deliver(messageType: UInt16, payload: Data) {
        onGfdiFrame?(GfdiFrame(messageType: messageType, payload: payload))
    }
}

struct CalendarAccessVsWatchSyncTests {
    private let sample = CalendarEventInput(
        title: "Réunion", location: nil, notes: nil, organizer: nil,
        start: Date(timeIntervalSince1970: 1_700_000_000),
        end: Date(timeIntervalSince1970: 1_700_003_600),
        isAllDay: false
    )

    /// Envoie une vraie demande calendrier de la montre (PROTOBUF_REQUEST 5043,
    /// service 1) à une `GarminSession` et décode la réponse PROTOBUF_RESPONSE
    /// (5044) émise.
    private func watchResponse(for source: CalendarEventSource) throws -> GCalCalendarService.CalendarServiceResponse {
        let fake = CalendarFakeCommunicator()
        let session = GarminSession(communicator: fake, spoolStore: nil, calendarSource: source)
        withExtendedLifetime(session) {
            var request = GCalCalendarService.CalendarServiceRequest()
            request.begin = 0
            request.end = .max
            request.maxEvents = 100
            request.maxTitleLength = 100
            var service = GCalCalendarService()
            service.calendarRequest = request
            var smart = GCalSmart()
            smart.calendarService = service
            let message = (try? smart.serializedData()) ?? Data()

            var writer = GarminByteWriter()
            writer.writeUInt16LE(7) // requestId
            writer.writeUInt32LE(0) // dataOffset
            writer.writeUInt32LE(UInt32(message.count)) // totalProtobufLength
            writer.writeUInt32LE(UInt32(message.count)) // protobufDataLength
            writer.writeBytes(message)
            fake.deliver(messageType: 5043, payload: writer.data)
        }

        // Parmi les trames émises (accusé 5000, puis réponse 5044), retient la
        // réponse protobuf : son payload = requestId(2) + 3 × UInt32 + protobuf.
        let frames = try fake.sentFrames.map { try GfdiFrame.parse($0) }
        let reply = try #require(frames.first { $0.messageType == 5044 })
        let smart = try GCalSmart(serializedBytes: Data(reply.payload.dropFirst(14)))
        return smart.calendarService.calendarResponse
    }

    @Test func accesAccordeSynchroMontreDesactiveeLaSourceResteLisibleMaisLaMontreRecoitVide() throws {
        let source = StubCalendarSource(authorized: true, syncToWatch: false, events: [sample])

        // Côté app (organisateur) : lecture possible sans la synchro montre.
        #expect(source.isAuthorized)
        #expect(source.events(from: .distantPast, to: .distantFuture).count == 1)
        // Côté montre : pas prête → réponse vide, statut OK.
        #expect(!source.isReadyForWatch)
        let resp = try watchResponse(for: source)
        #expect(resp.status == .ok)
        #expect(resp.calendarEvent.isEmpty)
    }

    @Test func accesAccordeSynchroMontreActiveeLesEvenementsSontEnvoyes() throws {
        let source = StubCalendarSource(authorized: true, syncToWatch: true, events: [sample])

        #expect(source.isReadyForWatch)
        let resp = try watchResponse(for: source)
        #expect(resp.status == .ok)
        #expect(resp.calendarEvent.map(\.title) == ["Réunion"])
        #expect(resp.calendarEvent.first?.startDate == 1_700_000_000)
    }

    @Test func accesRefuseRienNiPourLAppNiPourLaMontre() throws {
        for syncToWatch in [false, true] {
            let source = StubCalendarSource(authorized: false, syncToWatch: syncToWatch, events: [sample])

            #expect(!source.isAuthorized)
            #expect(source.events(from: .distantPast, to: .distantFuture).isEmpty)
            #expect(!source.isReadyForWatch)
            let resp = try watchResponse(for: source)
            #expect(resp.status == .ok)
            #expect(resp.calendarEvent.isEmpty)
        }
    }
}
