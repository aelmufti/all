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

    init(client: PulseAPIClient = .shared) {
        self.client = client
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
        self.username = response.username
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
        username = nil
    }

    /// `GET /api/auth/me` — vérifie une session déjà posée (cookie persistant
    /// entre lancements). Renvoie `true`/`false` plutôt que de jeter : c'est
    /// une vérification de routine, pas une action utilisateur à faire échouer
    /// bruyamment (ex. `PulseConfig.baseURL` pas encore configurée au premier
    /// lancement → `false`, silencieux, la porte de login s'affiche).
    @discardableResult
    func check() async -> Bool {
        isChecking = true
        defer { isChecking = false }
        do {
            let response: MeResponse = try await client.get("api/auth/me")
            username = response.username
            return true
        } catch {
            username = nil
            return false
        }
    }
}
