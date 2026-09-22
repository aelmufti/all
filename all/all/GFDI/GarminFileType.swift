//
//  GarminFileType.swift
//  all (bridge-connect)
//
//  Table (type, sous-type) -> nom, portée de gadgetbridge/garmin-bridge,
//  AGPL-3.0 (service/devices/garmin/FileType.java, enum FILETYPE). Pure donnée :
//  seules les ~110 entrées identifiables par (type, sous-type) sur le fil sont
//  reprises ; les entrées « type/sous-type inconnus » de la table Java (utilisées
//  côté pont uniquement pour un rapprochement par nom de chaîne, jamais par
//  valeur reçue de la montre) sont omises.
//
//  Utilisée UNIQUEMENT pour nommer les entrées du manifeste directory (métadonnées
//  : index, type, taille, date). Aucun contenu de fichier n'est jamais lu ici.
//

import Foundation

/// Une entrée `(dataType, subType)` -> nom, comme un cas de `FileType.FILETYPE`
/// côté pont. Le nom reproduit l'identifiant Java (`ACTIVITY`, `MONITOR`, …), pas
/// le champ `typeName` interne (qui ne sert que pour un rapprochement par chaîne
/// côté pont et vaut souvent `null`).
struct GarminFileTypeKey: Hashable {
    let dataType: UInt8
    let subType: UInt8
}

enum GarminFileType {
    /// Table portée telle quelle depuis `FileType.FILETYPE` (ordre non
    /// significatif ici, contrairement à l'enum Java où c'est aussi l'ordre
    /// d'affichage). `DIRECTORY` et `DEVICE_XML` sont les deux entrées
    /// « virtuelles » à index fixe (0 et 0xFFFD) — cf. commentaire Java.
    private static let table: [GarminFileTypeKey: String] = {
        let entries: [(String, UInt8, UInt8)] = [
            ("DIRECTORY", 0, 0),
            ("UNKNOWN_1_0", 1, 0),
            ("DEVICE_XML", 8, 255),

            ("DEVICE_1", 128, 1),
            ("SETTINGS", 128, 2),
            ("SPORTS", 128, 3),
            ("ACTIVITY", 128, 4),
            ("WORKOUTS", 128, 5),
            ("COURSES", 128, 6),
            ("SCHEDULES", 128, 7),
            ("LOCATION", 128, 8),
            ("WEIGHT", 128, 9),
            ("TOTALS", 128, 10),
            ("GOALS", 128, 11),
            ("MAP", 128, 12),
            ("DEBUG", 128, 13),
            ("BLOOD_PRESSURE", 128, 14),
            ("MONITOR_A", 128, 15),
            ("FIT_TYPE_16", 128, 16),
            ("FIT_TYPE_17", 128, 17),
            ("FIT_TYPE_18", 128, 18),
            ("FIT_TYPE_19", 128, 19),
            ("SUMMARY", 128, 20),
            ("GLUCOSE", 128, 21),
            ("TRACKING_RECORDS", 128, 22),
            ("TRACKING_EVENTS", 128, 23),
            ("FIT_TYPE_24", 128, 24),
            ("VECTOR", 128, 25),
            ("FIT_TYPE_26", 128, 26),
            ("FIT_TYPE_27", 128, 27),
            ("MONITOR_DAILY", 128, 28),
            ("RECORDS", 128, 29),
            ("ALERT", 128, 30),
            ("UNKNOWN_31", 128, 31),
            ("MONITOR", 128, 32),
            ("MLT_SPORT", 128, 33),
            ("SEGMENTS", 128, 34),
            ("SEGMENT_LIST", 128, 35),
            ("GOLF", 128, 36),
            ("CLUBS", 128, 37),
            ("SCORE", 128, 38),
            ("ADJUSTMENTS", 128, 39),
            ("HMD", 128, 40),
            ("CHANGELOG", 128, 41),
            ("FIT_TYPE_42", 128, 42),
            ("FIT_TYPE_43", 128, 43),
            ("METRICS", 128, 44),
            ("BAT_SWING", 128, 45),
            ("ROSTER", 128, 46),
            ("DIVE_PLAN", 128, 47),
            ("HSA_DATA", 128, 48),
            ("SLEEP", 128, 49),
            ("SOFTWARE", 128, 50),
            ("CHALLENGE_RESULT", 128, 51),
            ("USER_BEHAVIOR_LOG", 128, 52),
            ("CHRONO_ROUND", 128, 53),
            ("CHRONO_SHOT", 128, 54),
            ("CHRONO_SCORECARD", 128, 55),
            ("PACE_BANDS", 128, 56),
            ("SPORTS_BACKUP", 128, 57),
            ("DEVICE_58", 128, 58),
            ("MUSCLE_MAP", 128, 59),
            ("RUNNING_TRACK", 128, 60),
            ("ECG", 128, 61),
            ("BENCHMARK", 128, 62),
            ("POWER_GUIDANCE", 128, 63),
            ("FIT_TYPE_64", 128, 64),
            ("CALENDAR", 128, 65),
            ("FIT_TYPE_66", 128, 66),
            ("FIT_TYPE_67", 128, 67),
            ("HRV_STATUS", 128, 68),
            ("HSA", 128, 70),
            ("COM_ACT", 128, 71),
            ("FBT_BACKUP", 128, 72),
            ("SKIN_TEMP", 128, 73),
            ("FBT_PTD_BACKUP", 128, 74),
            ("FIT_TYPE_75", 128, 75),
            ("FIT_TYPE_76", 128, 76),
            ("SCHEDULE", 128, 77),
            ("FIT_TYPE_78", 128, 78),
            ("SLP_DISR", 128, 79),
            ("FIT_TYPE_80", 128, 80),
            ("FIT_TYPE_81", 128, 81),
            ("AREA_COURSES", 128, 82),
            ("FIT_TYPE_83", 128, 83),
            ("FIT_TYPE_85", 128, 85),
            ("FIT_TYPE_86", 128, 86),
            ("GEAR", 128, 87),
            ("FIT_TYPE_88", 128, 88),
            ("FIT_TYPE_89", 128, 89),
            ("FIT_TYPE_90", 128, 90),
            ("FIT_TYPE_91", 128, 91),
            ("FIT_TYPE_92", 128, 92),
            ("FIT_TYPE_93", 128, 93),
            ("FIT_TYPE_94", 128, 94),
            ("FIT_TYPE_95", 128, 95),
            ("FIT_TYPE_96", 128, 96),
            ("FIT_TYPE_97", 128, 97),
            ("FIT_TYPE_98", 128, 98),
            ("FIT_TYPE_99", 128, 99),

            ("DOWNLOAD_COURSE", 255, 4),
            ("UNKNOWN_255_008", 255, 8),
            ("PRG", 255, 17),
            ("UNKNOWN_255_020", 255, 20),
            ("UNKNOWN_255_022", 255, 22),
            ("ERROR_SHUTDOWN_REPORTS", 255, 245),
            ("IQ_ERROR_REPORTS", 255, 244),
            ("GOLF_SCORECARD", 255, 246),
            ("ULF_LOGS", 255, 247),
            ("KPI", 255, 248),
        ]
        var result: [GarminFileTypeKey: String] = [:]
        for (name, type, subtype) in entries {
            result[GarminFileTypeKey(dataType: type, subType: subtype)] = name
        }
        return result
    }()

