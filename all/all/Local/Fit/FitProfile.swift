//
//  FitProfile.swift
//  all (bridge-connect)
//
//  Sous-ensemble du profil FIT — juste les messages/champs qu'utilise le
//  chemin bien-être (miroir de `custom-connect/server/src/ingest/fit-parser.service.ts`,
//  méthodes `extractWellness`/`extractSleep`). Numéros de message globaux,
//  numéros de champ, échelles/décalages et valeurs d'énum tirés du profil
//  FIT installé LOCALEMENT (`custom-connect/server/node_modules/@garmin/fitsdk/src/profile.js`,
//  Profile Version 21.208.0) — lu sur disque, aucun réseau. Cf.
//  `docs/stockage-local.md` (incrément L1) pour le choix "décodeur maison".
//
//  Champs volontairement absents (hors périmètre bien-être) : tout ce qui
//  touche activités/GPS/sessions (L3+, cf. tâche d'incrément) reste décodé
//  générique (aucune entrée ici ⇒ échelle 1, décalage 0, cf. `FitDecoder`).
//

import Foundation

enum FitProfile {
    // MARK: - Numéros de message globaux (Profile.mesgNum)

    static let mesgFileId: UInt16 = 0
    static let mesgEvent: UInt16 = 21
    static let mesgMonitoring: UInt16 = 55
    static let mesgMonitoringInfo: UInt16 = 103
    static let mesgMonitoringHrData: UInt16 = 211
    static let mesgStressLevel: UInt16 = 227
    static let mesgSpo2Data: UInt16 = 269
    static let mesgSleepLevel: UInt16 = 275
    static let mesgRespirationRate: UInt16 = 297
    static let mesgSleepAssessment: UInt16 = 346

    // MARK: - Énum `file` (fileId.type) — classification wellness/sleep

    /// Directory=Monitoring, fichier "MonitorB" — c'est le type que
    /// `FitParserService.parse` teste (`fileType === 'monitoringB'`).
    static let fileTypeMonitoringB: Double = 32
    /// Type Garmin "sommeil" — absent du profil PUBLIC du SDK (pas de nom
    /// dans l'énum `file`), d'où le test `fileType === 'sleep' || fileType === '49'`
    /// côté serveur (le SDK renvoie le nombre brut faute de nom connu).
    static let fileTypeSleep: Double = 49

    // MARK: - Énum `activityType` — cf. `monitoring.activityType`/`monitoringInfo.activityType`

    static let activityTypeNames: [Int: String] = [
        0: "generic", 1: "running", 2: "cycling", 3: "transition",
        4: "fitnessEquipment", 5: "swimming", 6: "walking", 8: "sedentary", 254: "all",
    ]

    /// `STEP_ACTIVITY_TYPES` côté TS (`walking`, `running`) — valeurs d'énum.
    static let stepActivityTypeValues: Set<Int> = [1, 6]

    // MARK: - Énum `eventType` — cf. `extractSleep` (start/stop)

    static let eventTypeStart: Double = 0
    static let eventTypeStop: Double = 1

    // MARK: - Énum `sleepLevel`

    static let sleepLevelDeep: Double = 3
    static let sleepLevelLight: Double = 2
    static let sleepLevelRem: Double = 4
    // `awake` (1) et `unmeasurable` (0) retombent tous deux sur "awake" —
    // cf. `mapStage` dans `fit-parser.service.ts` (branche `else`).

    // MARK: - Métadonnées de champ (nom, échelle, décalage)

    struct FieldMeta {
        let name: String
        let scale: Double
        let offset: Double
    }

    private static let table: [UInt16: [UInt8: FieldMeta]] = [
        mesgFileId: [
            0: FieldMeta(name: "type", scale: 1, offset: 0),
        ],
        mesgMonitoringInfo: [
            253: FieldMeta(name: "timestamp", scale: 1, offset: 0),
            0: FieldMeta(name: "localTimestamp", scale: 1, offset: 0),
            5: FieldMeta(name: "restingMetabolicRate", scale: 1, offset: 0),
        ],
        mesgMonitoring: [
            253: FieldMeta(name: "timestamp", scale: 1, offset: 0),
            2: FieldMeta(name: "distance", scale: 100, offset: 0),
            3: FieldMeta(name: "cycles", scale: 2, offset: 0),
            4: FieldMeta(name: "activeTime", scale: 1000, offset: 0),
            5: FieldMeta(name: "activityType", scale: 1, offset: 0),
            19: FieldMeta(name: "activeCalories", scale: 1, offset: 0),
            26: FieldMeta(name: "timestamp16", scale: 1, offset: 0),
            27: FieldMeta(name: "heartRate", scale: 1, offset: 0),
            28: FieldMeta(name: "intensity", scale: 10, offset: 0),
        ],
        mesgMonitoringHrData: [
            253: FieldMeta(name: "timestamp", scale: 1, offset: 0),
            0: FieldMeta(name: "restingHeartRate", scale: 1, offset: 0),
            1: FieldMeta(name: "currentDayRestingHeartRate", scale: 1, offset: 0),
        ],
        mesgStressLevel: [
            0: FieldMeta(name: "stressLevelValue", scale: 1, offset: 0),
            1: FieldMeta(name: "stressLevelTime", scale: 1, offset: 0),
        ],
        mesgSpo2Data: [
            253: FieldMeta(name: "timestamp", scale: 1, offset: 0),
            0: FieldMeta(name: "readingSpo2", scale: 1, offset: 0),
        ],
        mesgRespirationRate: [
            253: FieldMeta(name: "timestamp", scale: 1, offset: 0),
            0: FieldMeta(name: "respirationRate", scale: 100, offset: 0),
        ],
        // `event` : champ 3 ("data", uint32) tel que documenté dans le
        // profil. En pratique, sur les échantillons dont on dispose (aucun
        // fichier "sleep"), la donnée transmise sur le fil est souvent la
        // variante 16 bits ("data16", champ 2) que le SDK réexpand en "data"
        // via son mécanisme de composants (bits) — non reproduit ici (hors
        // périmètre L1, aucun fichier sommeil pour le valider). On décode
        // AUSSI le champ 2 sous le nom "data16" en repli : `FitWellnessExtractor`
        // essaie `data` puis `data16`. Cf. rapport d'incrément L1.
        mesgEvent: [
            253: FieldMeta(name: "timestamp", scale: 1, offset: 0),
            0: FieldMeta(name: "event", scale: 1, offset: 0),
            1: FieldMeta(name: "eventType", scale: 1, offset: 0),
            2: FieldMeta(name: "data16", scale: 1, offset: 0),
            3: FieldMeta(name: "data", scale: 1, offset: 0),
        ],
        mesgSleepLevel: [
            253: FieldMeta(name: "timestamp", scale: 1, offset: 0),
            0: FieldMeta(name: "sleepLevel", scale: 1, offset: 0),
        ],
        mesgSleepAssessment: [
            6: FieldMeta(name: "overallSleepScore", scale: 1, offset: 0),
            11: FieldMeta(name: "awakeningsCount", scale: 1, offset: 0),
        ],
    ]

    static func fieldMeta(mesgNum: UInt16, fieldNum: UInt8) -> FieldMeta? {
        table[mesgNum]?[fieldNum]
    }
}
