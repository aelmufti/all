//
//  RealtimeSession.swift
//  all (bridge-connect)
//
//  Couche de session pour les services ML `REALTIME_*` (Live-2, cf.
//  `all/docs/live2-realtime-design.md`) — analogue léger de `GarminSession.swift`
//  pour le temps réel : détient les toggles par métrique, reçoit les trames via
//  le callback de `CommunicatorV2` (`RealtimeMlCommunicating.onRealtimeFrame`),
//  décode les métriques connues via `RealtimeDecoders.swift` (décodeurs PURS,
//  réutilisés tels quels — rien n'est réécrit ici), publie les valeurs
//  (`@Published`), et calcule l'état **stateful** que les décodeurs purs ne font
//  pas par construction (delta de pas, cf. commentaire de `RealtimeSteps` et
//  doc §3.3).
//
//  PARALLÈLE à `GarminSession`, jamais couplé à elle : une `RealtimeSession` ne
//  touche jamais au handshake GFDI ni à la sync de fichiers — elle observe
//  seulement `onRealtimeFrame`, qui ne se déclenche jamais pour une trame GFDI
//  (cf. `CommunicatorV2.handleIncoming`, routage par handle).
//
//  DEUX régimes d'activation, jamais mélangés : les métriques CONNUES (FC,
//  pas, SpO2, respiration, VFC — cf. `enableKnownMetrics`/`disableKnownMetrics`)
//  sont désormais **toujours actives** tant que l'app est au premier plan et
//  la montre connectée (pilotées par `BLEManager.startRealtime`/`stopRealtime`,
//  plus de toggle utilisateur individuel pour elles) ; les services OPAQUES
//  (capture) restent strictement à la demande (toggle utilisateur explicite,
//  jamais automatique) — cf. `setCaptureEnabled`.
//
//  MODE CAPTURE (harnais octets bruts, EXCEPTION documentée à la règle
//  « on ne journalise jamais de donnée de santé ») : les quatre métriques
//  OPAQUES (stress, body battery, calories, intensité — cf.
//  `RealtimeMlService.hasKnownDecoder == false`) n'ont aucun décodeur connu
//  nulle part dans l'écosystème gadgetbridge (cf. doc §2.2) ; le seul moyen de
//  rétro-ingénier leur format est de capturer leurs octets bruts contre le
//  matériel. `setCaptureEnabled(_:for:)` active ce mode UNIQUEMENT pour un
//  service opaque donné, UNIQUEMENT sur toggle utilisateur explicite (jamais
//  par défaut), et journalise en local via `os.Logger` (Console.app, subsystem
//  "CleanYourRoom.all", catégorie "gfdi-realtime") — jamais de réseau, jamais
//  pour une métrique déjà décodée (`setEnabled` et `setCaptureEnabled` se
//  refusent mutuellement l'une l'autre catégorie de service, cf. leurs gardes).
//

import Foundation
import os

/// Session temps réel : une instance par lien BLE, détenue par `BLEManager`
/// comme `GarminSession` (cf. son commentaire de propriété).
final class RealtimeSession: ObservableObject {
    private let log = Logger(subsystem: "CleanYourRoom.all", category: "gfdi-realtime")

    /// Typé sur le protocole `RealtimeMlCommunicating` (pas `CommunicatorV2`) —
    /// même raison que `GarminSession.communicator` : rester testable avec un
    /// communicator factice, jamais de vrai CoreBluetooth/BLE en test.
    /// `CommunicatorV2` reste la seule conformance de production.
    private let communicator: RealtimeMlCommunicating

    /// Services `REALTIME_*` actuellement enregistrés côté montre — connus
    /// (décodés) et opaques (capture) confondus : source de vérité de ce qui a
    /// un handle ouvert, pour que l'UI reflète l'état réel plutôt qu'une
    /// intention locale non confirmée.
    @Published private(set) var enabledServices: Set<RealtimeMlService> = []

    // MARK: - Valeurs décodées (métriques connues)

    @Published private(set) var heartRate: RealtimeHeartRate?
    @Published private(set) var steps: RealtimeSteps?
    /// Delta stateful `steps - previousSteps` (cf. doc §3.3) — absent des
    /// décodeurs purs par construction (dépend du message précédent). `nil` tant
    /// qu'aucune paire de trames consécutives n'a été vue depuis la dernière
    /// (ré)activation de `.steps` (cf. `setEnabled`, qui réinitialise l'état).
    @Published private(set) var stepsDelta: Int?
    @Published private(set) var hrv: RealtimeHrv?
    @Published private(set) var accelerometer: RealtimeAccelerometerFrame?
    @Published private(set) var spo2: RealtimeSpo2?
    @Published private(set) var respiration: RealtimeRespiration?

