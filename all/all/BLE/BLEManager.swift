//
//  BLEManager.swift
//  all (bridge-connect)
//
//  Harnais de mesure de l'incrément 1 (Go/No-Go du projet) : établit et
//  maintient un lien BLE générique avec la montre — AUCUN protocole GFDI,
//  juste un abonnement à une caractéristique de notification, pour mesurer
//  la stabilité du lien en arrière-plan (CADRAGE §8, incrément 1).
//
//  Les 5 métriques attendues sont journalisées via os.Logger (subsystem
//  "CleanYourRoom.all", category "ble") ; lecture dans Console.app en
//  filtrant sur ce subsystem, sur device réel (le simulateur ne fait pas
//  de vrai BLE arrière-plan).
//
//  Depuis le pivot premier-plan (SESSION-NOTES 2026-09-22), le harnais de
//  restauration d'état de cet incrément sert un objectif différent de celui
//  pour lequel il a été écrit : l'app n'a plus besoin de survivre en tâche de
//  fond, mais elle doit annoncer un état de connexion **véridique** à chaque
//  retour au premier plan. Or `CBPeripheral.state` restitué par
//  `willRestoreState` peut valoir `.connected` alors que le lien réel est mort
//  (cf. `centralManager(_:willRestoreState:)`) : ce fichier ne fait donc plus
//  jamais confiance à ce `.connected` restauré tel quel — voir
//  `checkLinkLivenessIfRevalidating`/`isLinkProvenLive` pour la revalidation,
//  et `revalidateOnForeground` pour le hook appelé par `allApp.swift` à chaque
//  retour au premier plan.
//

import CoreBluetooth
import Foundation
import Combine
import os

/// État de connexion applicatif, distinct du `CBManagerState` du radio.
enum BLEConnectionState: String {
    case disconnected = "Déconnecté"
    case scanning = "Scan…"
    case connecting = "Connexion…"
    /// CoreBluetooth affirme un lien (restauré, ou présumé toujours actif au
    /// retour au premier plan) mais on ne l'a pas encore **prouvé** exploitable
    /// (canal GFDI ouvert, ou abonnement générique confirmé) — distinct de
    /// `.connecting` (première connexion, aucune ambiguïté de fraîcheur) pour
    /// que l'UI ne mente jamais en affichant `.connected` par anticipation.
    case reconnecting = "Reconnexion…"
    case connected = "Connecté"
}

/// Un périphérique repéré pendant le scan, présenté dans la liste de sélection.
struct DiscoveredPeripheral: Identifiable {
    let id: UUID          // identifiant CoreBluetooth (UUID par app/appareil)
    let name: String
    let rssi: Int
}

/// Manager BLE singleton, observable par la vue de diagnostic.
///
/// Reconnexion **sans scan** dès qu'un identifiant CoreBluetooth est connu :
/// `retrievePeripherals(withIdentifiers:)` puis `connect(_:)`, qui n'a pas de
/// timeout côté CoreBluetooth — c'est cet appel qui porte la mesure de la
/// métrique 3 (latence retour-de-portée → reconnexion). L'identifiant persisté
/// est celui de CoreBluetooth (UUID par app/appareil), **pas** l'adresse MAC :
/// iOS ne l'expose pas.
final class BLEManager: NSObject, ObservableObject {
    static let shared = BLEManager()

    /// Identifiant de restauration d'état — constant, stable entre lancements.
    static let restoreIdentifier = "CleanYourRoom.all.ble.centralManager"

    /// Aucune cible Garmin présumée ici (le CADRAGE cite HR/180D à titre
    /// d'exemple, pas une garantie sur la Venu 2) : `nil` = on s'abonne à la
    /// première caractéristique notifiable trouvée, tous services confondus.
    /// Fixer un UUID pour cibler/filtrer un service précis au scan si besoin.
    static let targetServiceUUID: CBUUID? = nil

    private static let peripheralIDKey = "ble.peripheralIdentifier"

    private let log = Logger(subsystem: "CleanYourRoom.all", category: "ble")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notifyingCharacteristic: CBCharacteristic?

