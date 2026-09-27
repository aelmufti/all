//
//  CalendarSyncTests.swift
//  allTests
//
//  Couvre la brique pure de la synchro calendrier (CalendarSync.swift) :
//  filtrage par fenêtre, all-day opt-in, plafond maxEvents*2, troncatures, et
//  aller-retour d'encodage/décodage protobuf via les types générés (GCal*).
//  Pas de test EventKit ici : l'accès calendrier ne se simule pas hors device.
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