    /// Précédente valeur de pas vue, pour le calcul du delta — état privé, ne
    /// fuit jamais hors de cette classe (contrairement à `stepsDelta`, publié).
    private var previousSteps: UInt32?

    // MARK: - Mode capture (harnais octets bruts, services opaques)

    /// Services opaques pour lesquels la capture est actuellement active — cf.
    /// commentaire d'en-tête. Distinct de `enabledServices` : un service peut
    /// être enregistré (`enabledServices`) SANS que sa capture soit active,
    /// l'inverse n'arrive jamais (`setCaptureEnabled` enregistre toujours le
    /// service en même temps qu'il active la capture, cf. son corps).
    @Published private(set) var captureEnabled: Set<RealtimeMlService> = []
    /// Nombre de trames journalisées depuis la dernière activation de la
    /// capture pour ce service — purement informatif pour l'UI (« combien de
    /// trames ai-je déjà capturées ») ; les octets eux-mêmes ne sont QUE dans
    /// Console.app, jamais retenus en mémoire ici (pas de tampon d'octets bruts
    /// dans l'app — cf. règle « ne pas journaliser/retenir de donnée de santé »
    /// hors de ce mode explicite, lui-même limité à `os.Logger`).
    @Published private(set) var captureFrameCounts: [RealtimeMlService: Int] = [:]

    init(communicator: RealtimeMlCommunicating) {
        self.communicator = communicator
        communicator.onRealtimeFrame = { [weak self] service, data in
            self?.handle(service: service, data: data)
        }
    }

    // MARK: - Toggles : métriques connues (décodées, jamais journalisées)

    /// Active/désactive une métrique CONNUE (cf. `RealtimeMlService.hasKnownDecoder
    /// == true`) — enregistre/ferme son service ML et republie sa valeur
    /// décodée. No-op avec un log d'erreur si appelé pour un service opaque
    /// (cf. `setCaptureEnabled`, le bon point d'entrée pour ceux-là) : garder
    /// les deux catégories strictement séparées évite qu'une métrique opaque se
    /// retrouve activée sans que son mode capture (donc sans journalisation
    /// d'octets bruts nulle part) ne serve à rien.
    func setEnabled(_ enabled: Bool, for service: RealtimeMlService) {
        guard service.hasKnownDecoder else {
            log.error("setEnabled ignoré pour \(String(describing: service), privacy: .public) : service opaque, sans décodeur — utiliser setCaptureEnabled")
            return
        }
        applyToggle(enabled, for: service)
    }

    // MARK: - Activation groupée : métriques connues « toujours actives »

    /// Métriques connues qui ont un affichage naturel en direct (onglet
    /// Temps réel) — PAS `.accelerometer` (aucun affichage naturel, cf.
    /// commentaire historique de `RealtimeMetricsList.knownMetrics`). FC en
    /// tête : c'est elle qui remplace désormais le chemin 0x2A37 (Live-1a,
    /// retiré de `BLEManager`).
    private static let alwaysOnKnownMetrics: [RealtimeMlService] = [.heartRate, .steps, .spo2, .respiration, .hrv]

    /// Active toutes les métriques connues « toujours actives » (cf.
    /// `alwaysOnKnownMetrics`) — appelé par `BLEManager` quand l'app est au
    /// premier plan et qu'un lien GFDI est établi (`startRealtime()`, ou dès
    /// la (re)construction d'une session sur un nouveau lien si l'intention
    /// premier-plan était déjà là). Remplace le toggle manuel individuel pour
    /// ces cinq services : plus d'activation à la demande pour elles (celle-ci
    /// reste la règle pour les services opaques, cf. `setCaptureEnabled`).
    /// Réutilise `setEnabled` (idempotent), donc idempotent elle-même.
    func enableKnownMetrics() {
        for service in Self.alwaysOnKnownMetrics {
            setEnabled(true, for: service)
        }
    }

    /// Désactive toutes les métriques connues « toujours actives » — appelé
    /// par `BLEManager.stopRealtime()` (passage en arrière-plan). Idempotent.
    func disableKnownMetrics() {
        for service in Self.alwaysOnKnownMetrics {
            setEnabled(false, for: service)
        }
    }

    // MARK: - Toggles : mode capture (services opaques, octets bruts)

