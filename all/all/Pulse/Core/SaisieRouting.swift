//
//  SaisieRouting.swift
//  all (bridge-connect)
//
//  Classement PUR des routes de saisies pour le routage « Les deux » de
//  `PulseAPIClient` (contrat `custom-connect/docs/pulse-saisies-sync-contract.md`
//  §7) : quelles routes lisent des saisies, lesquelles en écrivent, lesquelles
//  portent un identifiant NUMÉRIQUE propre à une base (`id` d'`AUTOINCREMENT` —
//  différent entre le téléphone et Pulse pour la même ligne).
//
//  Aucune E/S ici : testable sans réseau ni base.
//

import Foundation

/// D'où est venue la dernière lecture de saisies réussie.
enum SaisieSource: Equatable {
    case pulse
    case local
}

enum SaisieRoute {
    /// Chemin sans « / » de tête ni préfixe `api/`.
    static func normalized(_ path: String) -> String {
        var route = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if route.hasPrefix("api/") { route = String(route.dropFirst(4)) }
        return route
    }

    private static let readRoutes: Set<String> = [
        "weight", "profile", "wake-schedule", "programme",
        "nutrition/frequent", "nutrition/foods", "nutrition/targets", "nutrition/weekly",
        "stats/tab-nutrition", "stats/tab-health",
    ]
    private static let readPrefixes = ["nutrition/day/", "nutrition/timing/", "nutrition/suggestions/"]

    /// Routes servies par le backend local qui lisent des saisies. Exclut
    /// `nutrition/search` et `nutrition/barcode/…` (Open Food Facts, pas une saisie).
    static func isRead(method: String, path: String) -> Bool {
        guard method == "GET" else { return false }
        let route = normalized(path)
        return readRoutes.contains(route) || readPrefixes.contains { route.hasPrefix($0) }
    }

    private static let writeRoutes: Set<String> = [
        "nutrition/foods", "nutrition/log", "weight", "profile", "wake-schedule",
        "programme/activate", "programme/stop", "programme/session",
    ]
    private static let writePrefixes = ["nutrition/foods/", "nutrition/log/", "weight/"]

    static func isWrite(method: String, path: String) -> Bool {
        guard method == "POST" || method == "PUT" || method == "DELETE" else { return false }
        let route = normalized(path)
        if writeRoutes.contains(route) { return true }
        return writePrefixes.contains { route.hasPrefix($0) && route.count > $0.count }
    }

    /// Écriture qui désigne une ligne par son `id` numérique : `PUT`/`DELETE` avec
    /// `:id` sous `nutrition/`, ou `POST nutrition/log` dont le corps porte un
    /// `foodId` (§7).
    static func carriesLocalId(method: String, path: String, body: Data?) -> Bool {
        let route = normalized(path)
        if method == "PUT" || method == "DELETE" {
            for prefix in ["nutrition/foods/", "nutrition/log/"] where route.hasPrefix(prefix) && route.count > prefix.count {
                return true
            }
            return false
        }
        guard method == "POST", route == "nutrition/log", let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let foodId = object["foodId"], !(foodId is NSNull) else { return false }
        return true
    }
}

/// Mémorise la source de la dernière lecture de saisies réussie. Accès depuis
/// n'importe quel fil (les écrans appellent le client depuis le main, les tâches de
/// fond non).
final class SaisieSourceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var source: SaisieSource?

    var last: SaisieSource? {
        lock.lock()
        defer { lock.unlock() }
        return source
    }

    func record(_ newValue: SaisieSource) {
        lock.lock()
        source = newValue
        lock.unlock()
    }
}