    // MARK: - Chemin GFDI V2 (Micro-Link)
    //
    // Caractéristiques accumulées au fil des découvertes CoreBluetooth (une par
    // service, asynchrone) ; une fois toutes reçues, on décide une seule fois si
    // le périphérique expose le service ML/GFDI V2 (auquel cas on bascule sur
    // CommunicatorV2/GarminSession) ou non (repli sur l'abonnement générique de
    // l'incrément 1).
    private var characteristicsByUUID: [CBUUID: CBCharacteristic] = [:]
    private var discoveredCharacteristicsOrder: [CBCharacteristic] = []
    private var pendingCharacteristicDiscoveries = 0

    private var garminCommunicator: CommunicatorV2?
    /// Session GFDI active, si la montre expose le service ML V2. `nil` tant que
    /// la découverte n'a pas tranché ou si le périphérique ne parle pas V2.
    @Published private(set) var garminSession: GarminSession?
    /// Abonnement à `GarminSession.state` — sert uniquement à savoir **quand**
    /// requalifier un lien en cours de revalidation comme réellement exploitable
    /// (cf. `checkLinkLivenessIfRevalidating`). Ne duplique aucune logique
    /// métier de `GarminSession` (fichier non modifié ici) : on observe juste son
    /// état publié, en lecture seule. Annulé et reconstruit à chaque nouveau lien
    /// par `resetGfdiDiscoveryState`.
    private var garminSessionStateSubscription: AnyCancellable?

    /// Une seule instance pour la durée de vie de l'app — partagée entre les
    /// `GarminSession` successives (une par lien BLE) pour ne pas relire le
    /// journal de spool à chaque reconnexion. `nil` si l'initialisation échoue
    /// (Application Support inaccessible) : journalisé au premier lien GFDI,
    /// cf. `activateProtocolIfPossible`.
    private let spoolStore: SpoolStore? = try? SpoolStore()

    /// Une seule `URLSession` (foreground, `.default`) pour la durée de vie de
    /// l'app, partagée entre les `GarminSession` successives — cf.
    /// `Sync/PulseUploader.swift` (émission active, autorisation utilisateur
    /// 2026-09-22).
    private let pulseUploader: SpoolUploading = PulseSpoolUploader()

    /// Intention de maintenir le lien (modèle keeper). Mis à `false` par
    /// `forgetDevice()` pour qu'une déconnexion **volontaire** ne relance pas la
    /// reconnexion automatique. Sans ce garde-fou, `cancelPeripheralConnection`
    /// déclencherait `didDisconnectPeripheral` → reconnexion sur l'appareil oublié.
    private var shouldReconnect = false

    // MARK: - Revalidation d'un lien restauré/présumé (véracité de `.connected`)

    /// Délai laissé à un périphérique restauré (ou présumé connecté au retour au
    /// premier plan) pour prouver que son lien est réellement exploitable, avant
    /// qu'on le considère mort. CoreBluetooth ne borne pas ce délai lui-même : un
    /// `.connected` restauré peut être un reliquat arbitrairement périmé (cf.
    /// `willRestoreState`), et son supervision timeout réel peut être bien plus
    /// long que ce qu'on est prêt à attendre côté UI. Valeur choisie dans la
    /// fourchette « raisonnable » suggérée (8–12 s) ; NON MESURÉE contre le
    /// matériel — à ajuster si trop d'allers-retours `.reconnecting` inutiles
    /// sont observés en usage réel.
    private static let revalidationTimeout: TimeInterval = 10

    /// Filet de sécurité : si aucune preuve de lien exploitable n'arrive avant
    /// expiration, on force `cancelPeripheralConnection` (cf. `revalidationTimedOut`)
    /// plutôt que de rester indéfiniment sur `.reconnecting`.
    private var revalidationTimer: Timer?

    // MARK: - État publié (vue de diagnostic)

    @Published private(set) var centralState: CBManagerState = .unknown
    @Published private(set) var connectionState: BLEConnectionState = .disconnected
    @Published private(set) var peripheralName: String?
    @Published private(set) var peripheralIdentifier: String?
    @Published private(set) var notificationCount: Int = 0

    /// Périphériques repérés pendant le scan courant, triés par RSSI décroissant,
    /// pour que l'utilisateur choisisse lequel connecter (plutôt qu'une connexion
    /// automatique au premier venu). Réfs `CBPeripheral` gardées à part.
    @Published private(set) var discovered: [DiscoveredPeripheral] = []
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    // MARK: - Horodatages des mesures (métriques 1, 3, 5)

