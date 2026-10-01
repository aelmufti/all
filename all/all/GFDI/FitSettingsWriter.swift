//
//  FitSettingsWriter.swift
//  all (bridge-connect)
//
//  Écrit un fichier FIT « Settings » minimal (FILE_ID + un enregistrement
//  USER_PROFILE) que la montre accepte en upload pour mettre à jour le profil.
//  Seul le champ `weight` est porté : c'est le seul que la Venu 2 fw 19.05
//  honore réellement (vérifié matériel — les champs d'objectif d'intensité,
//  eux, sont acceptés dans le fichier puis ignorés, cf. CLAUDE.md / spike
//  objectif intensité). Reproduit octet pour octet la structure produite par
//  garmin-bridge (`GarminSession.buildUserProfileSettingsFile` + gadgetbridge
//  `FitFile`/`RecordDefinition`/`RecordData`, AGPL-3.0), validée contre le
//  matériel par `ProfileWeightFitTest`.
//
//  Détails de format hérités de gadgetbridge (à ne pas réapprendre) :
//  - En-tête FIT de 14 o, **little-endian** : taille=14, version protocole=16,
//    version profil=21117, dataSize (u32), magic « .FIT » (0x5449462E), puis
//    CRC16 de l'en-tête (o 0..11).
//  - Les enregistrements (définition + données) sont écrits **big-endian**
//    (octet d'architecture = 1) — c'est le choix de `FitRecordDataBuilder`.
//  - L'ordre des champs dans un enregistrement = l'ordre des appels `setX`
//    côté builder garmin-bridge (LinkedHashMap), **pas** l'ordre des numéros de
//    champ : pour FILE_ID c'est type, manufacturer, product, time_created,
//    serial_number, number.
//  - CRC16 final (2 o, little-endian) calculé sur la zone de données seule
//    (à partir de l'octet 14) — l'en-tête, CRC compris, contribue 0 au CRC.
//

import Foundation

enum FitSettingsWriter {

    // MARK: - Identifiants de base type FIT (BaseType.java, gadgetbridge)
    private enum BaseType {
        static let enumType: UInt8 = 0x00
        static let uint8: UInt8 = 0x02
        static let uint16: UInt8 = 0x84
        static let uint32: UInt8 = 0x86
        static let uint32z: UInt8 = 0x8C
    }

    private static let fitHeaderSize: UInt8 = 14
    private static let fitProtocolVersion: UInt8 = 16
    private static let fitProfileVersion: UInt16 = 21117
    private static let fitMagic: [UInt8] = [0x2E, 0x46, 0x49, 0x54] // « .FIT » (0x5449462E en LE)

    /// Valeur d'énumération FIT `file_id.type` pour un fichier Settings
    /// (`FileType.FILETYPE.SETTINGS(128, 2)` → 2).
    private static let fileTypeSettings: UInt8 = 2

