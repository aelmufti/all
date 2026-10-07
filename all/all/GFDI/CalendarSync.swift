//
//  CalendarSync.swift
//  all (bridge-connect)
//
//  Synchronisation du calendrier du téléphone vers la montre. Contrairement au
//  reste du collecteur (qui *tire* des fichiers de la montre), ici la montre est
//  demandeuse : pendant une session GFDI elle émet un
//  `CalendarService.CalendarServiceRequest` (champ 1 du message `Smart`, cf.
//  `calendar.pb.swift`), on lui répond un `CalendarServiceResponse` avec les
//  événements de la fenêtre demandée. Le câblage vit dans
//  `GarminSession.handleProtobufRequest` (service 1).
//
//  Portage du comportement de Gadgetbridge
//  (`ProtocolBufferHandler.processProtobufCalendarRequest`, AGPL — voir
//  garmin-bridge) : mêmes filtres (fenêtre, all-day opt-in), même plafond
//  (`maxEvents * 2`, testé sans souci en amont), mêmes troncatures.
//
//  Divergence iOS assumée sur les événements *journée entière* : Gadgetbridge
//  décale UTC→local car Android stocke leur début à minuit **UTC**. EventKit, lui,
//  fournit déjà minuit **local** (`EKEvent.startDate`), donc on envoie la seconde
//  Unix telle quelle, sans décalage. Si la montre affiche les all-day décalés du
//  fuseau après test sur matériel, ajouter `+ TimeZone.current.secondsFromGMT`
//  dans `unixSeconds(from:)` pour ce cas.
//

import Foundation
import EventKit
import os

/// Un événement de calendrier, découplé d'EventKit pour rester testable sans
/// permission ni `EKEventStore` (cf. `CalendarSyncTests`).
struct CalendarEventInput {
    var title: String
    var location: String?
    var notes: String?
    var organizer: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
}

/// Source d'événements du calendrier du téléphone. Abstraite pour injecter un
/// double en test ; l'implémentation réelle est `EventKitCalendarSource`.
///
/// Deux notions distinctes, volontairement découplées :
/// - **Accès** (`isAuthorized`, `requestAccess`, `events(from:to:)`) : l'app
///   a-t-elle le droit de lire le calendrier ? Indépendant de la montre — c'est ce
///   qu'utilisera l'organisateur de vie, qu'on envoie ou non les événements à la
///   montre.
/// - **Synchro montre** (`syncToWatchEnabled`, `isReadyForWatch`) : faut-il
///   répondre à la montre avec les événements ? Consommée par la session GFDI.
protocol CalendarEventSource: AnyObject {
    /// `true` si l'utilisateur a accordé l'accès complet au calendrier. Ne dépend
    /// pas du réglage de synchro montre.
    var isAuthorized: Bool { get }

    /// Demande l'accès (invite système si nécessaire) ; `granted` indique
    /// l'autorisation obtenue. Sans réseau, sans écriture de données.
    func requestAccess(_ completion: @escaping (Bool) -> Void)

    /// Réglage « envoyer les événements à la montre »
    /// (`PulseConfig.calendarSyncEnabled`). Sans effet sur l'accès.
    var syncToWatchEnabled: Bool { get }

    /// Événements chevauchant `[from, to]`, **sans condition sur la synchro
    /// montre** : liste vide si l'accès n'est pas accordé. Appel **synchrone**
    /// (l'autorisation est demandée en amont, hors du chemin GFDI).
    func events(from: Date, to: Date) -> [CalendarEventInput]
}

extension CalendarEventSource {
    /// `true` si la montre doit recevoir les événements : accès accordé *et*
    /// synchro montre activée. Quand `false`, la session répond une liste vide
    /// (statut OK), exactement comme Gadgetbridge quand `PREF_SYNC_CALENDAR` est
    /// désactivé.
    var isReadyForWatch: Bool { isAuthorized && syncToWatchEnabled }
}

/// Construit la réponse protobuf calendrier. Fonction pure (aucune dépendance
/// EventKit), pour tester le filtrage/troncature/sérialisation en isolation.
enum CalendarResponder {
    /// Réponse `Smart{ calendar_service { calendar_response } }` sérialisée, prête
    /// à être encapsulée dans une trame PROTOBUF_RESPONSE (5044).
    static func responseData(
        for request: GCalCalendarService.CalendarServiceRequest,
        events: [CalendarEventInput]
    ) -> Data {
        responseData(from: watchEvents(for: request, events: events))
    }

    /// Encapsule des événements déjà filtrés dans un `Smart{ calendar_response }`
    /// sérialisé. Séparé de `responseData(for:events:)` pour que l'appelant puisse
    /// compter les événements retenus (diagnostic) sans refiltrer.
    static func responseData(from watchEvents: [GCalCalendarService.CalendarEvent]) -> Data {
        var response = GCalCalendarService.CalendarServiceResponse()
        response.status = .ok
        response.calendarEvent = watchEvents

        var service = GCalCalendarService()
        service.calendarResponse = response
        var smart = GCalSmart()
        smart.calendarService = service
        // La sérialisation ne peut échouer pour ce message (champs scalaires +
        // strings valides) ; en cas d'imprévu on renvoie une réponse vide plutôt
        // que de propager une erreur sur le chemin GFDI.
        return (try? smart.serializedData()) ?? Data()
    }

