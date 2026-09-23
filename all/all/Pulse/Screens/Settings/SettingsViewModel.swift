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

    private(set) var state: ScreenState = .loading

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

    func load() async {
        state = .loading
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
            state = .failed(Self.message(for: error))
        }
    }

    func retry() async {
        await load()
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