    /// Poids en kg → fichier FIT Settings prêt à uploader. `timeCreated` en
    /// secondes epoch **Unix** (comme garmin-bridge, qui passe
    /// `System.currentTimeMillis()/1000` sans décalage epoch Garmin — la montre
    /// l'accepte tel quel).
    static func userProfileSettings(weightKg: Double, timeCreated: UInt32 = UInt32(Date().timeIntervalSince1970)) -> Data {
        // Poids : UINT16 à l'échelle 0.1 kg. Borné au plausible (25–300 kg) pour
        // ne jamais écrire une valeur aberrante dans le profil de la montre.
        let clampedKg = min(max(weightKg, 25), 300)
        let weightScaled = UInt16((clampedKg * 10).rounded())

        var records = Data()

        // --- FILE_ID (global msg 0) : définition (local 0) ---
        records.append(contentsOf: [
            0x40,       // en-tête d'enregistrement : bit définition (0x40) | local 0
            0x00,       // réservé
            0x01,       // architecture = 1 (big-endian)
            0x00, 0x00, // numéro de message global = 0 (big-endian)
            0x06,       // 6 champs
            // champ : numéro, taille, base type — ORDRE = appels setX côté pont
            0x00, 0x01, BaseType.enumType,  // type
            0x01, 0x02, BaseType.uint16,    // manufacturer
            0x02, 0x02, BaseType.uint16,    // product
            0x04, 0x04, BaseType.uint32,    // time_created
            0x03, 0x04, BaseType.uint32z,   // serial_number
            0x05, 0x02, BaseType.uint16,    // number
        ])
        // --- FILE_ID : données (local 0), big-endian ---
        records.append(0x00)                       // en-tête d'enregistrement (données, local 0)
        records.append(fileTypeSettings)           // type = SETTINGS (2)
        records.append(bigEndianU16(1))            // manufacturer = 1 (garmin)
        records.append(bigEndianU16(65534))        // product = 65534 (connect)
        records.append(bigEndianU32(timeCreated))  // time_created
        records.append(bigEndianU32(1))            // serial_number = 1
        records.append(bigEndianU16(1))            // number = 1

        // --- USER_PROFILE (global msg 3) : définition (local 0) ---
        records.append(contentsOf: [
            0x40,       // définition | local 0
            0x00,       // réservé
            0x01,       // big-endian
            0x00, 0x03, // numéro de message global = 3
            0x02,       // 2 champs
            0xFE, 0x02, BaseType.uint16,    // message_index
            0x04, 0x02, BaseType.uint16,    // weight
        ])
        // --- USER_PROFILE : données (local 0), big-endian ---
        records.append(0x00)                       // en-tête (données, local 0)
        records.append(bigEndianU16(0))            // message_index = 0
        records.append(bigEndianU16(weightScaled)) // weight (×10)

        return finishFitFile(records: records)
    }

    /// Assemble l'en-tête FIT (14 o, little-endian) + CRC d'en-tête, puis
    /// concatène la zone de données et le CRC final — factorisé entre
    /// `userProfileSettings` et `alarmSettings` (même structure, cf.
    /// commentaire d'en-tête de ce fichier).
    private static func finishFitFile(records: Data) -> Data {
        var header = Data()
        header.append(fitHeaderSize)
        header.append(fitProtocolVersion)
        header.append(littleEndianU16(fitProfileVersion))
        header.append(littleEndianU32(UInt32(records.count)))
        header.append(contentsOf: fitMagic)
        let headerCrc = Crc16.compute(header) // sur les 12 premiers octets
        header.append(littleEndianU16(headerCrc))

        var file = header
        file.append(records)
        let fileCrc = Crc16.compute(records) // en-tête (CRC inclus) contribue 0
        file.append(littleEndianU16(fileCrc))
        return file
    }

    /// Bit de répétition hebdomadaire Garmin pour un jour `Calendar.weekday`
    /// (1=dimanche..7=samedi, convention iOS/Foundation). Table reprise de
    /// gadgetbridge `model/Alarm.java` (`ALARM_MON=1, TUE=2, WED=4, THU=8,
    /// FRI=16, SAT=32, SUN=64`) — PAS l'ordre des bits du `Calendar` iOS, d'où
    /// la table de correspondance explicite plutôt qu'un simple décalage.
    /// Une entrée hors `1...7` renvoie 0 (ignorée par l'appelant, défensif).
    private static func garminWeekdayBit(forCalendarWeekday weekday: Int) -> UInt32 {
        switch weekday {
        case 1: return 64 // dimanche → ALARM_SUN
        case 2: return 1  // lundi    → ALARM_MON
        case 3: return 2  // mardi    → ALARM_TUE
        case 4: return 4  // mercredi → ALARM_WED
        case 5: return 8  // jeudi    → ALARM_THU
        case 6: return 16 // vendredi → ALARM_FRI
        case 7: return 32 // samedi   → ALARM_SAT
        default: return 0
        }
    }

