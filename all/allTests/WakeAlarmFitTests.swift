//
//  WakeAlarmFitTests.swift
//  allTests
//
//  Valide `FitSettingsWriter.alarmSettings` — encodage FIT Settings pour les
//  alarmes natives Venu 2 (FILE_ID + `alarm_settings`(222) × N +
//  `device_settings`(2)), même esprit que `Crc16Tests` (vecteurs/structure,
//  hors-ligne) côté en-tête/CRC, et round-trip via le décodeur FIT maison
//  (`FitDecoder`, `Local/Fit/FitDecoder.swift`) pour le contenu des messages
//  — le décodeur est générique (types/tailles lus dans le message de
//  définition écrit sur le fil), donc capable de relire `alarm_settings` et
//  `device_settings` sans connaître leur profil à l'avance (`FitProfile` n'a
//  pas ces deux messages, scale/offset par défaut 1/0 — exact pour tous les
//  champs utilisés ici).
//
//  Limite assumée : pas de référence SDK Garmin officiel pour CES deux
//  messages (contrairement à `FitDecoderTests`, qui valide contre une sortie
//  `@garmin/fitsdk` réelle) — `alarm_settings`/`device_settings` ne sont pas
//  dans le profil FIT public, seulement dans l'extension propriétaire Garmin
//  que gadgetbridge a rétro-documentée (`FitCodeGenerator/.../fit_profile.json`,
//  `FieldDefinitionAlarm.java`). La validation ultime de ces numéros de champ
//  reste le test device (incrément W5, cf. tâche de répartition).
//

import Testing
import Foundation
@testable import all

private let mesgFileId: UInt16 = 0
private let mesgDeviceSettings: UInt16 = 2
private let mesgAlarmSettings: UInt16 = 222

struct WakeAlarmFitTests {

    // MARK: - (a) Sortie non vide + en-tête FIT valide

    @Test func nonEmptyScheduleProducesValidFitHeader() throws {
        let data = FitSettingsWriter.alarmSettings(schedule: [2: 420], timeCreated: 1_000_000)
        #expect(data.count > 14 + 2) // en-tête + au moins un peu de contenu + CRC final

        let bytes = [UInt8](data)
        #expect(bytes[0] == 14) // taille d'en-tête
        #expect(Array(bytes[8...11]) == [0x2E, 0x46, 0x49, 0x54]) // « .FIT »

        let file = try FitDecoder.decode(data)
        #expect(file.crcValid)
        #expect(!file.messages.isEmpty)
    }

    @Test func fileIdMessageHasSettingsType() throws {
        let data = FitSettingsWriter.alarmSettings(schedule: [2: 420], timeCreated: 42)
        let file = try FitDecoder.decode(data)
        let fileId = try #require(file.messages.first { $0.globalMessageNumber == mesgFileId })
        #expect(fileId.double(0) == 2) // file_id.type = SETTINGS
        #expect(fileId.double(4) == 42) // time_created
    }

    // MARK: - (b) Regroupement : Lun–Ven 07:00 + Sam 08:30 → 2 alarm_settings

    @Test func groupsSameTimeWeekdaysIntoOneAlarm() throws {
        // Calendar.weekday : 1=dim..7=sam. Lun(2)..Ven(6) à 07:00 (420 min),
        // Sam(7) à 08:30 (510 min).
        let schedule: [Int: Int] = [2: 420, 3: 420, 4: 420, 5: 420, 6: 420, 7: 510]
        let data = FitSettingsWriter.alarmSettings(schedule: schedule, timeCreated: 1_000)
        let file = try FitDecoder.decode(data)

        let alarms = file.messages.filter { $0.globalMessageNumber == mesgAlarmSettings }
        #expect(alarms.count == 2) // 2 heures distinctes → 2 alarmes, pas 6

        let sortedAlarms = alarms.sorted { ($0.double(0) ?? 0) < ($1.double(0) ?? 0) }
        let morningAlarm = sortedAlarms[0]
        let saturdayAlarm = sortedAlarms[1]

        #expect(morningAlarm.double(0) == 420) // time
        // Lun(1) | Mar(2) | Mer(4) | Jeu(8) | Ven(16) = 31
        #expect(morningAlarm.double(1) == 31) // repeat
        #expect(morningAlarm.double(254) == 0) // message_index

        #expect(saturdayAlarm.double(0) == 510)
        #expect(saturdayAlarm.double(1) == 32) // Sam seul
        #expect(saturdayAlarm.double(254) == 1)

        // Champs communs par défaut
        for alarm in alarms {
            #expect(alarm.double(2) == 1) // enabled
            #expect(alarm.double(3) == 3) // sound = TONE_AND_VIBRATION
            #expect(alarm.double(4) == 1) // backlight
            #expect(alarm.double(5) == 1_000) // time_created
            #expect(alarm.double(7) == 0) // snooze
            #expect(alarm.double(8) == 1) // label = WAKE_UP
        }

        // device_settings : tableaux parallèles, 2 éléments, même ordre
        // (heure croissante) que les alarm_settings.
        let deviceSettings = try #require(file.messages.first { $0.globalMessageNumber == mesgDeviceSettings })
        #expect(deviceSettings.numberList(8) == [420, 510]) // alarms_time
        #expect(deviceSettings.numberList(9) == [5, 5]) // alarms_unk5
        #expect(deviceSettings.numberList(28) == [1, 1]) // alarms_enabled
        #expect(deviceSettings.numberList(92) == [31, 32]) // alarms_repeat
    }

