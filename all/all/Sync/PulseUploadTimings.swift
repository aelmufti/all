//
//  PulseUploadTimings.swift
//  all (bridge-connect)
//
//  Mesure des derniers envois vers Pulse, affichée dans Paramètres › Montre ›
//  Diagnostic. Pour chaque fichier : taille, attente avant préparation, préparation
//  (SHA-256 + requête), réseau + ingestion Pulse (requête émise → réponse), retour
//  sur le fil principal (délai avant que la session puisse enchaîner — un fil
//  principal occupé y apparaît directement) et code HTTP. Ni nom de fichier ni
//  contenu : rien qui identifie une donnée. En mémoire seulement (perdu à la
//  relance), borné aux `capacity` derniers envois.
//

import Foundation
import Observation

struct PulseUploadTiming: Identifiable, Equatable {
    let id = UUID()
    /// Appel de l'envoi (avant toute file d'attente).
    let startedAt: Date
    let sizeBytes: Int?
    /// Attente dans la file de préparation (une préparation à la fois).
    let waitS: Double
    /// Hachage du fichier + construction de la requête.
    let prepS: Double
    /// Requête émise → réponse (réseau + ingestion par Pulse) ; nil si non émise.
    let networkS: Double?
    /// Réponse → prise en main par le fil principal.
    var mainHopS: Double?
    /// Code HTTP ; nil sans réponse (erreur réseau, config absente, lecture impossible).
    let status: Int?
}

@MainActor
@Observable
final class PulseUploadTimings {
    static let shared = PulseUploadTimings()
    static let capacity = 30

    /// Plus récent en premier.
    private(set) var recent: [PulseUploadTiming] = []

    func clear() { recent = [] }

    private func append(_ timing: PulseUploadTiming) {
        recent.insert(timing, at: 0)
        if recent.count > Self.capacity { recent.removeLast(recent.count - Self.capacity) }
    }

    /// Depuis n'importe quel fil, au moment de la réponse (`respondedAt`) et AVANT
    /// d'appeler la complétion de l'envoi : le bloc posté sur le main passe juste
    /// avant celui de la session, son délai est donc le même.
    nonisolated static func report(_ timing: PulseUploadTiming, respondedAt: Date) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                var t = timing
                t.mainHopS = Date().timeIntervalSince(respondedAt)
                shared.append(t)
            }
        }
    }
}

/// Enveloppe d'un transport qui note l'instant d'émission et le code reçu.
final class TimedUploadTransport: PulseUploadTransport {
    private let base: PulseUploadTransport
    private(set) var sentAt: Date?
    private(set) var status: Int?

    init(base: PulseUploadTransport) {
        self.base = base
    }

    func send(_ request: URLRequest, fileURL: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        sentAt = Date()
        base.send(request, fileURL: fileURL) { [self] result in
            if case .success(let code) = result { status = code }
            completion(result)
        }
    }
}