    /// Planning de réveil hebdo (`Calendar` weekday 1..7 → minutes depuis
    /// minuit local, 0..1439) → fichier FIT Settings prêt à uploader vers la
    /// montre (FILE_ID type=SETTINGS + `alarm_settings` × N + `device_settings`),
    /// pour que la Venu 2 sonne une alarme native. Même canal d'upload que le
    /// poids (`userProfileSettings` / `GarminSession.writeWeight`).
    ///
    /// Numéros de message/champ FIT (introuvables dans le code source
    /// gadgetbridge, qui les génère à la compilation) retrouvés dans son
    /// générateur : `FitCodeGenerator/src/main/resources/fit_profile.json` —
    /// `ALARM_SETTINGS` = message global **222**, `DEVICE_SETTINGS` = **2**
    /// (champs `alarms_time`=8, `alarms_unk5`=9, `alarms_enabled`=28,
    /// `alarms_repeat`=92). Champs d'`alarm_settings` dans l'ORDRE des appels
    /// `setX` de `GarminSupport.onSetAlarms` (comme `FILE_ID`/`USER_PROFILE` plus
    /// haut) : `time`(0, UINT16 — minutes depuis minuit, cf.
    /// `FieldDefinitionAlarm.encode` : `hour*60+minute`, PAS le type "heure FIT"
    /// standard), `repeat`(1, UINT32Z — masque hebdo), `enabled`(2, ENUM),
    /// `sound`(3, ENUM), `backlight`(4, ENUM), `time_created`(5, UINT32),
    /// `snooze`(7, UINT8), `label`(8, ENUM `AlarmLabel`), `message_index`(254,
    /// UINT16).
    ///
    /// Défauts par alarme (repris de `onSetAlarms`, qui les tire de l'UI
    /// Gadgetbridge — ici fixes puisque notre API n'expose que jour+heure) :
    /// `enabled=1`, `sound=3` (code `TONE_AND_VIBRATION`, mapping
    /// `UNSET/TONE_AND_VIBRATION → 3`), `backlight=1`, `snooze=0`,
    /// `label=1` (`AlarmLabel.WAKE_UP`).
    ///
    /// Regroupement : les jours qui partagent la même heure (ex. Lun–Ven
    /// 07:00) deviennent UNE SEULE alarme à répétition hebdo (masque cumulé des
    /// bits `garminWeekdayBit`), plutôt que N alarmes à un seul jour —
    /// `onSetAlarms` reçoit déjà un objet `Alarm` par créneau avec son propre
    /// masque (le regroupement par heure n'a donc pas d'équivalent direct côté
    /// pont : c'est une décision prise ICI, nécessaire puisque notre API prend
    /// un planning par jour `Calendar.weekday → minutes`). Alarmes triées par
    /// heure croissante pour un `message_index` déterministe.
    ///
    /// Planning vide → fichier FILE_ID **seul** (pas de `device_settings` ni
    /// `alarm_settings`) : reproduit à l'identique `onSetAlarms`, qui n'écrit le
    /// message `device_settings` que `if (numberEnabledAlarms > 0)`. Effacer les
    /// alarmes existantes sur la montre n'est PAS le rôle de cette fonction
    /// (gadgetbridge non plus, au passage, ne le fait pas par ce chemin) —
    /// explicitement hors scope ici, à traiter côté appelant si besoin.
    static func alarmSettings(schedule: [Int: Int],
                              timeCreated: UInt32 = UInt32(Date().timeIntervalSince1970)) -> Data {
        var maskByMinutes: [Int: UInt32] = [:]
        for (weekday, minutes) in schedule {
            // Défensif : entrée hors contrat (weekday hors 1...7, minutes hors
            // 0..<1440) silencieusement ignorée plutôt que de produire un FIT
            // invalide — la validation du contrat vit côté appelant/API (cf.
            // `WakeScheduleLocalTests.putWithWeekday8Throws` etc., hors scope
            // de ce fichier).
            guard (1...7).contains(weekday), (0..<1440).contains(minutes) else { continue }
            let bit = garminWeekdayBit(forCalendarWeekday: weekday)
            maskByMinutes[minutes, default: 0] |= bit
        }
        let sortedMinutes = maskByMinutes.keys.sorted()

        var records = Data()

        // --- FILE_ID (global msg 0) : identique à `userProfileSettings` ---
        records.append(contentsOf: [
            0x40, 0x00, 0x01, 0x00, 0x00, 0x06,
            0x00, 0x01, BaseType.enumType,
            0x01, 0x02, BaseType.uint16,
            0x02, 0x02, BaseType.uint16,
            0x04, 0x04, BaseType.uint32,
            0x03, 0x04, BaseType.uint32z,
            0x05, 0x02, BaseType.uint16,
        ])
        records.append(0x00)
        records.append(fileTypeSettings)
        records.append(bigEndianU16(1))
        records.append(bigEndianU16(65534))
        records.append(bigEndianU32(timeCreated))
        records.append(bigEndianU32(1))
        records.append(bigEndianU16(1))

        guard !sortedMinutes.isEmpty else {
            return finishFitFile(records: records)
        }

        // --- ALARM_SETTINGS (global msg 222) : une définition, N enregistrements ---
        records.append(contentsOf: [
            0x40,       // définition | local 0
            0x00,       // réservé
            0x01,       // big-endian
            0x00, 0xDE, // numéro de message global = 222
            0x09,       // 9 champs
            0x00, 0x02, BaseType.uint16,   // time
            0x01, 0x04, BaseType.uint32z,  // repeat
            0x02, 0x01, BaseType.enumType, // enabled
            0x03, 0x01, BaseType.enumType, // sound
            0x04, 0x01, BaseType.enumType, // backlight
            0x05, 0x04, BaseType.uint32,   // time_created
            0x07, 0x01, BaseType.uint8,    // snooze
            0x08, 0x01, BaseType.enumType, // label
            0xFE, 0x02, BaseType.uint16,   // message_index
        ])
        for (index, minutes) in sortedMinutes.enumerated() {
            // `mask` ne peut pas être 0 ici (chaque entrée du planning porte au
            // moins un bit de jour) ; la sentinelle 128 de `onSetAlarms`
            // (répétition absente côté Gadgetbridge) ne s'applique donc jamais
            // en pratique — gardée en défense plutôt que pour être exercée.
            let mask = maskByMinutes[minutes] ?? 0
            records.append(0x00) // en-tête (données, local 0)
            records.append(bigEndianU16(UInt16(minutes)))
            records.append(bigEndianU32(mask == 0 ? 128 : mask))
            records.append(1) // enabled
            records.append(3) // sound = TONE_AND_VIBRATION
            records.append(1) // backlight
            records.append(bigEndianU32(timeCreated))
            records.append(0) // snooze
            records.append(1) // label = AlarmLabel.WAKE_UP
            records.append(bigEndianU16(UInt16(index))) // message_index
        }

        // --- DEVICE_SETTINGS (global msg 2) : tableaux parallèles, un élément
        //     par alarme, même ordre que `sortedMinutes` ci-dessus ---
        let n = sortedMinutes.count // ≤ 7 (un planning n'a qu'un slot par jour de semaine)
        records.append(contentsOf: [
            0x40,       // définition | local 0
            0x00,       // réservé
            0x01,       // big-endian
            0x00, 0x02, // numéro de message global = 2
            0x04,       // 4 champs
            0x08, UInt8(2 * n), BaseType.uint16,   // alarms_time[]
            0x09, UInt8(n), BaseType.enumType,     // alarms_unk5[]
            0x1C, UInt8(n), BaseType.enumType,      // alarms_enabled[] (28)
            0x5C, UInt8(4 * n), BaseType.uint32z,  // alarms_repeat[] (92)
        ])
        records.append(0x00) // en-tête (données, local 0)
        for minutes in sortedMinutes { records.append(bigEndianU16(UInt16(minutes))) }
        for _ in sortedMinutes { records.append(5) } // alarms_unk5 : constante 5, cf. onSetAlarms
        for _ in sortedMinutes { records.append(1) } // alarms_enabled : toutes activées
        for minutes in sortedMinutes {
            let mask = maskByMinutes[minutes] ?? 0
            records.append(bigEndianU32(mask == 0 ? 128 : mask))
        }

        return finishFitFile(records: records)
    }

    // MARK: - Petits encodeurs d'entiers

    private static func bigEndianU16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    private static func bigEndianU32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
    private static func littleEndianU16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func littleEndianU32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }
}