    /// Nom lisible pour un couple (type, sous-type) reçu dans une entrée de
    /// manifeste directory. `nil` = type inconnu de cette table (affiché comme
    /// "TYPE_{type}/{subtype}" par l'appelant) — jamais un obstacle au listing,
    /// contrairement au pont qui écarte ces entrées (`fetchUnknownFiles`) : ici on
    /// liste tout, on ne télécharge rien.
    static func name(dataType: UInt8, subType: UInt8) -> String? {
        table[GarminFileTypeKey(dataType: dataType, subType: subType)]
    }

    /// Types **téléchargeables à la demande** — porté du flag `pull` de
    /// `FileType.FILETYPE` côté pont (`FileType.java` : seules les entrées
    /// construites avec `pull=true` se tirent par `DOWNLOAD_REQUEST`). Les autres
    /// (SETTINGS, SPORTS, DEVICE, GOALS…) existent dans le manifeste mais la montre
    /// **refuse** de les servir (elle répond `downloadStatus != OK`, p. ex. 3) : le
    /// pont ne les met donc jamais dans sa file. On liste tout (UI), mais on ne
    /// télécharge que ces types-là — cf. `GarminDirectoryEntry.isPullable` et
    /// `SyncPlanner.filesDue`. Les entrées `pull=true` « virtuelles » de la table
    /// Java (adressées par nom, type/sous-type = `Integer.MIN_VALUE`) sont hors
    /// sujet ici : jamais reçues sur le fil par (type, sous-type).
    private static let pullableKeys: Set<GarminFileTypeKey> = {
        let pairs: [(UInt8, UInt8)] = [
            (128, 4), (128, 9), (128, 15), (128, 28), (128, 32), (128, 35),
            (128, 38), (128, 41), (128, 44), (128, 49), (128, 52), (128, 57),
            (128, 58), (128, 61), (128, 66), (128, 68), (128, 70), (128, 71),
            (128, 72), (128, 73), (128, 74), (128, 77), (128, 79), (128, 82),
            (255, 244), (255, 245), (255, 246), (255, 247), (255, 248),
        ]
        return Set(pairs.map { GarminFileTypeKey(dataType: $0.0, subType: $0.1) })
    }()

