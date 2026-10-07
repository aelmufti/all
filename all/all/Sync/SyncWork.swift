//
//  SyncWork.swift
//  all (bridge-connect)
//
//  État observable du TRAVAIL du téléphone qui n'a pas de lien avec le BLE — l'envoi
//  des `.fit` vers Pulse, l'ingestion locale, l'échange des saisies — pour la bannière
//  globale (`Pulse/SyncStatusBanner.swift`) — plus le rapatriement des `.fit` depuis Pulse
//  (`PulseFilesPullService`). La synchro MONTRE, elle, vient toujours de
//  `BLEManager`/`GarminSession` (`SyncActivity.from`) : rien n'est dupliqué ici, ces
//  activités n'étaient publiées nulle part.
//
//  Même forme que `PulseUploadHealth` : `@MainActor @Observable`, `shared`, instance
//  injectable en test. Les producteurs tournent hors main : ils passent par
//  `SyncWorkReporting` (`MainSyncWorkReporter` en production, double en test), qui
//  saute sur le main par `DispatchQueue.main.async` — file FIFO, donc l'ordre
//  d'émission est celui de la réception, et les compteurs sont de simples
//  begin/end (jamais « positionne à N » concurrents).
//
//  Trois couches, chacune pure ou injectable :
//   1. `SyncWorkSnapshot` : ce qui travaille, tel que déclaré par les producteurs ;
//   2. `SyncActivity.fromWork` (`Pulse/SyncActivity.swift`) : quoi montrer, selon le mode
//      et les priorités ;
//   3. `SyncActivityGate` : quand le montrer (anti-clignotement).
//
//  RISQUE PRINCIPAL = un compteur coincé, donc une bannière affichée pour toujours.
//  Défenses : chaque producteur libère dans TOUS ses chemins de sortie (`defer`, ou
//  compteur dérivé de la file elle-même), les `end` sans `begin` sont ignorés, et un
//  compteur qui n'a reçu aucun signe de vie depuis `staleAfter` est abandonné
//  (filet de sécurité, pas un chemin normal).
//

import Foundation
import Observation

/// Ce que les producteurs déclarent, avant toute décision d'affichage.
struct SyncWorkSnapshot: Equatable {
    /// Envois vers Pulse non terminés, toutes sources confondues (session BLE,
    /// rattrapage).
    var uploads = 0
    var ingestRunning = false
    /// Entrées restant à traiter dans la passe d'ingestion ; `nil` tant qu'aucun
    /// décompte fiable n'a été donné.
    var ingestRemaining: Int?
    var exchangeRunning = false
    var pullRunning = false
    /// Fichiers restant à rapatrier de Pulse dans la passe ; `nil` tant qu'aucun décompte
    /// fiable n'a été donné (manifeste en cours de lecture).
    var pullRemaining: Int?
}

/// Ce que les producteurs appellent, depuis n'importe quel fil.
protocol SyncWorkReporting: Sendable {
    /// Envois non terminés de `source` (une session BLE, un rattrapage) ; `0` la libère.
    func uploads(source: String, remaining: Int)
    func ingestBegan()
    /// Entrées restant à traiter dans la passe en cours.
    func ingestProgress(remaining: Int)
    func ingestEnded()
    func exchangeBegan()
    func exchangeEnded()
    /// Rapatriement des `.fit` depuis Pulse : même forme que l'ingestion.
    func pullBegan()
    func pullProgress(remaining: Int)
    func pullEnded()
}

/// Les producteurs d'avant le rapatriement n'ont rien à déclarer de plus.
extension SyncWorkReporting {
    func pullBegan() {}
    func pullProgress(remaining: Int) {}
    func pullEnded() {}
}

/// Anti-clignotement, PUR (aucune horloge : l'instant est un paramètre). Trois délais :
///  - `showDelay` : une activité plus brève ne s'affiche jamais ;
///  - `minVisible` : une fois affichée, la bannière reste au moins ce temps ;
///  - `hideLinger` : elle ne disparaît qu'après être restée retombée ce temps (deux
///    passes d'ingestion enchaînées ne la font pas clignoter entre elles).
/// Le CONTENU affiché suit l'activité voulue sans délai tant que la bannière est
/// visible (le décompte descend en direct).
struct SyncActivityGate: Equatable {
    var showDelay: TimeInterval = 0.4
    var minVisible: TimeInterval = 1.0
    var hideLinger: TimeInterval = 0.5

