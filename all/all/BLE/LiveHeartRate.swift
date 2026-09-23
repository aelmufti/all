//
//  LiveHeartRate.swift
//  all (bridge-connect)
//
//  Le pouls de la montre en direct, pris depuis le profil Bluetooth standard
//  Heart Rate (service 0000180D, caractéristique Heart Rate Measurement
//  00002A37) plutôt que depuis le protocole GFDI — portage fidèle de
//  garmin-bridge/src/main/java/net/garminbridge/session/LiveHeartRate.java.
//
//  Constaté sur une Venu 2, pont GFDI tenant le lien en parallèle : la
//  caractéristique 0x2A37 notifie sur un rythme régulier qu'on diffuse ou
//  non — `00 00` quand la diffusion FC est coupée, `06 4A` (drapeaux, puis
//  74 bpm) quand elle est active. Les deux services partagent le même lien
//  ACL plutôt que de se le disputer : un abonnement de plus sur une connexion
//  déjà ouverte, aucun protocole vendored en plus.
//
//  Trois faits séparés découlent de ce `00 00`, et c'est tout l'objet de ce
//  fichier :
//
//  1. La diffusion ne peut pas être activée depuis ici — c'est un menu sur le
//     poignet, et la montre l'arrête elle-même au bout d'un moment. Il faut
//     donc distinguer une montre qui ne diffuse pas (que l'utilisateur peut
//     corriger, et à qui on le dit) d'une montre devenue silencieuse (qu'il
//     ne peut pas corriger). Seule la première a un conseil : envoyer
//     quelqu'un dans le menu de diffusion parce que le lien est tombé est
//     pire que ne rien dire.
//  2. Un échantillon immuable écrase le précédent plutôt que de s'accumuler
//     dans une file : un lecteur lent ou absent ne coûte rien et ne perd que
//     des valeurs que personne n'allait regarder.
//  3. Un capteur optique laissé en marche pour rien est un coût que personne
//     n'a demandé — d'où l'abonnement à la demande, calé sur la présence
//     d'une vue live à l'écran côté SwiftUI (`onAppear`/`onDisappear`, cf.
//     `BLEManager.startLiveHeartRate`/`stopLiveHeartRate`).
//
//  Rien ici n'est jamais journalisé que « on »/« off » de l'abonnement —
//  jamais un bpm, jamais un horodatage de mesure (règle héritée du pont).
//
//  Volontairement libre de CoreBluetooth : le décodage prend du `Data` brut,
//  ce qui le rend testable sans matériel ni simulateur BLE (cf.
//  allTests/LiveHeartRateTests.swift). `BLEManager` fait le pont vers
//  `CBCharacteristic`/`CBUUID`.
//

import Foundation

enum LiveHeartRate {

    /// Combien de temps une mesure reste « en direct » avant d'être jugée
    /// périmée. La montre notifie environ une fois par seconde : cette marge
    /// large capture quand même un lien devenu silencieux en un peu plus d'un
    /// cycle de notification.
    static let staleAfter: TimeInterval = 10

    /// La seule phrase de ce fichier, et elle n'est montrée que quand elle
    /// est actionnable.
    static let notBroadcastingHint =
        "La montre ne diffuse pas sa fréquence cardiaque. L'activer sur la montre : "
        + "Paramètres > Capteurs et accessoires > Fréquence cardiaque au poignet > "
        + "Diffuser la FC. La montre arrête la diffusion d'elle-même au bout d'un "
        + "moment ; il faut alors la réactiver."

    /// Ce que l'UI affiche. `enabled` est notre abonnement, `broadcasting`
    /// est l'interrupteur de la montre, `stale` est l'état du lien : trois
    /// faits séparés à dessein — les fusionner en un seul statut est ce qui
    /// pousse une interface à dire aux gens de vérifier la mauvaise chose.
    struct Reading: Equatable {
        let enabled: Bool
        let broadcasting: Bool
        let heartRate: Int?
        let measuredAt: Date?
        let stale: Bool
        let hint: String?

        static let off = Reading(enabled: false, broadcasting: false, heartRate: nil, measuredAt: nil, stale: false, hint: nil)
    }

    /// Une trame décodée. Immuable, pour qu'un lecteur ne voie jamais une
    /// mise à jour à moitié faite.
    struct Sample {
        let heartRate: Int
        let broadcasting: Bool
        let at: Date
    }