    /// Vrai si la montre sert ce (type, sous-type) sur `DOWNLOAD_REQUEST` (flag
    /// `pull` du pont). Un type inconnu de la table renvoie `false` : comme le
    /// pont, on ne tente pas de télécharger ce qu'on ne sait pas être tirable.
    static func isPullable(dataType: UInt8, subType: UInt8) -> Bool {
        pullableKeys.contains(GarminFileTypeKey(dataType: dataType, subType: subType))
    }
}

/// Une entrée du manifeste directory de la montre — métadonnées seulement
/// (aucun contenu de fichier). Porté de `FileTransferHandler.DirectoryEntry`
/// côté pont, réduit aux champs utiles à l'affichage.
struct GarminDirectoryEntry: Identifiable, Equatable {
    let id: Int // fileIndex — stable pour la durée d'un lien, cf. commentaire Java
    let fileIndex: Int
    let dataType: UInt8
    let subType: UInt8
    let fileNumber: Int
    let sizeBytes: Int
    /// `nil` quand l'horodatage fil valait 0 (sentinelle « pas de date » de la
    /// montre), comme `DirectoryEntry.fileDate` côté pont.
    let date: Date?

    var typeName: String {
        GarminFileType.name(dataType: dataType, subType: subType) ?? "TYPE_\(dataType)_\(subType)"
    }

    /// Vrai pour l'entrée virtuelle DIRECTORY (dataType=0, subType=0) — jamais
    /// une cible valide de `GarminSession.downloadFile` : ce n'est pas un
    /// fichier, c'est le manifeste lui-même (`requestDirectoryListing`).
    var isDirectory: Bool { dataType == 0 && subType == 0 }

    /// Vrai si la montre accepte de servir ce fichier sur `DOWNLOAD_REQUEST`
    /// (flag `pull` du pont, cf. `GarminFileType.isPullable`). Les types non-`pull`
    /// sont listés mais jamais téléchargés : la montre les refuse
    /// (`downloadStatus != OK`). Utilisé par `SyncPlanner.filesDue` pour ne mettre
    /// que des cibles servables dans la file de traversée.
    var isPullable: Bool { GarminFileType.isPullable(dataType: dataType, subType: subType) }

    init?(fileIndex: Int, dataType: UInt8, subType: UInt8, fileNumber: Int, sizeBytes: Int, garminTimestamp: UInt32) {
        // Sentinelle anti-boucle du pont : une entrée entièrement à zéro n'est
        // pas un fichier, c'est un manifeste tronqué ou un bourrage de fin.
        if fileIndex == 0 && dataType == 0 && subType == 0 && fileNumber == 0 && sizeBytes == 0 && garminTimestamp == 0 {
            return nil
        }
        self.id = fileIndex
        self.fileIndex = fileIndex
        self.dataType = dataType
        self.subType = subType
        self.fileNumber = fileNumber
        self.sizeBytes = sizeBytes
        self.date = garminTimestamp == 0
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(garminTimestamp) + GarminEpoch.offsetFromUnix)
    }
}

/// Décalage entre l'epoch Unix et l'epoch Garmin — invariant protocole hérité du
/// pont, partagé par CURRENT_TIME_REQUEST et les horodatages du manifeste
/// directory (`GarminTimeUtils.GARMIN_TIME_EPOCH`).
enum GarminEpoch {
    static let offsetFromUnix: TimeInterval = 631_065_600
}

/// Parse un manifeste directory déjà entièrement reçu et réassemblé (16 octets
/// par entrée, LE) — port de `FileTransferHandler.Download.parseDirectoryEntries`,
/// sans le filtrage par `fetchUnknownFiles` (on liste tout) ni l'ajout à une file
/// de téléchargement (interdit par le périmètre de cet incrément).
enum GarminDirectoryParser {
    static let entrySize = 16

    static func parse(_ data: Data) -> [GarminDirectoryEntry] {
        guard data.count % entrySize == 0 else {
            return []
        }
        var reader = GarminByteReader(data)
        var entries: [GarminDirectoryEntry] = []
        while reader.remaining >= entrySize {
            guard let fileIndex = reader.readUInt16LE(),
                  let dataType = reader.readUInt8(),
                  let subType = reader.readUInt8(),
                  let fileNumber = reader.readUInt16LE(),
                  let _ = reader.readUInt8(), // specificFlags — non affiché
                  let _ = reader.readUInt8(), // fileFlags — non affiché
                  let fileSize = reader.readUInt32LE(),
                  let timestamp = reader.readUInt32LE()
            else { break }
            if let entry = GarminDirectoryEntry(
                fileIndex: Int(fileIndex),
                dataType: dataType,
                subType: subType,
                fileNumber: Int(fileNumber),
                sizeBytes: Int(fileSize),
                garminTimestamp: timestamp
            ) {
                entries.append(entry)
            }
        }
        return entries
    }
}
