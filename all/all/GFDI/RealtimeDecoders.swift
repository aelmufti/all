//
//  RealtimeDecoders.swift
//  all (bridge-connect)
//
//  Décodeurs PURS (aucun CoreBluetooth, aucun état, aucun effet de bord) pour les
//  charges utiles des services ML `REALTIME_*` de GFDI V2 (Micro-Link) — Live-2.
//  Portés de gadgetbridge upstream NON strippé (AGPL-3.0),
//  service/devices/garmin/communicator/v2/CommunicatorV2.java, classes internes
//  `RealtimeHeartRateCallback` / `RealtimeStepsCallback` /
//  `RealtimeAccelerometerCallback` / `RealtimeSpo2Callback` /
//  `RealtimeRespirationCallback` / `RealtimeHrvCallback` — précisément les
//  callbacks que garmin-bridge a retirés (`patches/CommunicatorV2-strip-realtime.patch`
//  dans le dépôt voisin) pour ne garder que le transport GFDI de fichiers.
//
//  MÉCANISME (tranché, preuves détaillées dans `all/docs/live2-realtime-design.md`) :
//  ce sont des SERVICES ML enregistrés par handle — même famille que le service
//  GFDI (code 1, déjà porté dans `CommunicatorV2.swift`) — PAS le protobuf
//  `GdiSmartProto`/`GdiSettingsService` (capacité « REALTIME_SETTINGS », champ 42) :
//  ce dernier concerne les écrans de préférences de la montre, sans rapport avec
//  les flux biométriques, et CLAUDE.md confirme qu'il ne répond jamais
//  applicativement sur cette Venu 2 (fw 19.05).
//
//  CE FICHIER NE BRANCHE RIEN — décodeurs PURS uniquement. C'est
//  `RealtimeSession.swift` (via `CommunicatorV2`, conforme à
//  `RealtimeMlCommunicating`) qui les branche : la FC en direct (service
//  `.heartRate` = `REALTIME_HR`) et les autres métriques connues (pas, SpO2,
//  respiration, VFC) sont désormais actives par défaut dès que l'app est au
//  premier plan et la montre connectée (`RealtimeSession.enableKnownMetrics`,
//  pilotée par `BLEManager.startRealtime`/`stopRealtime`) — plus de toggle
//  manuel pour elles ; remplace l'ancien profil BLE standard Heart Rate
//  (0x2A37, Live-1a, retiré de `BLEManager`, instable).
//

import Foundation

/// Codes de service ML `REALTIME_*`, tels qu'énumérés côté pont (gadgetbridge
/// upstream, `CommunicatorV2.Service`, non strippé). Purement informatif — ce
/// fichier ne les enregistre jamais (cf. en-tête). `calories`/`intensity`/
/// `stress`/`bodyBattery` n'ont NULLE PART dans l'écosystème (gadgetbridge,
/// garmin-bridge) de décodeur connu : la Venu 2 les expose vraisemblablement
/// (mêmes espace de codes, même mécanisme d'enregistrement que les six
/// implémentés), mais leur format de charge utile n'a jamais été documenté ni
/// rétro-ingénié par personne en amont — matériel + capture uniquement.
enum RealtimeMlService: UInt16 {
    case heartRate = 6
    case steps = 7
    /// Format INCONNU — jamais décodé nulle part dans l'écosystème gadgetbridge.
    case calories = 8
    /// Format INCONNU — idem.
    case intensity = 10
    case hrv = 12
    /// Format INCONNU — idem.
    case stress = 13
    case accelerometer = 16
    case spo2 = 19
    /// Format INCONNU — idem.
    case bodyBattery = 20
    case respiration = 21

    /// `true` si un décodeur existe ci-dessous ; `false` = hardware-only, à
    /// rétro-ingénier par capture avant de pouvoir écrire quoi que ce soit.
    var hasKnownDecoder: Bool {
        switch self {
        case .heartRate, .steps, .hrv, .accelerometer, .spo2, .respiration:
            return true
        case .calories, .intensity, .stress, .bodyBattery:
            return false
        }
    }
}

/// Fréquence cardiaque en direct via GFDI (service ML `REALTIME_HR` = 6) —
/// LA source de FC en direct de l'app (onglet Temps réel + push Pulse
/// `/api/live/hr` via `BLEManager.handleRealtimeHeartRate`) : remplace
/// l'ancien profil BLE standard Heart Rate (0x2A37, Live-1a — `LiveHeartRate
/// .Engine`/`.decode`, retirés, cf. `LiveHeartRate.swift`), instable (la
/// montre coupait sa diffusion FC d'elle-même). Port de
/// `RealtimeHeartRateCallback.onMessage` : le commentaire d'origine lui-même
/// est incertain sur le sens du premier octet (« 0/2/3? 3 == realtime? ») —
/// reproduit tel quel, non résolu, non vérifié contre le matériel.
struct RealtimeHeartRate: Equatable {
    /// Premier octet, sens incertain côté pont (voir doc ci-dessus).
    let rawType: UInt8
    let heartRate: UInt8
    let restingHeartRate: UInt8