    /// Métrique 1 — ouverture de la fenêtre de connexion courante.
    private var connectWindowStartedAt: Date?
    /// Métrique 3 — instant où l'on redemande la connexion (juste après une
    /// chute) ; la latence est mesurée jusqu'au `didConnect` suivant. NB :
    /// CoreBluetooth ne distingue pas « montre hors portée » de « montre en
    /// portée mais pas encore reconnectée » — cette latence englobe donc les
    /// deux (à noter en interprétant la mesure).
    private var reconnectRequestedAt: Date?
    /// Métrique 5 — dernière notification GATT reçue, pour le delta à la chute.
    private var lastNotificationAt: Date?

    private override init() {
        super.init()
        let options: [String: Any] = [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ]
        central = CBCentralManager(delegate: self, queue: nil, options: options)
        log.info("CBCentralManager créé (restoreIdentifier=\(Self.restoreIdentifier, privacy: .public))")
    }

    // MARK: - Commandes utilisateur (vue de diagnostic)

    /// Reconnexion automatique (keeper / restauration) : reconnexion directe si un
    /// identifiant est connu (pas de scan), sinon démarre un scan de découverte.
    func connectOrScan() {
        guard central.state == .poweredOn else {
            log.warning("connectOrScan ignoré : centralState=\(self.central.state.rawValue)")
            return
        }
        if let savedID = Self.savedPeripheralIdentifier(),
           let known = central.retrievePeripherals(withIdentifiers: [savedID]).first {
            log.info("Reconnexion par identifiant connu \(savedID.uuidString, privacy: .public)")
            connect(known)
        } else {
            startScan()
        }
    }

    /// Lance un scan de découverte manuel : vide la liste et repère les
    /// périphériques sans se connecter (l'utilisateur choisit ensuite).
    func scan() {
        guard central.state == .poweredOn else {
            log.warning("scan ignoré : centralState=\(self.central.state.rawValue)")
            return
        }
        discovered = []
        discoveredPeripherals = [:]
        startScan()
    }

    /// Arrête le scan de découverte en cours.
    func stopScan() {
        central.stopScan()
        if connectionState == .scanning { connectionState = .disconnected }
        log.info("Scan arrêté")
    }

    /// Connecte le périphérique choisi dans la liste (arrête le scan d'abord).
    func connect(to identifier: UUID) {
        guard let chosen = discoveredPeripherals[identifier] else {
            log.warning("connect(to:) ignoré : \(identifier.uuidString, privacy: .public) absent de la liste")
            return
        }
        central.stopScan()
        log.info("Sélection manuelle : \(identifier.uuidString, privacy: .public) name=\(chosen.name ?? "?", privacy: .public)")
        connect(chosen)
    }

    /// Oublie l'appareil : purge l'identifiant persisté et coupe la connexion en cours.
    func forgetDevice() {
        shouldReconnect = false
        stopRevalidationWatchdog()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        UserDefaults.standard.removeObject(forKey: Self.peripheralIDKey)
        peripheral = nil
        notifyingCharacteristic = nil
        resetGfdiDiscoveryState()
        peripheralName = nil
        peripheralIdentifier = nil
        connectWindowStartedAt = nil
        reconnectRequestedAt = nil
        lastNotificationAt = nil
        notificationCount = 0
        connectionState = .disconnected
        log.info("Appareil oublié")
    }

    private func startScan() {
        connectionState = .scanning
        let services = Self.targetServiceUUID.map { [$0] }
        central.scanForPeripherals(withServices: services, options: nil)
        log.info("Scan démarré (filtre service=\(services == nil ? "aucun" : services!.map(\.uuidString).joined(), privacy: .public))")
    }

    private func connect(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        shouldReconnect = true
        connectionState = .connecting
        reconnectRequestedAt = Date()
        resetGfdiDiscoveryState()
        central.connect(peripheral, options: nil)
    }