    private(set) var shown: SyncActivity = .idle
    private var wantedSince: Date?
    private var shownSince: Date?
    private var idleSince: Date?

    /// Intègre l'activité voulue à l'instant `now` ; rend le prochain instant où il
    /// faudra ré-évaluer (apparition ou disparition différée), `nil` si rien n'est en
    /// attente.
    @discardableResult
    mutating func update(desired: SyncActivity, now: Date) -> Date? {
        if desired == .idle {
            wantedSince = nil
            guard shown != .idle else {
                idleSince = nil
                return nil
            }
            let since = idleSince ?? now
            idleSince = since
            let hideAt = max(since.addingTimeInterval(hideLinger), (shownSince ?? now).addingTimeInterval(minVisible))
            if now >= hideAt {
                shown = .idle
                shownSince = nil
                idleSince = nil
                return nil
            }
            return hideAt
        }

        idleSince = nil
        if shown != .idle {
            shown = desired
            return nil
        }
        let since = wantedSince ?? now
        wantedSince = since
        let showAt = since.addingTimeInterval(showDelay)
        if now >= showAt {
            shown = desired
            shownSince = now
            wantedSince = nil
            return nil
        }
        return showAt
    }
}

@MainActor
@Observable
final class SyncWork {
    static let shared = SyncWork()

    /// Sans signe de vie (aucun début, progrès ni fin) depuis ce délai, un compteur est
    /// jugé coincé et abandonné. Largement au-dessus de toute attente réelle : une
    /// requête dure au plus quelques dizaines de secondes, et l'ingestion donne un
    /// signe de vie à chaque entrée.
    static let staleAfter: TimeInterval = 600

    /// Travail à montrer MAINTENANT (après décision de mode et anti-clignotement) — ce
    /// que la bannière lit.
    private(set) var displayed: SyncActivity = .idle
    /// Incrémenté à chaque fin d'activité (envois tous partis, passe d'ingestion
    /// terminée, échange terminé) : signal simple pour les écrans qui affichent des
    /// tailles ou des totaux (Paramètres › Stockage).
    private(set) var completions = 0

    private struct Counter {
        var remaining: Int
        var at: Date
    }

    @ObservationIgnored private var uploadSources: [String: Counter] = [:]
    @ObservationIgnored private var ingestRuns = 0
    @ObservationIgnored private var ingestRemaining: Int?
    @ObservationIgnored private var ingestAt = Date.distantPast
    @ObservationIgnored private var pullRuns = 0
    @ObservationIgnored private var pullRemaining: Int?
    @ObservationIgnored private var pullAt = Date.distantPast
    @ObservationIgnored private var exchangeRuns = 0
    @ObservationIgnored private var exchangeAt = Date.distantPast

    @ObservationIgnored private var gate: SyncActivityGate
    @ObservationIgnored private let mode: () -> StorageMode
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timer: WakeTimer

    init(
        gate: SyncActivityGate = SyncActivityGate(),
        mode: @escaping () -> StorageMode = { StorageModeStore.current },
        now: @escaping () -> Date = { Date() },
        timer: WakeTimer = TaskWakeTimer()
    ) {
        self.gate = gate
        self.mode = mode
        self.now = now
        self.timer = timer
    }

    // MARK: - Producteurs

    func setUploads(source: String, remaining: Int) {
        let before = uploadsTotal
        if remaining > 0 {
            uploadSources[source] = Counter(remaining: remaining, at: now())
        } else {
            uploadSources[source] = nil
        }
        if before > 0, uploadsTotal == 0 { completions += 1 }
        refresh()
    }

    func ingestBegan() {
        ingestRuns += 1
        ingestRemaining = nil
        ingestAt = now()
        refresh()
    }

    func ingestProgress(remaining: Int) {
        guard ingestRuns > 0 else { return }
        ingestRemaining = max(0, remaining)
        ingestAt = now()
        refresh()
    }

    func ingestEnded() {
        guard ingestRuns > 0 else { return }
        ingestRuns -= 1
        ingestAt = now()
        if ingestRuns == 0 {
            ingestRemaining = nil
            completions += 1
        }
        refresh()
    }

