//
//  ProgrammeViewModel.swift
//  all (bridge-connect)
//
//  État + chargement de l'écran Programme — miroir de `ProgrammeComponent`
//  (Angular). Un seul `GET api/programme` renvoie les trois domaines
//  (entraînement/alimentation/sommeil) d'un coup ; les actions (`activate`,
//  `stop`, bascule de séance) renvoient elles-mêmes le `Current` à jour
//  (mêmes routes `POST` que côté serveur), donc rechargent l'état local sans
//  second aller-retour — même pattern que `apply()`/`send()` Angular.
//
//  Écritures gardées raisonnables (cf. rendu de l'agent, consigne « priorité
//  à l'affichage ») :
//  - Cocher une séance marque directement « fait aujourd'hui » plutôt que
//    d'ouvrir le sheet de rapprochement avec les activités importées
//    (`GET api/programme/candidates` + `POST session` avec `activityId`) —
//    cette étape reste hors scope de cet incrément. Une séance déjà appariée
//    automatiquement (`done && !manual`) n'est pas modifiable, comme côté
//    Angular.
//  - L'envoi à la montre (`POST/GET api/programme/push`) est câblé en entier
//    (c'est un aller simple, peu de risque), avec le même polling 3 s que
//    `pollPush()` (Angular).
//

import Foundation
import Observation

@MainActor
@Observable
final class ProgrammeViewModel {
    enum ScreenState {
        case loading
        case loaded
        case failed(String)
    }

    private let client: PulseAPIClient

    /// Plein écran de chargement/erreur seulement tant qu'il n'y a rien à
    /// afficher : ensuite un rechargement garde le contenu.
    private(set) var state: ScreenState = .loading
    /// Échec d'un rechargement ou d'une action alors que l'écran est rempli :
    /// bandeau discret, le contenu reste (avant : tout l'écran remplacé par
    /// l'`ErrorView`).
    private(set) var actionError: String?
    var current: ProgrammeCurrent?

    /// Semaine affichée dans le détail entraînement — équivalent `shownWeek`.
    var shownWeek: Int = 1

    /// `true` pendant une mutation (activer/arrêter/cocher/envoyer) —
    /// désactive les actions concernées sans repasser tout l'écran en
    /// `.loading` — équivalent `busy()`.
    private(set) var isBusy = false

    /// Domaine dont la bibliothèque est ouverte (`nil` = sheet fermé).
    var libraryKind: ProgrammeKind?
    /// Feuille « choix d'objectif » ouverte.
    var showObjectives = false

    /// Activités récentes pour proposer des jours d'après les habitudes ;
    /// vide tant qu'elles ne sont pas chargées (ou si le chargement échoue).
    private(set) var habitActivities: [Activity] = []
    private var habitsLoaded = false

    var pushStatus: ProgrammePushStatus?
    /// Nombre de fichiers de la dernière `POST push` de cette session — le
    /// serveur ne le renvoie que dans la réponse d'envoi, pas dans
    /// `GET push` (même limite côté Angular : `pushCount` démarre à `nil`
    /// tant qu'aucun envoi n'a eu lieu depuis l'ouverture de l'écran).
    private(set) var pushFilesSent: Int?
    private var pushPollTask: Task<Void, Never>?
    /// Fusionne les rechargements — cf. `ReloadGate`.
    private let gate = ReloadGate()

    init(client: PulseAPIClient = .shared) {
        self.client = client
    }

    var domains: [ProgrammeDomainView] { current?.domains ?? [] }

    var trainingDomain: ProgrammeDomainView? { domains.first { $0.kind == .training } }

    var libraryDomain: ProgrammeDomainView? {
        guard let libraryKind else { return nil }
        return domains.first { $0.kind == libraryKind }
    }

    // MARK: - Chargement

    func reload() async {
        await gate.run { [self] in await self.load() }
    }

    /// Garde le contenu affiché pendant le rechargement ; un échec ne le vide
    /// pas (bandeau discret `actionError`).
    func load() async {
        if case .loaded = state {} else { state = .loading }
        if case .loading = state, let stale: ProgrammeCurrent = await client.cachedValue("api/programme"),
           case .loading = state {
            apply(stale)
            state = .loaded
        }
        do {
            let result: ProgrammeCurrent = try await client.getCached("api/programme")
            apply(result)
            state = .loaded
            actionError = nil
        } catch {
            if case .loaded = state {
                actionError = Self.message(for: error)
            } else {
                state = .failed(Self.message(for: error))
            }
        }
        await refreshPushStatus()
    }

    /// Remet la semaine affichée sur la semaine active (entrée dans le détail).
    func resetShownWeek() {
        guard let active = trainingDomain?.active, active.weeks > 0 else { return }
        shownWeek = min(max(active.week, 1), active.weeks)
    }