    // MARK: - (c) Réveil unique un seul jour

    @Test func singleDayScheduleProducesOneAlarmWithSingleDayMask() throws {
        let data = FitSettingsWriter.alarmSettings(schedule: [4: 390], timeCreated: 7)
        let file = try FitDecoder.decode(data)

        let alarms = file.messages.filter { $0.globalMessageNumber == mesgAlarmSettings }
        #expect(alarms.count == 1)
        let alarm = alarms[0]
        #expect(alarm.double(0) == 390)
        #expect(alarm.double(1) == 4) // mercredi seul
        #expect(alarm.double(254) == 0)

        let deviceSettings = try #require(file.messages.first { $0.globalMessageNumber == mesgDeviceSettings })
        #expect(deviceSettings.numberList(8) == [390])
        #expect(deviceSettings.numberList(92) == [4])
    }

    /// Les 7 bits de jour (dim..sam) sont couverts et distincts (bijection
    /// `Calendar.weekday → bit Garmin`), chacun isolé dans sa propre alarme
    /// puisqu'à des heures différentes (pas de regroupement).
    @Test func allSevenWeekdaysMapToDistinctGarminBits() throws {
        let schedule: [Int: Int] = [1: 0, 2: 60, 3: 120, 4: 180, 5: 240, 6: 300, 7: 360]
        let data = FitSettingsWriter.alarmSettings(schedule: schedule, timeCreated: 0)
        let file = try FitDecoder.decode(data)

        let alarms = file.messages.filter { $0.globalMessageNumber == mesgAlarmSettings }
        #expect(alarms.count == 7)
        let masks = Set(alarms.compactMap { $0.double(1) })
        #expect(masks == Set([64, 1, 2, 4, 8, 16, 32])) // dim, lun, mar, mer, jeu, ven, sam — tous distincts
    }

    // MARK: - (d) Planning vide → FILE_ID seul, documenté

    @Test func emptyScheduleProducesFileIdOnly() throws {
        let data = FitSettingsWriter.alarmSettings(schedule: [:], timeCreated: 5)
        #expect(!data.isEmpty) // PAS Data() — un FIT minimal valide, contrairement à l'ancien stub

        let file = try FitDecoder.decode(data)
        #expect(file.crcValid)
        #expect(file.messages.count == 1)
        let fileId = try #require(file.messages.first { $0.globalMessageNumber == mesgFileId })
        #expect(fileId.double(0) == 2) // type = SETTINGS

        // Ni alarm_settings ni device_settings : reproduit `onSetAlarms`
        // (gadgetbridge) qui n'écrit device_settings que si au moins une
        // alarme est active. Documenté dans `FitSettingsWriter.alarmSettings`.
        #expect(file.messages.first { $0.globalMessageNumber == mesgAlarmSettings } == nil)
        #expect(file.messages.first { $0.globalMessageNumber == mesgDeviceSettings } == nil)
    }

    /// Entrées hors contrat (weekday hors 1...7, minutes hors 0..<1440)
    /// silencieusement ignorées plutôt que de produire un FIT invalide — la
    /// validation stricte vit côté API (`WakeScheduleLocalTests`), pas ici.
    @Test func outOfRangeEntriesAreIgnoredDefensively() throws {
        let schedule: [Int: Int] = [0: 420, 8: 420, 2: -1, 3: 1440, 4: 420]
        let data = FitSettingsWriter.alarmSettings(schedule: schedule, timeCreated: 0)
        let file = try FitDecoder.decode(data)

        let alarms = file.messages.filter { $0.globalMessageNumber == mesgAlarmSettings }
        #expect(alarms.count == 1) // seule l'entrée [4: 420] (mercredi) est valide
        #expect(alarms[0].double(1) == 4)
    }
}