    /// À appeler avant chaque tentative de connexion : les `CBCharacteristic`
    /// d'un lien précédent ne sont plus valables, et la décision V2/générique
    /// doit être reprise de zéro sur ce nouveau lien.
    private func resetGfdiDiscoveryState() {
        characteristicsByUUID = [:]
        discoveredCharacteristicsOrder = []
        pendingCharacteristicDiscoveries = 0
        garminCommunicator = nil
        garminSession = nil
        garminSessionStateSubscription?.cancel()
        garminSessionStateSubscription = nil
    }

    private static func savedPeripheralIdentifier() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: peripheralIDKey) else { return nil }
        return UUID(uuidString: raw)
    }

    private func persistPeripheralIdentifier(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: Self.peripheralIDKey)
    }

    // MARK: - Revalidation d'un lien restauré/présumé

    /// Hook de cycle de vie appelé par `allApp.swift` (via `scenePhase`) à
    /// chaque retour au premier plan. Un `.connected` affiché avant la mise en
    /// arrière-plan n'est PAS une garantie qu'il tienne toujours : l'app a pu
    /// passer un temps arbitraire suspendue, largement de quoi rater un vrai
    /// `didDisconnectPeripheral` si iOS l'avait livré pendant qu'on n'exécutait
    /// plus de code — CoreBluetooth ne rejoue ce callback qu'une fois, et pas
    /// forcément à la reprise. Plutôt que de faire confiance à un affichage figé,
    /// on repasse activement par la même revalidation que pour un périphérique
    /// restauré (cf. `willRestoreState`) : nouvelle découverte de services, qui
    /// recrée une `GarminSession` fraîche et rejoue la poignée de main GFDI en
    /// entier — c'est la preuve la plus rigoureuse qu'on ait d'un canal encore
    /// exploitable, pas un coût significatif (quelques allers-retours BLE locaux).
    func revalidateOnForeground() {
        guard let peripheral else { return }
        switch connectionState {
        case .connected:
            log.info("Revalidation au premier plan : lien présumé connecté re-vérifié avant affichage")
            connectionState = .reconnecting
            resetGfdiDiscoveryState()
            startRevalidationWatchdog(for: peripheral)
            peripheral.discoverServices(nil)
        case .reconnecting:
            // Une revalidation est déjà en cours (typiquement : `willRestoreState`
            // vient de nous y placer juste avant que la scène ne redevienne
            // active). On ne relance pas une seconde découverte en parallèle —
            // juste un réarmement défensif du filet de sécurité.
            startRevalidationWatchdog(for: peripheral)
        case .connecting, .scanning, .disconnected:
            break // rien à revalider : pas de lien présumé établi
        }
    }

    /// Preuve qu'un lien est réellement exploitable, PAS juste que CoreBluetooth
    /// rend `.connected` : sur le chemin GFDI (montre Garmin V2), le canal doit
    /// avoir réellement échangé CLOSE_ALL_REQ/RESP puis REGISTER_ML_REQ/RESP avec
    /// la montre (`GarminHandshakeState` a dépassé `.idle`) ; sur le repli
    /// générique (incrément 1, périphérique non-Garmin), la caractéristique
    /// notifiable doit être confirmée active par la montre elle-même
    /// (`isNotifying`), pas juste demandée de notre côté.
    private func isLinkProvenLive() -> Bool {
        if let session = garminSession {
            switch session.state {
            case .gfdiChannelOpen, .initialized, .listingDirectory, .listed:
                return true
            case .idle, .failed:
                return false
            }
        }
        if let notifyingCharacteristic {
            return notifyingCharacteristic.isNotifying
        }
        return false
    }

    /// À appeler à chaque nouvelle preuve possible (changement d'état
    /// `GarminSession`, confirmation d'abonnement générique). Ne fait rien si on
    /// n'est pas en train de revalider un lien — l'affichage `.connected` normal
    /// (connexion fraîche, cf. `didConnect`) n'est pas concerné par ce garde-fou.
    private func checkLinkLivenessIfRevalidating() {
        guard connectionState == .reconnecting else { return }
        guard isLinkProvenLive() else { return }
        stopRevalidationWatchdog()
        connectionState = .connected
        connectWindowStartedAt = Date()
        log.info("Revalidation réussie — lien confirmé exploitable, passage à Connecté")
    }

    private func startRevalidationWatchdog(for peripheral: CBPeripheral) {
        revalidationTimer?.invalidate()
        let timer = Timer(timeInterval: Self.revalidationTimeout, repeats: false) { [weak self] _ in
            self?.revalidationTimedOut(peripheral)
        }
        // `.common` plutôt que le mode par défaut : le timer doit se déclencher
        // même si le run loop principal est occupé par du suivi d'interaction UI
        // (scroll, etc.) au moment du retour au premier plan.
        RunLoop.main.add(timer, forMode: .common)
        revalidationTimer = timer
    }

    private func stopRevalidationWatchdog() {
        revalidationTimer?.invalidate()
        revalidationTimer = nil
    }

    /// Aucune preuve de lien exploitable n'est arrivée avant expiration : on
    /// considère le lien mort plutôt que de rester indéfiniment sur
    /// `.reconnecting`. `cancelPeripheralConnection` déclenche
    /// `didDisconnectPeripheral`, qui relance le modèle keeper (`shouldReconnect`
    /// est resté `true`) — reconnexion propre, sans scan, comme pour toute chute
    /// de lien détectée par CoreBluetooth lui-même.
    private func revalidationTimedOut(_ peripheral: CBPeripheral) {
        revalidationTimer = nil
        guard connectionState == .reconnecting else { return } // déjà tranché entre-temps
        log.warning("Revalidation expirée (\(Self.revalidationTimeout, privacy: .public)s) sans preuve de lien exploitable — lien considéré mort")
        central.cancelPeripheralConnection(peripheral)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    /// Métrique 4 — survie à une terminaison système : iOS relance l'app en
    /// arrière-plan sur évènement BLE et restitue l'état ici, **avant**
    /// `didUpdateState`. On journalise explicitement l'entrée dans ce callback :
    /// c'est la preuve que la restauration a eu lieu.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        log.info("MÉTRIQUE 4 — willRestoreState : restauration réussie, \(restored.count) périphérique(s) restitué(s)")
        for p in restored {
            log.info("  restauré : id=\(p.identifier.uuidString, privacy: .public) name=\(p.name ?? "?", privacy: .public) state=\(p.state.rawValue)")
            peripheral = p
            p.delegate = self
            peripheralName = p.name
            peripheralIdentifier = p.identifier.uuidString
            shouldReconnect = true
            if p.state == .connected {
                // NE PAS FAIRE CONFIANCE à ce `.connected` : c'est l'état que
                // CoreBluetooth avait mémorisé à la dernière terminaison du
                // process, pas une preuve que le lien tient *maintenant*. La
                // montre n'annonce qu'à UN seul companion à la fois ; si un autre
                // lien s'est substitué entre-temps, ou si la portée a été perdue
                // pendant que l'app était suspendue, iOS n'a aucune raison de le
                // savoir tant que le supervision timeout du lien précédent n'a
                // pas expiré — et iOS ne laisse pas régler ce délai (cf. CLAUDE.md,
                // risque rédhibitoire BLE). CoreBluetooth continuera donc de
                // rendre `.connected` ici, potentiellement pendant un long moment,
                // sur un lien en réalité mort. Afficher "Connecté" serait un
                // mensonge tant qu'on n'a pas nous-mêmes la preuve d'un canal
                // exploitable (poignée de main GFDI ouverte, ou abonnement
                // générique confirmé) — d'où l'état intermédiaire `.reconnecting`
                // le temps de la revalidation (cf. `checkLinkLivenessIfRevalidating`,
                // `isLinkProvenLive`), et le filet de sécurité `startRevalidationWatchdog`
                // si la preuve n'arrive jamais.
                connectionState = .reconnecting
                connectWindowStartedAt = Date()
                notificationCount = 0
                // Les services/caractéristiques découverts avant la terminaison ne
                // sont pas garantis intacts après restauration : on relance la
                // découverte pour retrouver la caractéristique notifiable (ou
                // rejouer la poignée de main GFDI en entier).
                resetGfdiDiscoveryState()
                startRevalidationWatchdog(for: p)
                p.discoverServices(nil)
            } else if p.state == .connecting {
                connectionState = .connecting
                reconnectRequestedAt = Date()
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralState = central.state
        log.info("didUpdateState : \(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        // Un périphérique déjà connu (restauré ou persisté) mais pas connecté :
        // on relance la connexion sans scan.
        if let peripheral, peripheral.state != .connected {
            connect(peripheral)
        } else if peripheral == nil, Self.savedPeripheralIdentifier() != nil {
            connectOrScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Nom d'annonce en secours : `peripheral.name` est souvent nil tant qu'on
        // n'est pas connecté ; l'advertisement porte parfois un nom local.
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName ?? "Sans nom"
        discoveredPeripherals[peripheral.identifier] = peripheral
        let entry = DiscoveredPeripheral(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let idx = discovered.firstIndex(where: { $0.id == entry.id }) {
            discovered[idx] = entry            // mise à jour du RSSI
        } else {
            discovered.append(entry)
            log.info("didDiscover : \(peripheral.identifier.uuidString, privacy: .public) name=\(name, privacy: .public) rssi=\(RSSI.intValue)")
        }
        discovered.sort { $0.rssi > $1.rssi }   // plus proche en haut
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let now = Date()
        if let requestedAt = reconnectRequestedAt {
            let latency = now.timeIntervalSince(requestedAt)
            log.info("MÉTRIQUE 3 — latence retour-de-portée → reconnexion : \(String(format: "%.3f", latency), privacy: .public)s")
        }
        reconnectRequestedAt = nil
        connectWindowStartedAt = now
        notificationCount = 0
        connectionState = .connected
        peripheralName = peripheral.name
        peripheralIdentifier = peripheral.identifier.uuidString
        persistPeripheralIdentifier(peripheral.identifier)
        log.info("didConnect : \(peripheral.identifier.uuidString, privacy: .public) — fenêtre de connexion ouverte")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("didFailToConnect : \(peripheral.identifier.uuidString, privacy: .public) erreur=\(error?.localizedDescription ?? "?", privacy: .public)")
        stopRevalidationWatchdog()
        guard shouldReconnect else {
            connectionState = .disconnected
            return
        }
        connectionState = .connecting
        // Modèle keeper : on retente sans scan (connect() n'a pas de timeout).
        reconnectRequestedAt = Date()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Toute déconnexion — volontaire, keeper, ou provoquée par
        // `revalidationTimedOut` — rend une éventuelle revalidation en cours
        // caduque : ce périphérique va être retenté depuis zéro plus bas.
        stopRevalidationWatchdog()
        let now = Date()
        // Métrique 1 — durée de la fenêtre de connexion qui vient de se terminer.
        if let start = connectWindowStartedAt {
            let duration = now.timeIntervalSince(start)
            log.info("MÉTRIQUE 1 — durée fenêtre de connexion : \(String(format: "%.3f", duration), privacy: .public)s")
        }
        // Métrique 2 — nombre de notifications reçues durant cette fenêtre.
        log.info("MÉTRIQUE 2 — notifications reçues dans la fenêtre : \(self.notificationCount)")
        // Métrique 5 — supervision timeout effectif (dernière notif → chute détectée).
        if let lastNotif = lastNotificationAt {
            let gap = now.timeIntervalSince(lastNotif)
            log.info("MÉTRIQUE 5 — délai dernière notification → chute détectée : \(String(format: "%.3f", gap), privacy: .public)s")
        }
        log.info("didDisconnectPeripheral : \(peripheral.identifier.uuidString, privacy: .public) erreur=\(error?.localizedDescription ?? "aucune", privacy: .public)")

        connectWindowStartedAt = nil
        lastNotificationAt = nil
        notifyingCharacteristic = nil

        // Déconnexion volontaire (appareil oublié) : ne pas relancer le keeper.
        guard shouldReconnect else {
            connectionState = .disconnected
            return
        }
        // Modèle keeper : reconnexion automatique, sans scan. C'est ce
        // `connect()` qui ouvre la fenêtre mesurée par la métrique 3.
        reconnectRequestedAt = now
        connectionState = .connecting
        central.connect(peripheral, options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log.error("didDiscoverServices erreur=\(error.localizedDescription, privacy: .public)")
            return
        }
        let services = peripheral.services ?? []
        pendingCharacteristicDiscoveries = services.count
        if services.isEmpty {
            activateProtocolIfPossible(on: peripheral)
            return
        }
        for service in services {
            log.info("service découvert : \(service.uuid.uuidString, privacy: .public)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log.error("didDiscoverCharacteristicsFor erreur=\(error.localizedDescription, privacy: .public)")
        } else {
            for characteristic in service.characteristics ?? [] {
                log.info("  caractéristique : \(characteristic.uuid.uuidString, privacy: .public) propriétés=\(characteristic.properties.rawValue)")
                characteristicsByUUID[characteristic.uuid] = characteristic
                discoveredCharacteristicsOrder.append(characteristic)
            }
        }

        // Décision V2/générique prise une seule fois, une fois les caractéristiques
        // de TOUS les services résolues (asynchrone, un rappel par service) —
        // sinon le service ML pourrait n'être que partiellement vu si un autre
        // service répond en premier.
        pendingCharacteristicDiscoveries -= 1
        if pendingCharacteristicDiscoveries <= 0 {
            activateProtocolIfPossible(on: peripheral)
        }
    }

    /// Bascule sur le chemin GFDI V2 (Micro-Link) si le périphérique expose la
    /// paire de caractéristiques ML connue ; sinon repli sur l'abonnement
    /// générique de l'incrément 1 (première caractéristique notifiable trouvée).
    private func activateProtocolIfPossible(on peripheral: CBPeripheral) {
        guard garminSession == nil else { return } // déjà décidé pour ce lien
        if let communicator = CommunicatorV2(peripheral: peripheral, characteristicsByUUID: characteristicsByUUID) {
            log.info("Service GFDI ML (V2) détecté — bascule sur le chemin GFDI")
            if spoolStore == nil {
                log.error("SpoolStore indisponible — le téléchargement de fichiers ne pourra pas écrire sur disque")
            }
            let session = GarminSession(communicator: communicator, spoolStore: spoolStore, uploader: pulseUploader)
            garminCommunicator = communicator
            garminSession = session
            // Observe l'état publié de la session pour savoir dès que le canal
            // GFDI s'ouvre (preuve de lien exploitable) — utile quand on est en
            // train de revalider un lien restauré/présumé (cf.
            // `checkLinkLivenessIfRevalidating`) ; sans effet sinon (le
            // `guard connectionState == .reconnecting` y renvoie tôt).
            garminSessionStateSubscription = session.$state
                .sink { [weak self] _ in self?.checkLinkLivenessIfRevalidating() }
            session.start()
            return
        }
        log.info("Aucune caractéristique ML connue — repli sur l'abonnement générique")
        subscribeToFirstNotifiableCharacteristic(on: peripheral)
    }

    private func subscribeToFirstNotifiableCharacteristic(on peripheral: CBPeripheral) {
        guard notifyingCharacteristic == nil else { return }
        for characteristic in discoveredCharacteristicsOrder {
            let notifiable = characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
            if notifiable {
                notifyingCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                log.info("abonnement générique demandé sur \(characteristic.uuid.uuidString, privacy: .public) (première caractéristique notifiable trouvée)")
                return
            }
        }
        log.warning("Aucune caractéristique notifiable trouvée sur ce périphérique")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log.error("didUpdateNotificationStateFor erreur=\(error.localizedDescription, privacy: .public)")
            return
        }
        log.info("didUpdateNotificationStateFor : \(characteristic.uuid.uuidString, privacy: .public) notifying=\(characteristic.isNotifying)")
        // Chemin générique (pas de GarminSession) : c'est ici, et seulement ici,
        // qu'on obtient la confirmation par la montre elle-même que l'abonnement
        // est actif — cf. `isLinkProvenLive`.
        checkLinkLivenessIfRevalidating()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log.error("didUpdateValueFor erreur=\(error.localizedDescription, privacy: .public)")
            return
        }
        lastNotificationAt = Date()
        notificationCount += 1
        log.info("didUpdateValueFor : \(characteristic.uuid.uuidString, privacy: .public) octets=\(characteristic.value?.count ?? 0) (compteur fenêtre=\(self.notificationCount))")

        if let garminCommunicator, characteristic.uuid == garminCommunicator.receiveCharacteristicUUID {
            garminCommunicator.handleIncoming(characteristic.value ?? Data())
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log.error("didWriteValueFor erreur=\(error.localizedDescription, privacy: .public) caractéristique=\(characteristic.uuid.uuidString, privacy: .public)")
        }
    }
}
