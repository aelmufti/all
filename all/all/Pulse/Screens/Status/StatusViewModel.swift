//
//  StatusViewModel.swift
//  all (bridge-connect)
//
//  État + chargement de l'écran Statut — port des signaux calculés de
//  `custom-connect/web/src/app/pages/status/status.component.ts` (tonalité du
//  lien, libellés relatifs, tête de ligne de la synchro auto) et d'une partie
//  de `shared/sync-card.component.ts` (état/progression/fraîcheur d'une
//  synchro). Un seul `load()` déclenche les trois lectures en parallèle
//  (lien, santé auto-sync, statut de synchro) — pas de minuteries de sondage
//  façon Angular (`LINK_MS`/`DETAIL_MS`/`FAST_POLL_MS`) : cet écran mise sur
//  le tirer-pour-rafraîchir (`.refreshable`), plus simple et suffisant pour
//  une page de diagnostic consultée à la demande.
//

import Foundation
import Observation

@MainActor
@Observable
final class StatusViewModel {
    enum ScreenState {
        case loading
        case loaded
        case failed(String)
    }

    /// Tonalité du lien BLE — miroir de `tone()` côté Angular, consommée par
    /// la vue pour colorer le point d'état (succès/danger/neutre).
    enum LinkTone {
        case idle
        case ok
        case warn
        case bad
    }

    private let client: PulseAPIClient

    private(set) var state: ScreenState = .loading
    private(set) var linkState: StatusLinkState?
    private(set) var autoSync: StatusAutoSyncHealth?
    private(set) var syncStatus: StatusSyncStatusView?

    private(set) var isConnecting = false
    private(set) var isTriggeringSync = false
    /// Message transitoire suite à une action (« Connecter maintenant »,
    /// « Synchroniser maintenant ») — miroir du signal `note()`/`syncMessage()`
    /// Angular, en plus discret ici (pas de minuterie d'auto-effacement, la
    /// prochaine action ou le prochain tirage l'écrase).
    private(set) var actionNote: String?

    init(client: PulseAPIClient = .shared) {
        self.client = client
    }

    // MARK: - Chargement