    /// `nil` si la charge fait moins de 3 octets. Garde défensive absente côté
    /// pont (Java lit `value[0..2]` sans vérifier la longueur — un payload trop
    /// court y lèverait une exception ; ici on rend `nil`, cf. convention du
    /// reste du fichier `GarminByteIO.swift`).
    static func decode(_ data: Data) -> RealtimeHeartRate? {
        var reader = GarminByteReader(data)
        guard let type = reader.readUInt8(),
              let hr = reader.readUInt8(),
              let resting = reader.readUInt8() else { return nil }
        return RealtimeHeartRate(rawType: type, heartRate: hr, restingHeartRate: resting)
    }

    /// Cf. `if (hr > 0)` côté pont : `heartRate == 0` signifie « pas de valeur »,
    /// pas « 0 bpm ».
    var isValid: Bool { heartRate > 0 }
}

/// Pas en direct (service ML `REALTIME_STEPS` = 7). Port de
/// `RealtimeStepsCallback.onMessage` : deux entiers non signés 32 bits LE, pas
/// cumulés dans la journée et objectif du jour. Le pont calcule aussi un delta
/// depuis le dernier message (`steps - previousSteps`) ; ce calcul est **stateful**
/// (dépend du message précédent) et volontairement absent d'un décodeur pur — à
/// faire, le cas échéant, dans la couche appelante avec état (cf. doc de
/// conception, plan de câblage).
struct RealtimeSteps: Equatable {
    let steps: UInt32
    let goal: UInt32

    static func decode(_ data: Data) -> RealtimeSteps? {
        var reader = GarminByteReader(data)
        guard let steps = reader.readUInt32LE(), let goal = reader.readUInt32LE() else { return nil }
        return RealtimeSteps(steps: steps, goal: goal)
    }
}

/// Un échantillon accéléromètre (x, y, z) en m/s², convention Android telle que
/// documentée côté pont (axe z = -1g montre posée écran vers le haut) —
/// HYPOTHÈSE non vérifiée que CoreMotion/iOS utiliserait la même convention de
/// signe ; reproduit tel quel, à confronter au matériel avant tout usage réel.
struct RealtimeAccelerometerSample: Equatable {
    let x: Float
    let y: Float
    let z: Float
}

/// Trame accéléromètre en direct (service ML `REALTIME_ACCELEROMETER` = 16).
/// Port de `RealtimeAccelerometerCallback` — javadoc d'origine traduite :
///
/// Chaque message fait 16 octets :
/// - bits 0..12 : horodatage en millisecondes, boucle toutes les 8192 ms (PAS un
///   horodatage absolu) ;
/// - bits 13..15 : toujours 3 côté pont, nombre d'échantillons qui suivent ;
/// - bits 16..123 : 9 valeurs signées 12 bits, empaquetage en nibbles
///   little-endian, comme 3 échantillons (x, y, z) — les axes sont entrelacés,
///   pas groupés par axe ;
/// - bits 124..127 : toujours 1 côté pont, inconnu.
///
/// Messages consécutifs espacés d'environ 115,5 ms, donc les 3 échantillons
/// internes sont espacés d'environ 38,5 ms (26 Hz). 1 g = `scaleFactor` unités
/// brutes.
struct RealtimeAccelerometerFrame: Equatable {
    /// Horodatage 13 bits en millisecondes, boucle toutes les 8192 ms.
    let timestampMs13Bit: Int
    let samples: [RealtimeAccelerometerSample]

    private static let samplesOffset = 2
    private static let scaleFactor: Float = 256
    private static let gravity: Float = -9.81

    /// Exactement 16 octets, sinon `nil` (le pont journalise et abandonne ; idem
    /// ici). Rend aussi `nil` si `numSamples > 3` (valeur aberrante, cf. le garde
    /// équivalent côté pont).
    static func decode(_ data: Data) -> RealtimeAccelerometerFrame? {
        let bytes = [UInt8](data)
        guard bytes.count == 16 else { return nil }

        let header = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let timestamp = Int(header & 0x1FFF)
        let numSamples = Int(header >> 13)
        guard numSamples <= 3 else { return nil }

        var samples: [RealtimeAccelerometerSample] = []
        samples.reserveCapacity(numSamples)
        for i in 0..<numSamples {
            let x = accelSample(bytes, i * 3)
            let y = accelSample(bytes, i * 3 + 1)
            let z = accelSample(bytes, i * 3 + 2)
            samples.append(RealtimeAccelerometerSample(x: x, y: y, z: z))
        }
        return RealtimeAccelerometerFrame(timestampMs13Bit: timestamp, samples: samples)
    }