    /// Active/désactive la CAPTURE d'un service OPAQUE (cf.
    /// `RealtimeMlService.hasKnownDecoder == false` : stress, body battery,
    /// calories, intensité) — enregistre son service ML et journalise en local
    /// (`os.Logger`) les octets bruts de chaque trame reçue tant que ce toggle
    /// est actif. C'est l'EXCEPTION explicite et gardée à la règle « pas de
    /// journalisation de donnée de santé » : le seul moyen connu de
    /// rétro-ingénier le format de ces quatre métriques (cf. doc §2.2/§3). No-op
    /// avec un log d'erreur si appelé pour un service déjà décodé.
    func setCaptureEnabled(_ enabled: Bool, for service: RealtimeMlService) {
        guard !service.hasKnownDecoder else {
            log.error("setCaptureEnabled ignoré pour \(String(describing: service), privacy: .public) : service déjà décodé — utiliser setEnabled, jamais de capture pour une métrique connue")
            return
        }
        if enabled {
            captureEnabled.insert(service)
            captureFrameCounts[service] = 0
        } else {
            captureEnabled.remove(service)
        }
        applyToggle(enabled, for: service)
    }

    /// Enregistrement/fermeture ML proprement dit — commun aux deux familles de
    /// toggle ci-dessus (connu vs capture), idempotent dans les deux sens (un
    /// second `enable`/`disable` sur un état déjà atteint n'émet rien de plus).
    private func applyToggle(_ enabled: Bool, for service: RealtimeMlService) {
        if enabled {
            guard !enabledServices.contains(service) else { return }
            enabledServices.insert(service)
            communicator.enableRealtimeService(service)
        } else {
            guard enabledServices.contains(service) else { return }
            enabledServices.remove(service)
            communicator.disableRealtimeService(service)
            resetDecodedValue(for: service)
        }
    }

    /// Efface la dernière valeur affichée (et l'état stateful associé) quand une
    /// métrique connue est désactivée — comme le faisait l'ancien
    /// `LiveHeartRate.Engine.stop()` (0x2A37, retiré) : une valeur figée après
    /// désactivation induirait en erreur (elle a l'air
    /// « en direct » alors que l'abonnement est coupé). No-op pour un service
    /// opaque (rien à effacer : jamais de valeur décodée pour eux).
    private func resetDecodedValue(for service: RealtimeMlService) {
        switch service {
        case .heartRate: heartRate = nil
        case .steps: steps = nil; stepsDelta = nil; previousSteps = nil
        case .hrv: hrv = nil
        case .accelerometer: accelerometer = nil
        case .spo2: spo2 = nil
        case .respiration: respiration = nil
        case .calories, .intensity, .stress, .bodyBattery: break
        }
    }

    // MARK: - Dispatch entrant (routage handle→service déjà fait par CommunicatorV2)

    /// Point d'entrée unique pour toute trame `REALTIME_*` — `CommunicatorV2` a
    /// déjà résolu le handle vers son `RealtimeMlService` (cf.
    /// `handleIncoming`/`processHandleManagement`) ; cette méthode ne fait que
    /// choisir décodage (connu) vs capture (opaque), jamais les deux à la fois.
    private func handle(service: RealtimeMlService, data: Data) {
        if service.hasKnownDecoder {
            decodeKnown(service, data)
        } else {
            captureIfEnabled(service, data)
        }
    }

    private func decodeKnown(_ service: RealtimeMlService, _ data: Data) {
        switch service {
        case .heartRate:
            heartRate = RealtimeHeartRate.decode(data)
        case .steps:
            guard let sample = RealtimeSteps.decode(data) else { return }
            if let previousSteps {
                stepsDelta = Int(sample.steps) - Int(previousSteps)
            }
            previousSteps = sample.steps
            steps = sample
        case .hrv:
            hrv = RealtimeHrv.decode(data)
        case .accelerometer:
            accelerometer = RealtimeAccelerometerFrame.decode(data)
        case .spo2:
            spo2 = RealtimeSpo2.decode(data)
        case .respiration:
            respiration = RealtimeRespiration.decode(data)
        case .calories, .intensity, .stress, .bodyBattery:
            break // jamais atteint (hasKnownDecoder == false) — garde exhaustive
        }
    }

    /// Journalise les octets bruts d'un service opaque SI ET SEULEMENT SI sa
    /// capture est active — cf. commentaire d'en-tête de fichier, l'exception
    /// gardée à la règle « pas de journalisation de donnée de santé ». Réutilise
    /// `Data.gfdiHexDump` (`GarminByteIO.swift`), déjà l'unique point de
    /// formatage hexadécimal du projet.
    private func captureIfEnabled(_ service: RealtimeMlService, _ data: Data) {
        guard captureEnabled.contains(service) else { return }
        let frameNumber = (captureFrameCounts[service] ?? 0) + 1
        captureFrameCounts[service] = frameNumber
        log.info("CAPTURE [\(String(describing: service), privacy: .public)] trame #\(frameNumber, privacy: .public) (\(data.count, privacy: .public) o) : \(data.gfdiHexDump, privacy: .public)")
    }
}