    func load() async {
        state = .loading
        do {
            async let linkTask: StatusLinkState = client.get("api/sync/link")
            async let detailTask: StatusHealthDetail = client.get("api/health/detail")
            async let statusTask: StatusSyncStatusView = client.get("api/sync/status")
            let (link, detail, status) = try await (linkTask, detailTask, statusTask)
            self.linkState = link
            self.autoSync = detail.sync
            self.syncStatus = status
            state = .loaded
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    // MARK: - Actions

    /// `POST api/sync/link/connect` — demande une tentative de connexion
    /// immédiate au bridge. Miroir de `connect()` côté Angular : le bridge la
    /// joue à son prochain passage, la réponse ne garantit pas un lien établi.
    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        actionNote = "Tentative demandée : le bridge la joue à son prochain passage."
        defer { isConnecting = false }
        do {
            let updated: StatusLinkState = try await client.post("api/sync/link/connect")
            linkState = updated
            if updated.link.connected == true {
                actionNote = "Lien établi."
            } else if !updated.reachable {
                actionNote = nil
            }
        } catch {
            actionNote = "Demande impossible : le serveur ne répond pas."
        }
    }

    /// `POST api/sync` — déclenche une synchronisation manuelle, puis relit
    /// `api/sync/status` pour refléter l'état obtenu (miroir de `onSync()`
    /// côté Angular, sans le sondage périodique qui suit la synchro là-bas).
    func triggerSync() async {
        guard !isTriggeringSync else { return }
        isTriggeringSync = true
        defer { isTriggeringSync = false }
        do {
            let result: StatusTriggerResult = try await client.post("api/sync")
            switch result.status {
            case .pending:
                actionNote = "Synchronisation demandée."
            case .throttled:
                actionNote = "Réessaie dans \(result.retryInSec ?? 30) s."
            case .unavailable:
                actionNote = result.message ?? "Synchronisation indisponible."
            }
            do {
                syncStatus = try await client.get("api/sync/status")
            } catch {
                // Statut illisible : on garde le dernier connu, la note d'action prime.
            }
        } catch {
            actionNote = "Erreur réseau."
        }
    }

    private static func message(for error: Error) -> String {
        (error as? PulseAPIError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Lien BLE : tonalité et libellés (miroir des signaux Angular)

    var linkTone: LinkTone {
        guard let linkState else { return .idle }
        if !linkState.reachable { return .bad }
        if linkState.link.recovery?.inProgress == true { return .bad }
        if linkState.link.connected == true { return .ok }
        return .warn
    }

    var linkStateLabel: String {
        guard let linkState else { return "Lecture du lien…" }
        if !linkState.reachable { return "Bridge injoignable" }
        if linkState.link.recovery?.inProgress == true { return "Contrôleur Bluetooth en récupération" }
        if linkState.link.connected == true { return "Montre connectée" }
        if linkState.link.connected == false { return "Montre déconnectée" }
        return "État du lien inconnu"
    }

    var showConnectButton: Bool {
        guard let linkState, linkState.reachable else { return false }
        return linkState.link.connected != true && linkState.link.recovery?.inProgress != true
    }

    var signalValue: String {
        guard let rssi = linkState?.link.rssi else { return "inconnu" }
        let dbm = Int(rssi.rounded())
        if rssi > -60 { return "\(dbm) dBm · excellent" }
        if rssi > -75 { return "\(dbm) dBm · bon" }
        if rssi > -85 { return "\(dbm) dBm · faible" }
        return "\(dbm) dBm · marginal"
    }

    var signalNote: String {
        guard let linkState else { return "" }
        if linkState.link.rssi == nil {
            return linkState.link.connected == true ? "aucun relevé récent" : "pas de lien à mesurer"
        }
        guard let rssiAt = linkState.link.rssiAt, let date = StatusDateFormatting.parse(rssiAt) else {
            return "relevé sans date"
        }
        return "relevé il y a \(StatusDateFormatting.spell(Date().timeIntervalSince(date)))"
    }

    var lastSeenLabel: String {
        guard let at = linkState?.link.lastSeenAt, let date = StatusDateFormatting.parse(at) else {
            return "—"
        }
        return StatusDateFormatting.clock(date)
    }

    var lastSeenNote: String {
        guard let at = linkState?.link.lastSeenAt else { return "jamais datée par le bridge" }
        guard let date = StatusDateFormatting.parse(at) else { return "jamais datée par le bridge" }
        return "il y a \(StatusDateFormatting.spell(Date().timeIntervalSince(date)))"
    }

    var retryValue: String? {
        guard let at = linkState?.link.nextAttemptAt, let date = StatusDateFormatting.parse(at) else {
            return nil
        }
        let left = date.timeIntervalSince(Date())
        return left < 1 ? "imminente" : "dans \(StatusDateFormatting.spell(left))"
    }

    var retryNote: String {
        guard let failures = linkState?.link.failures, failures > 0 else {
            return "le bridge rappelle la montre tout seul"
        }
        return "\(failures) échec\(failures > 1 ? "s" : "") d'affilée"
    }

    var linkMessage: String? {
        guard let linkState else { return nil }
        if !linkState.reachable { return linkState.detail }
        if linkState.link.connected == false { return linkState.link.error }
        return nil
    }

    var recoveryMessage: String? {
        guard let recovery = linkState?.link.recovery else { return nil }
        if recovery.inProgress {
            return "Le contrôleur Bluetooth du serveur est bloqué : une récupération matérielle est " +
                "en cours, la montre n'y est pour rien."
        }
        return recovery.outcome
    }

    // MARK: - Synchronisation automatique (miroir de `headline()`/`cadence()`/`countdown()`)

    var autoSyncHeadline: String {
        guard let autoSync else { return "" }
        if !autoSync.enabled { return "désactivée" }
        if autoSync.source != .bridge { return "au repos, source \(autoSync.source.rawValue) active" }
        if autoSync.stalled { return "bloquée depuis \(autoSync.cycles) cycles" }
        if autoSync.presence == .absente { return "sondage espacé, montre absente" }
        return autoSync.pending > 0 ? "drainage en cours" : "à jour"
    }

    var autoSyncStallNote: String? {
        guard let autoSync, autoSync.stalled, let reason = autoSync.reason else { return nil }
        guard let since = autoSync.since, let date = StatusDateFormatting.parse(since) else {
            return reason
        }
        return "\(reason) · depuis \(StatusDateFormatting.clock(date))"
    }

    var autoSyncCadence: String {
        guard let autoSync, autoSync.enabled else { return "—" }
        let minutes = Int((autoSync.intervalMs / 60_000).rounded())
        return autoSync.presence == .absente
            ? "\(minutes) min · montre absente"
            : "\(minutes) min · montre proche"
    }

    var autoSyncLastSuccessLabel: String {
        guard let at = autoSync?.lastSuccess, let date = StatusDateFormatting.parse(at) else {
            return "aucun enregistré"
        }
        return StatusDateFormatting.dayAndClock(date)
    }

    var autoSyncNextAttemptLabel: String? {
        guard let autoSync, autoSync.enabled,
            let at = autoSync.nextAttemptAt, let date = StatusDateFormatting.parse(at)
        else { return nil }
        return StatusDateFormatting.clock(date)
    }

    var autoSyncCountdown: String? {
        guard let autoSync, autoSync.enabled,
            let at = autoSync.nextAttemptAt, let date = StatusDateFormatting.parse(at)
        else { return nil }
        return StatusDateFormatting.spell(max(0, date.timeIntervalSince(Date())))
    }

    // MARK: - État de synchro / fraîcheur (miroir de `<app-sync-card>`)

    var syncFreshLabel: String? {
        guard let ageSec = syncStatus?.freshness?.ageSec else { return nil }
        return StatusDateFormatting.spell(Double(ageSec))
    }

    var syncLastSuccessLabel: String? {
        guard let at = syncStatus?.lastSuccess, let date = StatusDateFormatting.parse(at) else {
            return nil
        }
        return StatusDateFormatting.dayAndClock(date)
    }

    var syncWaitingLabel: String? {
        guard syncStatus?.state != .running,
            let left = syncStatus?.progress?.remainingOnWatch, left > 0
        else { return nil }
        let noun = left > 1 ? "fichiers" : "fichier"
        return "\(left) \(noun) encore sur la montre, repris au prochain passage"
    }

    var syncRunningLabel: String? {
        guard syncStatus?.state == .running else { return nil }
        var parts = ["Synchronisation en cours"]
        if let left = syncStatus?.progress?.remainingOnWatch {
            if left == 0 {
                parts.append("la montre a tout donné")
            } else {
                let noun = left > 1 ? "fichiers" : "fichier"
                if let total = syncStatus?.progress?.watchFiles, total >= left {
                    parts.append("il reste \(left) \(noun) sur \(total)")
                } else {
                    parts.append("il reste \(left) \(noun)")
                }
            }
        }
        return parts.joined(separator: " · ")
    }

    var syncProgressRatio: Double? {
        guard let total = syncStatus?.progress?.watchFiles, total > 0,
            let left = syncStatus?.progress?.remainingOnWatch
        else { return nil }
        let fetched = Double(max(0, min(total, total - left)))
        return fetched / Double(total)
    }

    var syncButtonLabel: String {
        switch syncStatus?.state {
        case .running: return "Synchronisation…"
        case .ok: return "Synchronisé ✓"
        default: return "Synchroniser maintenant"
        }
    }

    var syncButtonDisabled: Bool {
        isTriggeringSync || syncStatus?.state == .running
    }
}

// MARK: - Formatage de dates (miroir de `spell()` côté Angular)

/// Conversion locale des chaînes ISO 8601 renvoyées par Pulse (jamais de
/// `Date` côté modèles, cf. `StatusModels.swift`) en libellés relatifs ou en
/// heure courte — même esprit que `ActivityDateFormatting`.
enum StatusDateFormatting {
    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    static func parse(_ iso: String) -> Date? {
        isoFormatterWithFractional.date(from: iso) ?? isoFormatter.date(from: iso)
    }

    /// `HH:mm:ss` — miroir de `date: 'HH:mm:ss'` (Angular `DatePipe`).
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// `d MMM, HH:mm` — miroir de `date: 'd MMM, HH:mm'`.
    static func dayAndClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }

    /// Durée en secondes → libellé lisible ("42 s", "3 min", "2 h 05 min",
    /// "1 j 4 h") — miroir exact de `spell()` côté Angular (arrondi à la
    /// seconde, jamais négatif).
    static func spell(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        let totalSec = max(0, Int(seconds.rounded()))
        if totalSec < 60 { return "\(totalSec) s" }
        let minutes = totalSec / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours < 24 { return rest > 0 ? "\(hours) h \(rest) min" : "\(hours) h" }
        let days = hours / 24
        return "\(days) j \(hours % 24) h"
    }
}
