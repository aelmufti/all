//
//  AuthStore.swift
//  all (bridge-connect)
//
//  État d'auth partagé, pilote la porte de login de la coquille (cf.
//  `ContentView.swift`) : tant que `username == nil`, on affiche `LoginView` ;
//  une fois posé, on affiche `PulseShellView`. Un seul point de vérité — les
//  écrans ne font jamais leur propre `POST /api/auth/*`.
//
//  Le cookie de session est géré par `URLSession`/`HTTPCookieStorage` (cf.
//  `PulseAPIClient`) : `AuthStore` ne le manipule pas directement, il ne fait
//  que refléter le résultat des appels (`username` posé/effacé).
//
//  Session retenue : le dernier `username` connu est gardé (UserDefaults). Au
//  lancement, la coquille s'ouvre aussitôt avec lui (données en cache) et `check()`
//  vérifie en arrière-plan ; seul un 401 (ou une adresse absente) ramène au login.
//  Avant, l'app restait sur « Connexion à Pulse… » jusqu'au délai réseau (60 s) et
//  toute erreur, même de transport, déconnectait.
//

import Foundation
import Observation

@MainActor
@Observable
final class AuthStore {
    static let shared = AuthStore()

    /// Nom d'utilisateur de la session en cours, `nil` = pas connecté (porte
    /// de login affichée).
    var username: String?

    /// `true` pendant `check()` (vérification de session au lancement) — les
    /// écrans peuvent s'en servir pour afficher `LoadingView` plutôt que de
    /// flasher la porte de login avant d'avoir la réponse. Vrai par défaut :
    /// `ContentView` lance `check()` dans un `.task` au premier rendu, donc la
    /// toute première image (avant que la tâche démarre) doit déjà refléter
    /// « en cours de vérification », pas « pas connecté ».
    var isChecking = true

    private let client: PulseAPIClient
    private let defaults: UserDefaults
    private static let rememberedKey = "pulse.auth.username"

    init(client: PulseAPIClient = .shared, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        // Session retenue : pas d'attente bloquante au lancement (cf. en-tête).
        username = defaults.string(forKey: Self.rememberedKey)
        isChecking = username == nil
    }

    private func remember(_ name: String?) {
        username = name
        if let name {
            defaults.set(name, forKey: Self.rememberedKey)
        } else {
            defaults.removeObject(forKey: Self.rememberedKey)
        }
    }

    private struct Credentials: Encodable {
        let username: String
        let password: String
    }

    private struct MeResponse: Decodable {
        let username: String
    }

    private struct OKResponse: Decodable {
        let ok: Bool
    }

    /// `POST /api/auth/login`. Mauvais identifiants → `PulseAPIError.unauthorized`
    /// remonté à l'appelant (`LoginView` affiche le message), `username` reste
    /// `nil` tant que ça n'a pas réussi.
    func login(username: String, password: String) async throws {
        let credentials = Credentials(username: username, password: password)
        let response: MeResponse = try await client.post("api/auth/login", body: credentials)
        remember(response.username)
    }

    /// `POST /api/auth/logout`. Best-effort côté réseau : même si l'appel
    /// échoue (Pulse inatteignable), on efface l'état local — l'utilisateur
    /// s'attend à être déconnecté de l'app, pas seulement du serveur.
    func logout() async {
        do {
            let _: OKResponse = try await client.post("api/auth/logout")
        } catch {
            // Ignoré : on efface l'état local même si Pulse est inatteignable
            // ou si la session avait déjà expiré côté serveur.
        }
        PulseResponseCache.shared.invalidateAll()
        remember(nil)
    }

    /// `GET /api/auth/me` — vérifie une session déjà posée (cookie persistant
    /// entre lancements). Renvoie `true`/`false` plutôt que de jeter : c'est
    /// une vérification de routine, pas une action utilisateur à faire échouer
    /// bruyamment (ex. `PulseConfig.baseURL` pas encore configurée au premier
    /// lancement → `false`, silencieux, la porte de login s'affiche).
    /// Session retenue : vérifiée sans bloquer (`isChecking` reste faux) ; une
    /// erreur de transport ou un 5xx la garde (Pulse injoignable ≠ déconnecté).
    @discardableResult
    func check() async -> Bool {
        let blocking = username == nil
        if blocking { isChecking = true }
        defer { if blocking { isChecking = false } }
        do {
            let response: MeResponse = try await client.get("api/auth/me")
            remember(response.username)
            return true
        } catch PulseAPIError.unauthorized, PulseAPIError.notConfigured {
            remember(nil)
            return false
        } catch {
            if blocking { username = nil }
            return false
        }
    }
}