    func pullBegan() {
        pullRuns += 1
        pullRemaining = nil
        pullAt = now()
        refresh()
    }

    func pullProgress(remaining: Int) {
        guard pullRuns > 0 else { return }
        pullRemaining = max(0, remaining)
        pullAt = now()
        refresh()
    }

    func pullEnded() {
        guard pullRuns > 0 else { return }
        pullRuns -= 1
        pullAt = now()
        if pullRuns == 0 {
            pullRemaining = nil
            completions += 1
        }
        refresh()
    }

    func exchangeBegan() {
        exchangeRuns += 1
        exchangeAt = now()
        refresh()
    }

    func exchangeEnded() {
        guard exchangeRuns > 0 else { return }
        exchangeRuns -= 1
        exchangeAt = now()
        if exchangeRuns == 0 { completions += 1 }
        refresh()
    }

    // MARK: - Lecture

    private var uploadsTotal: Int { uploadSources.values.reduce(0) { $0 + $1.remaining } }

    /// Ce qui travaille à l'instant `at`, sans les compteurs coincés (abandonnés au
    /// passage).
    func snapshot(at instant: Date) -> SyncWorkSnapshot {
        let limit = Self.staleAfter
        uploadSources = uploadSources.filter { instant.timeIntervalSince($0.value.at) < limit }
        if ingestRuns > 0, instant.timeIntervalSince(ingestAt) >= limit {
            ingestRuns = 0
            ingestRemaining = nil
        }
        if pullRuns > 0, instant.timeIntervalSince(pullAt) >= limit {
            pullRuns = 0
            pullRemaining = nil
        }
        if exchangeRuns > 0, instant.timeIntervalSince(exchangeAt) >= limit { exchangeRuns = 0 }
        return SyncWorkSnapshot(
            uploads: uploadsTotal,
            ingestRunning: ingestRuns > 0,
            ingestRemaining: ingestRemaining,
            exchangeRunning: exchangeRuns > 0,
            pullRunning: pullRuns > 0,
            pullRemaining: pullRemaining)
    }

    /// Recalcule ce qu'il faut afficher (à appeler aussi au changement de mode) et
    /// arme UNE minuterie pour la prochaine échéance : apparition ou disparition
    /// différée de l'anti-clignotement, ou péremption d'un compteur.
    func refresh() {
        let instant = now()
        let desired = SyncActivity.fromWork(snapshot(at: instant), mode: mode())
        var next = gate.update(desired: desired, now: instant)
        if let expiry = earliestExpiry() {
            next = next.map { min($0, expiry) } ?? expiry
        }
        if gate.shown != displayed { displayed = gate.shown }
        if let next {
            timer.arm(after: max(0.05, next.timeIntervalSince(instant))) { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        } else {
            timer.cancel()
        }
    }

    private func earliestExpiry() -> Date? {
        var dates = uploadSources.values.map { $0.at }
        if ingestRuns > 0 { dates.append(ingestAt) }
        if pullRuns > 0 { dates.append(pullAt) }
        if exchangeRuns > 0 { dates.append(exchangeAt) }
        return dates.min().map { $0.addingTimeInterval(Self.staleAfter) }
    }
}

/// Production : relaie vers `SyncWork.shared` sur le main, dans l'ordre d'émission.
struct MainSyncWorkReporter: SyncWorkReporting {
    private func onMain(_ body: @escaping @MainActor @Sendable (SyncWork) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { body(SyncWork.shared) }
        }
    }

    func uploads(source: String, remaining: Int) { onMain { $0.setUploads(source: source, remaining: remaining) } }
    func ingestBegan() { onMain { $0.ingestBegan() } }
    func ingestProgress(remaining: Int) { onMain { $0.ingestProgress(remaining: remaining) } }
    func ingestEnded() { onMain { $0.ingestEnded() } }
    func exchangeBegan() { onMain { $0.exchangeBegan() } }
    func exchangeEnded() { onMain { $0.exchangeEnded() } }
    func pullBegan() { onMain { $0.pullBegan() } }
    func pullProgress(remaining: Int) { onMain { $0.pullProgress(remaining: remaining) } }
    func pullEnded() { onMain { $0.pullEnded() } }
}
