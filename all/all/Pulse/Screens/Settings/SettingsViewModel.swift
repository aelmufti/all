//
//  SettingsViewModel.swift
//  all (bridge-connect)
//
//  État + logique réseau de l'écran Paramètres. Charge en parallèle la
//  source de synchro, son statut et le profil (miroir partiel de
//  `SettingsComponent.ngOnInit`, Angular — restreint aux trois sections que
//  porte cet écran : Synchronisation, Profil, Application). L'inventaire est
//  chargé à part, en best-effort : purement informatif, une panne ne doit pas
//  faire échouer tout l'écran (même logique que le poids dans
//  `HealthViewModel.loadWeight`).
//
//  Écritures : changement de source (`PUT api/sync/source`), régénération du
//  token d'ingestion (`POST api/sync/ingest-token/regenerate`), sauvegarde du
//  profil (`PUT api/profile`). L'adresse Pulse (`PulseConfig.baseURL`) et la
//  déconnexion (`AuthStore.shared.logout()`) sont des actions locales, pas des
//  appels réseau typés par ce fichier — la vue les invoque directement.
//

import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    enum ScreenState {
        case loading
        case loaded
        case failed(String)
    }

    private let client: PulseAPIClient

    /// Plein écran de chargement/erreur seulement tant qu'il n'y a rien à
    /// afficher : ensuite un rechargement (changement de source de stockage…)
    /// garde le formulaire — sinon le sélecteur que l'on vient de toucher
    /// disparaissait derrière un écran de chargement.
    private(set) var state: ScreenState = .loading
    /// Fusionne les rechargements — cf. `ReloadGate`.
    private let gate = ReloadGate()

    private(set) var source: SettingsSyncSource?
    private(set) var status: SettingsSyncStatus?
    private(set) var inventory: SettingsSyncInventory?
    private(set) var profile: SettingsProfile?

    /// Désactive le sélecteur pendant un changement de source, pour éviter un
    /// double tap qui déclencherait deux `PUT` concurrents.
    private(set) var isChangingSource = false
    private(set) var sourceError: String?
    private(set) var isRegeneratingToken = false

    // MARK: - Édition du profil

    var birthYearText: String = ""
    var heightCmText: String = ""
    var sex: String?
    private(set) var isSavingProfile = false
    private(set) var profileSaved = false
    private(set) var profileError: String?

    // MARK: - Application (adresse Pulse)

    /// Pré-rempli depuis `PulseConfig.baseURL` : la vue n'a pas besoin de lire
    /// le singleton elle-même, elle passe par ce champ.
    var baseURLText: String
    private(set) var baseURLSaved = false
    private(set) var baseURLError: String?

    init(client: PulseAPIClient = .shared) {
        self.client = client
        self.baseURLText = PulseConfig.baseURL?.absoluteString ?? ""
    }

    // MARK: - Chargement

    /// Rechargement fusionné : un déclencheur pendant un rechargement en cours
    /// le rejoint au lieu de relancer les requêtes.
    func reload() async {
        await gate.run(trailing: true) { [self] in await self.load() }
    }

    func load() async {
        if case .loaded = state {} else { state = .loading }
        // Mode Téléphone (incréments L0+L6, `docs/stockage-local.md`) :
        // source de synchro / statut / inventaire n'ont pas de sens sans
        // serveur — ils passeraient par le backend local stub et
        // échoueraient (`LocalPulseUnavailableError`), affichant `ErrorView`
        // en boucle et coinçant l'utilisateur SANS accès au sélecteur de
        // Stockage pour revenir en arrière. On les court-circuite : `source`/
        // `status`/`inventory` restent `nil`, `SettingsView` n'affiche alors
        // que les sections qui ne les lisent pas (Stockage, Apparence,
        // Montre, Profil). Le PROFIL, lui, EST servi localement depuis L6
        // (`RealLocalPulseBackend`, `GET api/profile`) — on le charge donc
        // quand même, seul, via le même `client` (le routage vers le backend
        // local est déjà géré par `PulseAPIClient`, transparent ici).
        guard StorageModeStore.current != .phone else {
            do {
                let profile: SettingsProfile = try await client.get("api/profile")
                applyProfile(profile)
                state = .loaded
            } catch {
                if case .loaded = state {} else { state = .failed(Self.message(for: error)) }
            }
            return
        }
        do {
            async let sourceResult: SettingsSyncSource = client.get("api/sync/source")
            async let statusResult: SettingsSyncStatus = client.get("api/sync/status")
            async let profileResult: SettingsProfile = client.get("api/profile")
            let (source, status, profile) = try await (sourceResult, statusResult, profileResult)
            self.source = source
            self.status = status
            applyProfile(profile)
            state = .loaded
            await loadInventory()
        } catch {
            // Déjà chargé : on garde le formulaire (aucun bandeau d'erreur ici).
            if case .loaded = state {} else { state = .failed(Self.message(for: error)) }
        }
    }

    func retry() async {
        await reload()
    }

    private func loadInventory() async {
        do {
            inventory = try await client.get("api/sync/inventory")
        } catch {
            // Secondaire (cf. en-tête de fichier) : silencieux, l'inventaire
            // reste `nil` et la carte correspondante ne s'affiche pas.
        }
    }

    private func applyProfile(_ profile: SettingsProfile) {
        self.profile = profile
        birthYearText = profile.birthYear.map(String.init) ?? ""
        heightCmText = profile.heightCm.map(Self.formatHeight) ?? ""
        sex = profile.sex
    }

    // MARK: - Source de synchro

    func setSource(_ next: String) async {
        guard source?.source != next, !isChangingSource else { return }
        isChangingSource = true
        sourceError = nil
        defer { isChangingSource = false }
        do {
            source = try await client.put(
                "api/sync/source",
                body: SettingsSyncSourceUpdateRequest(source: next)
            )
            // Pulse accepte de nouveau les envois de l'app : on repousse tout de
            // suite les fichiers restés dans le Spool pendant que la source
            // était ailleurs (403), sans attendre le prochain lancement ni la
            // prochaine synchro montre. Sans effet s'il n'y a rien en attente.
            if source?.source == SettingsSyncSourceKind.phone.rawValue {
                PulseBacklogPusher.pushIfNeeded()
            }
        } catch {
            sourceError = (error as? PulseAPIError)?.errorDescription ?? "Changement de source refusé par le serveur."
        }
    }

    func regenerateIngestToken() async {
        guard !isRegeneratingToken else { return }
        isRegeneratingToken = true
        sourceError = nil
        defer { isRegeneratingToken = false }
        do {
            source = try await client.post("api/sync/ingest-token/regenerate")
        } catch {
            sourceError = "Régénération du token refusée par le serveur."
        }
    }

    // MARK: - Profil

    func saveProfile() async {
        profileError = nil
        profileSaved = false
        guard let birthYear = Int(birthYearText.trimmingCharacters(in: .whitespaces)), let sex else {
            profileError = "Année de naissance et sexe sont nécessaires au calcul."
            return
        }
        guard !isSavingProfile else { return }
        isSavingProfile = true
        defer { isSavingProfile = false }

        var body = SettingsProfileUpdateRequest(birthYear: birthYear, sex: sex)
        let trimmedHeight = heightCmText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if let heightCm = Double(trimmedHeight), heightCm > 0 {
            body.heightCm = heightCm
        }

        do {
            let updated: SettingsProfile = try await client.put("api/profile", body: body)
            applyProfile(updated)
            profileSaved = true
        } catch {
            profileError = "Valeurs refusées : vérifie l'année de naissance et la taille."
        }
    }

    /// Poids retenu, en lecture seule (miroir de `profileWeight()`, Angular).
    var profileWeightLabel: String {
        guard let kg = profile?.weightKg else { return "aucune pesée enregistrée" }
        return "\(Self.formatHeight(kg)) kg"
    }

    // MARK: - Application

    func saveBaseURL() {
        baseURLError = nil
        baseURLSaved = false
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            baseURLError = "Adresse invalide."
            return
        }
        PulseConfig.baseURL = url
        baseURLSaved = true
    }

    // MARK: - Formatage

    private static func formatHeight(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func message(for error: Error) -> String {
        (error as? PulseAPIError)?.errorDescription ?? "Erreur inattendue."
    }
}