    private func apply(_ result: ProgrammeCurrent) {
        current = result
        if let training = trainingDomain, let active = training.active, active.weeks > 0 {
            shownWeek = min(max(active.week, 1), active.weeks)
        }
    }

    // MARK: - Bibliothèque

    func openLibrary(for kind: ProgrammeKind) {
        libraryKind = kind
    }

    func closeLibrary() {
        libraryKind = nil
    }

    func openObjectives() {
        showObjectives = true
    }

    /// Jours proposés pour `perWeek` séances (repli silencieux sur l'ordre par défaut).
    func daySuggestion(perWeek: Int) -> ProgrammeDaySuggestion {
        programmeSuggestDays(activities: habitActivities, perWeek: perWeek)
    }

    /// Même route que l'écran Activités ; un échec laisse l'ordre par défaut.
    func loadHabitsIfNeeded() async {
        guard !habitsLoaded else { return }
        do {
            let response: ActivityListResponse = try await client.get(
                "api/activities", query: ["limit": "500"])
            habitActivities = response.items
            habitsLoaded = true
        } catch {
            // Habitudes facultatives : on retombe sur l'ordre par défaut.
        }
    }

    // MARK: - Actions (entraînement/alimentation/sommeil)

    /// `POST api/programme/activate` — équivalent `activate(programmeId, days)`.
    @discardableResult
    func activate(programmeId: String, days: [Int]) async -> Bool {
        await mutate {
            let body = ProgrammeActivateRequest(programmeId: programmeId, days: days)
            return try await self.client.post("api/programme/activate", body: body)
        }
    }

    /// Équivalent `restart(domain)` : relance le même programme, mêmes jours,
    /// à partir d'aujourd'hui.
    func restart(_ domain: ProgrammeDomainView) async {
        guard let active = domain.active else { return }
        await activate(programmeId: active.programmeId, days: active.days)
    }

    /// `POST api/programme/stop` — équivalent `stop(kind)`.
    func stop(_ kind: ProgrammeKind) async {
        await mutate {
            let body = ProgrammeStopRequest(kind: kind.rawValue)
            return try await self.client.post("api/programme/stop", body: body)
        }
    }

    /// Bascule une séance — cf. remarque d'en-tête sur la simplification vs
    /// `openAttach`/candidats. Verrouillée côté vue quand `done && !manual`.
    func toggleSession(_ session: ProgrammeSessionProgress) async {
        await mutate {
            let body = ProgrammeSessionRequest(
                week: session.week,
                session: session.session.key,
                done: !session.done,
                date: nil,
                activityId: nil
            )
            return try await self.client.post("api/programme/session", body: body)
        }
    }

    /// Active la paire d'un objectif : entraînement (avec les jours) puis
    /// alimentation. Chacun remplace l'actif de son domaine. `true` si les deux passent.
    func activateObjective(_ choices: ProgrammeObjectiveChoices, days: [Int]) async -> Bool {
        guard await activate(programmeId: choices.training.id, days: days) else { return false }
        return await activate(programmeId: choices.nutrition.id, days: [])
    }

    @discardableResult
    private func mutate(_ operation: () async throws -> ProgrammeCurrent) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        actionError = nil
        defer { isBusy = false }
        do {
            let result = try await operation()
            apply(result)
            return true
        } catch {
            actionError = Self.message(for: error)
            return false
        }
    }

    // MARK: - Envoi à la montre

    /// `GET api/programme/push` — statut courant, appelé au chargement puis
    /// pendant le polling. Une panne ici reste secondaire : elle ne doit pas
    /// invalider tout l'écran (cf. `catch(() => null)` côté Angular).
    func refreshPushStatus() async {
        do {
            pushStatus = try await client.get("api/programme/push")
        } catch {
            // Statut secondaire, cf. commentaire ci-dessus.
        }
    }

    /// `POST api/programme/push` puis polling — équivalent `sendToWatch()`.
    func sendToWatch() async {
        guard !isBusy else { return }
        isBusy = true
        actionError = nil
        defer { isBusy = false }
        do {
            let response: ProgrammePushResponse = try await client.post("api/programme/push")
            pushFilesSent = response.files
            await refreshPushStatus()
            pollPush()
        } catch {
            actionError = Self.message(for: error)
        }
    }

    /// Équivalent `pollPush()` : relit le statut toutes les 3 s tant qu'il
    /// est `"running"`, jusqu'à 40 tentatives (~2 min, même borne qu'Angular).
    private func pollPush(tries: Int = 0) {
        pushPollTask?.cancel()
        guard tries < 40 else { return }
        pushPollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.refreshPushStatus()
            if self.pushStatus?.state == "running" {
                self.pollPush(tries: tries + 1)
            }
        }
    }

    private static func message(for error: Error) -> String {
        (error as? PulseAPIError)?.errorDescription ?? error.localizedDescription
    }
}
