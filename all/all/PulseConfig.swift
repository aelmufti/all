//
//  PulseConfig.swift
//  all (bridge-connect)
//
//  Configuration du collecteur : l'URL de Pulse (WebView, incrément 0) et,
//  depuis cet incrément, le token d'ingestion utilisé par `Sync/PulseUploader.swift`
//  (contrat `docs/pulse-ingest-contract.md` §3). Reste un espace de noms
//  statique (pas un type valeur `struct`) : `ContentView.swift` consomme déjà
//  `PulseConfig.baseURL` comme getter/setter global, l'introduction du token ne
//  doit pas casser cette forme.
//

import Foundation
import Security

/// Configuration minimale du collecteur.
///
/// L'URL de Pulse n'est **pas codée en dur** (on ne committe pas le hostname
/// Tailscale interne) : elle est saisie par l'utilisateur et persistée localement
/// (`UserDefaults`). Suffisant pour l'incrément 0 (charger la WebView) — et
/// réutilisée telle quelle comme base de l'endpoint `POST /api/ingest` (contrat
/// §2) par `PulseUploader`.
///
/// L'auth par **token dédié au téléphone** (contrat §3) est ajoutée ici : un
/// secret, donc persisté en **Keychain** plutôt qu'en `UserDefaults` (contrairement
/// à `baseURL`, qui n'est pas sensible). Pas d'UI de saisie cette session — les
/// deux valeurs restent `nil` tant qu'elles n'ont pas été renseignées, aucune
/// valeur par défaut réelle.
enum PulseConfig {
    private static let baseURLKey = "pulse.baseURL"

    /// URL de base de Pulse (ex. `https://pulse.<tailnet>.ts.net`).
    /// `nil` tant qu'elle n'a pas été renseignée.
    static var baseURL: URL? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: baseURLKey),
                  let url = URL(string: raw) else { return nil }
            return url
        }
        set {
            UserDefaults.standard.set(newValue?.absoluteString, forKey: baseURLKey)
        }
    }

    /// Token Bearer dédié au téléphone (`Authorization: Bearer <token>`,
    /// contrat §3) — persisté en Keychain (`PulseIngestTokenKeychain`), jamais en
    /// `UserDefaults` (secret d'authentification, contrairement à `baseURL`).
    /// `nil` tant qu'il n'a pas été renseigné ; pas d'UI cette session pour le
    /// saisir, pas de valeur réelle en dur.
    static var ingestToken: String? {
        get { PulseIngestTokenKeychain.read() }
        set { PulseIngestTokenKeychain.write(newValue) }
    }
}

/// Enveloppe Keychain minimale pour un unique secret (le token d'ingestion) :
/// un seul item générique de mot de passe, service+compte fixes. Pas de
/// gestion multi-appareil côté téléphone (un seul token par installation).
/// Toute erreur Keychain (verrouillage de l'appareil, etc.) se traduit par
/// `nil` en lecture plutôt qu'un crash — jamais fatal pour l'appelant.
private enum PulseIngestTokenKeychain {
    private static let service = "CleanYourRoom.all.pulse-ingest"
    private static let account = "ingest-token"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var newItem = query
        newItem[kSecValueData as String] = data
        SecItemAdd(newItem as CFDictionary, nil)
    }
}