    /// La disposition standard Heart Rate Measurement : un octet de
    /// drapeaux, puis la fréquence. Le bit 0 choisit entre une valeur sur 8
    /// ou 16 bits, le bit 2 dit si le capteur rapporte un contact — ce qui
    /// distingue une vraie trame de la trame vide envoyée quand la montre ne
    /// diffuse pas.
    ///
    /// Une trame plus courte que ce que ses propres drapeaux annoncent est
    /// ignorée plutôt que devinée : ça ne coûte rien de la rater, une autre
    /// arrive à la seconde suivante.
    static func decode(_ value: Data, now: Date) -> Sample? {
        guard value.count >= 2 else { return nil }
        let bytes = [UInt8](value)
        let flags = bytes[0]
        let sixteenBit = (flags & 0x01) != 0
        if sixteenBit && bytes.count < 3 { return nil }

        let heartRate: Int
        if sixteenBit {
            heartRate = Int(bytes[1]) | (Int(bytes[2]) << 8)
        } else {
            heartRate = Int(bytes[1])
        }

        // Une trame qui revendique la détection de contact vient d'un
        // capteur en marche, qu'il ait ou non un pouls à rapporter cette
        // seconde-là. La trame vide ne revendique rien : c'est ce qui les
        // distingue.
        let sensorReporting = (flags & 0x04) != 0
        return Sample(heartRate: heartRate, broadcasting: heartRate > 0 || sensorReporting, at: now)
    }

    /// Porte l'état mutable d'une session d'abonnement. Aucune dépendance
    /// CoreBluetooth : `BLEManager` lui pousse les trames décodées
    /// (`onFrame`) et interroge `reading(now:)` pour publier l'état affiché.
    /// Classe plutôt que struct : `BLEManager` en garde une seule instance
    /// pour la durée de vie de l'app, mutée en place au fil des trames — un
    /// value type imposerait de la réassigner à chaque appel pour rien.
    final class Engine {
        private var enabledAt: Date?
        private var last: Sample?

        /// Vrai tant que la vue live est affichée (abonnement demandé côté app).
        private(set) var isEnabled = false

        init() {}

        /// Démarre une nouvelle session. La fraîcheur se compte depuis cet
        /// instant tant qu'aucune trame n'est encore arrivée, pour ne pas
        /// afficher « périmé » ni « ne diffuse pas » juste après
        /// l'activation (warm-up).
        func start(now: Date) {
            last = nil
            enabledAt = now
            isEnabled = true
        }

        func stop() {
            last = nil
            enabledAt = nil
            isEnabled = false
        }

        /// Une notification de la montre, décodée et retenue. Aucun effet de
        /// bord sur `isEnabled` : comme côté pont, le décodage est
        /// inconditionnel — c'est `reading(now:)` qui décide si la valeur
        /// compte.
        func onFrame(_ value: Data, now: Date) {
            if let sample = LiveHeartRate.decode(value, now: now) {
                last = sample
            }
        }

        /// Traduit le dernier échantillon en les trois faits, dans l'ordre
        /// qui décide lequel montrer à l'utilisateur.
        ///
        /// La fraîcheur se juge depuis la dernière trame reçue si elle
        /// existe, sinon depuis le démarrage — un flux qui vient d'être
        /// activé est en warm-up plutôt que périmé, et surtout n'est pas
        /// rapporté comme une montre qui refuse de diffuser, ce qui est une
        /// instruction différente à une personne différente.
        func reading(now: Date) -> Reading {
            guard isEnabled, let enabledAt else { return .off }
            let lastHeardFrom = last?.at ?? enabledAt

            if now.timeIntervalSince(lastHeardFrom) > LiveHeartRate.staleAfter {
                // Rien de récent. Ce qui cloche n'est pas dans les menus de
                // la montre, donc pas de conseil.
                return Reading(enabled: true, broadcasting: false, heartRate: nil, measuredAt: nil, stale: true, hint: nil)
            }
            guard let last else {
                return Reading(enabled: true, broadcasting: false, heartRate: nil, measuredAt: nil, stale: false, hint: nil)
            }
            guard last.broadcasting else {
                return Reading(enabled: true, broadcasting: false, heartRate: nil, measuredAt: nil, stale: false, hint: LiveHeartRate.notBroadcastingHint)
            }

            // Rapportés ensemble ou pas du tout : une fréquence sans son
            // horodatage inviterait un affichage incapable de dire son âge.
            let heartRate = last.heartRate > 0 ? last.heartRate : nil
            return Reading(enabled: true, broadcasting: true, heartRate: heartRate, measuredAt: heartRate == nil ? nil : last.at, stale: false, hint: nil)
        }
    }
}
