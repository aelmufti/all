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
//  Extension incrément L3 (`docs/stockage-local.md`) : messages/champs du
//  chemin ACTIVITÉ (`record`/`session`/`lap`/`set`/`split`/`timeInZone`/
//  `sport`/`activity`), miroir de `FitParserService.extractSummary`/
//  `parseDetail` (`custom-connect/server/src/ingest/fit-parser.service.ts`).
//  Mêmes numéros/échelles/décalages/énums, tirés du MÊME profil local
//  (`profile.js`, Profile Version 21.208.0) — extraits avec un petit script
//  Node jetable dans le scratchpad de session (`Profile.messages[N].fields`,
//  `Profile.types[name].values`), aucun réseau, puis CROISÉS contre un
//  décodage réel des 3 échantillons `activity` (`custom-connect/samples/*.fit`)
//  avec le SDK officiel — cf. rapport d'incrément pour le détail.
//
//  GPS (`positionLat`/`positionLong`) volontairement ABSENT : décision actée
//  de la tâche d'incrément, `ActivityDetail.track` reste toujours `[]` (pas de
//  carte/road-snapping en L3, cf. `FitActivityExtractor`) — décoder ces deux
//  champs n'aurait servi à rien.
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

    // Messages ACTIVITÉ (L3) — numéros vérifiés dans `profile.js` local
    // (`Profile.messages[N].num`), cf. en-tête de fichier.
    static let mesgSport: UInt16 = 12
    static let mesgSession: UInt16 = 18
    static let mesgLap: UInt16 = 19
    static let mesgRecord: UInt16 = 20
    static let mesgActivity: UInt16 = 34
    static let mesgTimeInZone: UInt16 = 216
    static let mesgSet: UInt16 = 225
    static let mesgSplit: UInt16 = 312

    // MARK: - Énum `file` (fileId.type) — classification wellness/sleep/activité

    /// Directory=Monitoring, fichier "MonitorB" — c'est le type que
    /// `FitParserService.parse` teste (`fileType === 'monitoringB'`).
    static let fileTypeMonitoringB: Double = 32
    /// Type Garmin "sommeil" — absent du profil PUBLIC du SDK (pas de nom
    /// dans l'énum `file`), d'où le test `fileType === 'sleep' || fileType === '49'`
    /// côté serveur (le SDK renvoie le nombre brut faute de nom connu).
    static let fileTypeSleep: Double = 49
    /// Fichier ACTIVITÉ (`fileType === 'activity'` côté TS) — critère de
    /// classification de `LocalIngestor` (L3, cf. `docs/stockage-local.md`).
    static let fileTypeActivity: Double = 4

    // MARK: - Énum `setType` — `set.setType`, `extractSets` ne garde que
    // les séries "actives" (jamais les paliers de repos).

    static let setTypeActive: Double = 1

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

    // MARK: - Énums ACTIVITÉ (L3) — tables COMPLÈTES (recopiées de
    // `Profile.types.<nom>.values` dans `profile.js` local, cf. en-tête de
    // fichier) : le SDK expose ces champs comme des NOMS (pas des nombres) —
    // `ActivityFormatting.swift`/`ActivityDetailView.swift` attendent déjà
    // ces mêmes clés anglaises (`"running"`, `"strengthTraining"`,
    // `"climbActive"`, `"tricepsExtension"`…), donc il faut les mêmes noms
    // ici, pas juste le numéro brut.

    static let sportNames: [Int: String] = [
        0: "generic", 1: "running", 2: "cycling", 3: "transition", 4: "fitnessEquipment",
        5: "swimming", 6: "basketball", 7: "soccer", 8: "tennis", 9: "americanFootball",
        10: "training", 11: "walking", 12: "crossCountrySkiing", 13: "alpineSkiing",
        14: "snowboarding", 15: "rowing", 16: "mountaineering", 17: "hiking", 18: "multisport",
        19: "paddling", 20: "flying", 21: "eBiking", 22: "motorcycling", 23: "boating",
        24: "driving", 25: "golf", 26: "hangGliding", 27: "horsebackRiding", 28: "hunting",
        29: "fishing", 30: "inlineSkating", 31: "rockClimbing", 32: "sailing", 33: "iceSkating",
        34: "skyDiving", 35: "snowshoeing", 36: "snowmobiling", 37: "standUpPaddleboarding",
        38: "surfing", 39: "wakeboarding", 40: "waterSkiing", 41: "kayaking", 42: "rafting",
        43: "windsurfing", 44: "kitesurfing", 45: "tactical", 46: "jumpmaster", 47: "boxing",
        48: "floorClimbing", 49: "baseball", 53: "diving", 56: "shooting", 58: "winterSport",
        59: "grinding", 62: "hiit", 63: "videoGaming", 64: "racket", 65: "wheelchairPushWalk",
        66: "wheelchairPushRun", 67: "meditation", 68: "paraSport", 69: "discGolf",
        70: "teamSport", 71: "cricket", 72: "rugby", 73: "hockey", 74: "lacrosse",
        75: "volleyball", 76: "waterTubing", 77: "wakesurfing", 78: "waterSport",
        79: "archery", 80: "mixedMartialArts", 81: "motorSports", 82: "snorkeling",
        83: "dance", 84: "jumpRope", 85: "poolApnea", 86: "mobility", 87: "geocaching",
        88: "canoeing", 254: "all",
    ]

    static let subSportNames: [Int: String] = [
        0: "generic", 1: "treadmill", 2: "street", 3: "trail", 4: "track", 5: "spin",
        6: "indoorCycling", 7: "road", 8: "mountain", 9: "downhill", 10: "recumbent",
        11: "cyclocross", 12: "handCycling", 13: "trackCycling", 14: "indoorRowing",
        15: "elliptical", 16: "stairClimbing", 17: "lapSwimming", 18: "openWater",
        19: "flexibilityTraining", 20: "strengthTraining", 21: "warmUp", 22: "match",
        23: "exercise", 24: "challenge", 25: "indoorSkiing", 26: "cardioTraining",
        27: "indoorWalking", 28: "eBikeFitness", 29: "bmx", 30: "casualWalking",
        31: "speedWalking", 32: "bikeToRunTransition", 33: "runToBikeTransition",
        34: "swimToBikeTransition", 35: "atv", 36: "motocross", 37: "backcountry",
        38: "resort", 39: "rcDrone", 40: "wingsuit", 41: "whitewater", 42: "skateSkiing",
        43: "yoga", 44: "pilates", 45: "indoorRunning", 46: "gravelCycling",
        47: "eBikeMountain", 48: "commuting", 49: "mixedSurface", 50: "navigate",
        51: "trackMe", 52: "map", 53: "singleGasDiving", 54: "multiGasDiving",
        55: "gaugeDiving", 56: "apneaDiving", 57: "apneaHunting", 58: "virtualActivity",
        59: "obstacle", 62: "breathing", 63: "ccrDiving", 65: "sailRace", 66: "expedition",
        67: "ultra", 68: "indoorClimbing", 69: "bouldering", 70: "hiit",
        71: "indoorGrinding", 72: "huntingWithDogs", 73: "amrap", 74: "emom",
        75: "tabata", 77: "esport", 78: "triathlon", 79: "duathlon", 80: "brick",
        81: "swimRun", 82: "adventureRace", 83: "truckerWorkout", 84: "pickleball",
        85: "padel", 86: "indoorWheelchairWalk", 87: "indoorWheelchairRun",
        88: "indoorHandCycling", 90: "field", 91: "ice", 92: "ultimate", 93: "platform",
        94: "squash", 95: "badminton", 96: "racquetball", 97: "tableTennis",
        98: "overland", 99: "trollingMotor", 110: "flyCanopy", 111: "flyParaglide",
        112: "flyParamotor", 113: "flyPressurized", 114: "flyNavigate", 115: "flyTimer",
        116: "flyAltimeter", 117: "flyWx", 118: "flyVfr", 119: "flyIfr",
        121: "dynamicApnea", 123: "enduro", 124: "rucking", 125: "rally",
        126: "poolTriathlon", 127: "eBikeEnduro", 254: "all",
    ]

    static let splitTypeNames: [Int: String] = [
        1: "ascentSplit", 2: "descentSplit", 3: "intervalActive", 4: "intervalRest",
        5: "intervalWarmup", 6: "intervalCooldown", 7: "intervalRecovery",
        8: "intervalOther", 9: "climbActive", 10: "climbRest", 11: "surfActive",
        12: "runActive", 13: "runRest", 14: "workoutRound", 17: "rwdRun",
        18: "rwdWalk", 21: "windsurfActive", 22: "rwdStand", 23: "transition",
        28: "skiLiftSplit", 29: "skiRunSplit",
    ]

    /// `exerciseCategory` — catégorie de haut niveau du champ `set.category`
    /// (PAS `categorySubtype`, non utilisé par `extractSets`/`ActivitySport.exerciseName`).
    static let exerciseCategoryNames: [Int: String] = [
        0: "benchPress", 1: "calfRaise", 2: "cardio", 3: "carry", 4: "chop", 5: "core",
        6: "crunch", 7: "curl", 8: "deadlift", 9: "flye", 10: "hipRaise", 11: "hipStability",
        12: "hipSwing", 13: "hyperextension", 14: "lateralRaise", 15: "legCurl",
        16: "legRaise", 17: "lunge", 18: "olympicLift", 19: "plank", 20: "plyo",
        21: "pullUp", 22: "pushUp", 23: "row", 24: "shoulderPress", 25: "shoulderStability",
        26: "shrug", 27: "sitUp", 28: "squat", 29: "totalBody", 30: "tricepsExtension",
        31: "warmUp", 32: "run", 33: "bike", 34: "cardioSensors", 35: "move", 36: "pose",
        37: "bandedExercises", 38: "battleRope", 39: "elliptical", 40: "floorClimb",
        41: "indoorBike", 42: "indoorRow", 43: "ladder", 44: "sandbag", 45: "sled",
        46: "sledgeHammer", 47: "stairStepper", 49: "suspension", 50: "tire",
        52: "runIndoor", 53: "bikeOutdoor", 65534: "unknown",
    ]

    /// Résout un nom d'énum avec repli sur la valeur numérique brute
    /// stringifiée — même comportement que le SDK JS pour une valeur d'énum
    /// SANS nom connu (`asString` sur un nombre : `String(value)`), cf.
    /// `extractSets`/`extractSplits` (TS), qui traitent ce repli comme une
    /// chaîne valide (pas `null`).
    private static func name(_ table: [Int: String], _ raw: Double) -> String {
        let i = Int(raw)
        return table[i] ?? String(i)
    }

    static func sportName(_ raw: Double) -> String { name(sportNames, raw) }
    static func subSportName(_ raw: Double) -> String { name(subSportNames, raw) }
    static func splitTypeName(_ raw: Double) -> String { name(splitTypeNames, raw) }
    static func exerciseCategoryName(_ raw: Double) -> String { name(exerciseCategoryNames, raw) }

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

        // MARK: Activité (L3) — numéros/échelles/décalages vérifiés dans
        // `profile.js` local, cf. en-tête de fichier.

        mesgRecord: [
            253: FieldMeta(name: "timestamp", scale: 1, offset: 0),
            3: FieldMeta(name: "heartRate", scale: 1, offset: 0),
            5: FieldMeta(name: "distance", scale: 100, offset: 0),
            // `speed`/`altitude` (16 bits, anciens champs) ET leurs variantes
            // `enhanced*` (32 bits) sont décodées séparément — le mécanisme de
            // "composants" FIT (qui dériverait l'un de l'autre au décodage)
            // n'est PAS reproduit ici (hors périmètre, cf. `FitDecoder`), mais
            // les 3 échantillons d'activité dont on dispose montrent que la
            // Venu 2 n'émet QUE les champs `enhanced*` sur le fil — décoder
            // aussi les anciens champs est une robustesse gratuite (autre
            // matériel/export), `FitActivityExtractor` privilégie `enhanced*`.
            6: FieldMeta(name: "speed", scale: 1000, offset: 0),
            73: FieldMeta(name: "enhancedSpeed", scale: 1000, offset: 0),
            2: FieldMeta(name: "altitude", scale: 5, offset: 500),
            78: FieldMeta(name: "enhancedAltitude", scale: 5, offset: 500),
        ],
        mesgSession: [
            2: FieldMeta(name: "startTime", scale: 1, offset: 0),
            5: FieldMeta(name: "sport", scale: 1, offset: 0),
            6: FieldMeta(name: "subSport", scale: 1, offset: 0),
            7: FieldMeta(name: "totalElapsedTime", scale: 1000, offset: 0),
            8: FieldMeta(name: "totalTimerTime", scale: 1000, offset: 0),
            9: FieldMeta(name: "totalDistance", scale: 100, offset: 0),
            11: FieldMeta(name: "totalCalories", scale: 1, offset: 0),
            16: FieldMeta(name: "avgHeartRate", scale: 1, offset: 0),
            17: FieldMeta(name: "maxHeartRate", scale: 1, offset: 0),
        ],
        mesgLap: [
            7: FieldMeta(name: "totalElapsedTime", scale: 1000, offset: 0),
            8: FieldMeta(name: "totalTimerTime", scale: 1000, offset: 0),
            9: FieldMeta(name: "totalDistance", scale: 100, offset: 0),
            15: FieldMeta(name: "avgHeartRate", scale: 1, offset: 0),
            16: FieldMeta(name: "maxHeartRate", scale: 1, offset: 0),
        ],
        mesgSet: [
            0: FieldMeta(name: "duration", scale: 1000, offset: 0),
            3: FieldMeta(name: "repetitions", scale: 1, offset: 0),
            5: FieldMeta(name: "setType", scale: 1, offset: 0),
            7: FieldMeta(name: "category", scale: 1, offset: 0), // tableau (`exerciseCategory`)
        ],
        mesgSplit: [
            0: FieldMeta(name: "splitType", scale: 1, offset: 0),
            1: FieldMeta(name: "totalElapsedTime", scale: 1000, offset: 0),
            2: FieldMeta(name: "totalTimerTime", scale: 1000, offset: 0),
            13: FieldMeta(name: "totalAscent", scale: 1, offset: 0),
            14: FieldMeta(name: "totalDescent", scale: 1, offset: 0),
            26: FieldMeta(name: "avgVertSpeed", scale: 1000, offset: 0), // signé (sint32)
            28: FieldMeta(name: "totalCalories", scale: 1, offset: 0),
        ],
        mesgTimeInZone: [
            0: FieldMeta(name: "referenceMesg", scale: 1, offset: 0),
            2: FieldMeta(name: "timeInHrZone", scale: 1000, offset: 0), // tableau
            6: FieldMeta(name: "hrZoneHighBoundary", scale: 1, offset: 0), // tableau
        ],
        mesgSport: [
            0: FieldMeta(name: "sport", scale: 1, offset: 0),
            1: FieldMeta(name: "subSport", scale: 1, offset: 0),
        ],
        mesgActivity: [
            253: FieldMeta(name: "timestamp", scale: 1, offset: 0),
            0: FieldMeta(name: "totalTimerTime", scale: 1000, offset: 0),
        ],
    ]

    static func fieldMeta(mesgNum: UInt16, fieldNum: UInt8) -> FieldMeta? {
        table[mesgNum]?[fieldNum]
    }
}