    /// Réponse « OK, zéro événement » — utilisée quand la synchro est désactivée
    /// ou l'accès non accordé. Identique à l'ancien stub codé en dur.
    static var emptyOK: Data {
        var response = GCalCalendarService.CalendarServiceResponse()
        response.status = .ok
        var service = GCalCalendarService()
        service.calendarResponse = response
        var smart = GCalSmart()
        smart.calendarService = service
        return (try? smart.serializedData()) ?? Data()
    }

    static func watchEvents(
        for request: GCalCalendarService.CalendarServiceRequest,
        events: [CalendarEventInput]
    ) -> [GCalCalendarService.CalendarEvent] {
        let begin = request.begin
        let end = request.end
        let cap = Int(request.maxEvents) * 2
        var out: [GCalCalendarService.CalendarEvent] = []

        for ev in events {
            let startSec = unixSeconds(from: ev.start)
            let endSec = unixSeconds(from: ev.end)

            // Hors fenêtre demandée (comparaison directe en secondes Unix — le
            // service calendrier n'utilise PAS l'epoch Garmin, contrairement à
            // CURRENT_TIME).
            if endSec < begin || startSec > end { continue }
            // All-day seulement si la montre les demande (défaut : non).
            if !request.includeAllDay && ev.isAllDay { continue }
            // Plafond : le double de maxEvents, comme en amont (0 = pas de limite).
            if request.maxEvents > 0 && out.count >= cap { break }

            var pe = GCalCalendarService.CalendarEvent()
            pe.title = truncate(ev.title, request.maxTitleLength)
            pe.allDay = ev.isAllDay
            pe.startDate = startSec
            pe.endDate = endSec
            if request.includeLocation, let loc = ev.location, !loc.isEmpty {
                pe.location = truncate(loc, request.maxLocationLength)
            }
            if request.includeDescription, let notes = ev.notes, !notes.isEmpty {
                pe.description_p = truncate(notes, request.maxDescriptionLength)
            }
            // Gadgetbridge a ici un bug (il écrit l'organisateur dans le champ
            // *description*, l.375) ; on renseigne le vrai champ `organizer`.
            if request.includeOrganizer, let org = ev.organizer, !org.isEmpty {
                pe.organizer = truncate(org, request.maxOrganizerLength)
            }
            out.append(pe)
        }
        return out
    }

    static func unixSeconds(from date: Date) -> UInt32 {
        UInt32(clamping: Int(date.timeIntervalSince1970.rounded()))
    }

    /// Tronque à `maxLen` *caractères*. `maxLen == 0` (champ absent côté requête)
    /// = pas de troncature : plutôt renvoyer le texte complet qu'une chaîne vide,
    /// la montre positionnant ces bornes en pratique.
    static func truncate(_ s: String, _ maxLen: UInt32) -> String {
        maxLen == 0 ? s : String(s.prefix(Int(maxLen)))
    }
}

/// Source réelle adossée à EventKit. L'autorisation (`NSCalendarsFullAccessUsage
/// Description`) est demandée via `requestAccess(_:)` hors du chemin GFDI ; la
/// requête d'événements (`events(from:to:)`) est ensuite synchrone.
final class EventKitCalendarSource: CalendarEventSource {
    /// Instance partagée entre la session GFDI (`BLEManager`) et l'UI du toggle
    /// (`BLEDiagnosticView`) — l'autorisation EventKit est de toute façon
    /// globale à l'app, mais partager le `EKEventStore` évite d'en multiplier.
    static let shared = EventKitCalendarSource()

    private let store = EKEventStore()
    private let log = Logger(subsystem: "CleanYourRoom.all", category: "calendar")

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var syncToWatchEnabled: Bool {
        PulseConfig.calendarSyncEnabled
    }

    /// Déclenche l'invite système si nécessaire (aujourd'hui depuis le toggle de
    /// synchro montre ; l'organisateur de vie pourra l'appeler sans la montre).
    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { [weak self] granted, error in
            if let error { self?.log.error("EventKit accès refusé/erreur : \(error.localizedDescription, privacy: .public)") }
            completion(granted)
        }
    }

    func events(from: Date, to: Date) -> [CalendarEventInput] {
        guard isAuthorized else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).map { ek in
            CalendarEventInput(
                title: ek.title ?? "",
                location: ek.location,
                notes: ek.notes,
                organizer: ek.organizer?.name,
                start: ek.startDate,
                end: ek.endDate,
                isAllDay: ek.isAllDay
            )
        }
    }
}