    /// Lit le i-ème échantillon signé 12 bits empaqueté en nibbles (cf. javadoc
    /// du type) et le convertit en m/s².
    private static func accelSample(_ bytes: [UInt8], _ i: Int) -> Float {
        let base = samplesOffset + (i / 2) * 3
        let raw: UInt32
        if i % 2 == 0 {
            raw = UInt32(bytes[base]) | (UInt32(bytes[base + 1] & 0x0F) << 8)
        } else {
            raw = UInt32(bytes[base + 1] >> 4) | (UInt32(bytes[base + 2]) << 4)
        }
        // Extension de signe 12 -> 32 bits, équivalent de `(raw << 20) >> 20` côté
        // pont (où `raw` est un `int` Java 32 bits, décalage silencieusement
        // débordant). `&<<` = décalage non piégeant (Swift lève sur débordement
        // avec `<<` simple) ; `Int32(bitPattern:)` réinterprète ensuite le motif
        // de bits comme signé, et `>>` sur un type signé est un décalage
        // arithmétique qui propage le bit de signe — mêmes deux propriétés que
        // Java ici.
        let signed = Int32(bitPattern: raw &<< 20) >> 20
        return Float(signed) * gravity / scaleFactor
    }
}

/// SpO2 en direct (service ML `REALTIME_SPO2` = 19). Port de
/// `RealtimeSpo2Callback.onMessage`.
struct RealtimeSpo2: Equatable {
    /// Signé : le pont ne considère la mesure valide que si `> 0` ; `<= 0`
    /// (notamment -1) signifie « pas de valeur ».
    let rawValue: Int8
    let garminTimestamp: UInt32

    /// 1 octet (spo2 signé) + 4 octets (horodatage Garmin, LE, non signé).
    static func decode(_ data: Data) -> RealtimeSpo2? {
        var reader = GarminByteReader(data)
        guard let rawByte = reader.readUInt8(), let ts = reader.readUInt32LE() else { return nil }
        return RealtimeSpo2(rawValue: Int8(bitPattern: rawByte), garminTimestamp: ts)
    }

    var isValid: Bool { rawValue > 0 }

    /// `nil` si `!isValid` — le commentaire du pont est explicite : « the ts is
    /// not valid in that case » quand la mesure elle-même ne l'est pas. Réutilise
    /// `GarminEpoch.offsetFromUnix` (`GarminFileType.swift`), déjà l'unique point
    /// de conversion epoch Garmin -> Unix du projet.
    var timestamp: Date? {
        guard isValid else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(garminTimestamp) + GarminEpoch.offsetFromUnix)
    }
}

/// Respiration en direct (service ML `REALTIME_RESPIRATION` = 21). Port de
/// `RealtimeRespirationCallback.onMessage` — le décodeur le plus mince côté pont :
/// aucun filtrage, aucune sentinelle codée en dur ; le commentaire d'origine note
/// juste que la valeur « peut être négative si inconnue, généralement -2 » SANS
/// que le pont ne s'appuie dessus (il journalise la valeur brute, point).
/// Reproduit à l'identique : valeur brute exposée, pas d'interprétation ici — non
/// confirmée contre le matériel.
struct RealtimeRespiration: Equatable {
    let breathsPerMinute: Int8

    static func decode(_ data: Data) -> RealtimeRespiration? {
        guard let first = data.first else { return nil }
        return RealtimeRespiration(breathsPerMinute: Int8(bitPattern: first))
    }
}

/// VFC / intervalle RR en direct (service ML `REALTIME_HRV` = 12 —
/// `onEnableRealtimeRrIntervals` côté interface pont `ICommunicator`, d'où le nom
/// choisi ici). Port de `RealtimeHrvCallback.onMessage` : les deux champs sont
/// nommés `rr`/`unk` côté pont SANS unité confirmée (probablement des
/// millisecondes pour l'intervalle RR, mais non vérifié contre le matériel —
/// reproduit tel quel, sans conversion inventée).
struct RealtimeHrv: Equatable {
    let rrIntervalRaw: UInt16
    let unknown: UInt32

    static func decode(_ data: Data) -> RealtimeHrv? {
        var reader = GarminByteReader(data)
        guard let rr = reader.readUInt16LE(), let unk = reader.readUInt32LE() else { return nil }
        return RealtimeHrv(rrIntervalRaw: rr, unknown: unk)
    }
}
