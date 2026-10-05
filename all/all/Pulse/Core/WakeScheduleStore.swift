//
//  WakeScheduleStore.swift
//  all (bridge-connect)
//
//  Réveil manuel réglé DANS l'app — iOS n'expose pas les alarmes de
//  l'app Horloge système à une app tierce, on ne cherche pas à les lire.
//  L'heure vient uniquement de la saisie utilisateur ici, et sert à deux
//  choses : programmer un rappel sonore (`WakeAlarmScheduler`) et recalculer
//  localement l'heure de coucher conseillée à partir du prochain réveil à
//  venir (la reco serveur, `/api/stats/sleep-recommendation`, se base sinon
//  sur l'heure de lever HABITUELLE calculée sur l'historique).
//
//  Miroir de style `ThemeStore.swift` : `@MainActor @Observable`, persisté
//  dans `UserDefaults`.
//
//  Synchro par profil (planning de réveil) — `minutesByWeekday` reste la
//  source de vérité EN MÉMOIRE pour l'UI et `WakeAlarmScheduler` ; la
//  persistance `UserDefaults` devient un CACHE HORS-LIGNE (survit à un
//  relancement hors-ligne, affiche le dernier état connu dès le boot).
//  Par-dessus, on synchronise avec le backend routé (`PulseAPIClient`,
//  serveur ou local selon `StorageMode`) via `GET`/`PUT api/wake-schedule`
//  (miroir `WakeController`, `wake.controller.ts`). `load()` est appelé au
//  démarrage et aux changements de mode/connexion (cf. `ContentView.swift`) ;
//  `set`/`clear`/`clearAll` restent synchrones pour l'UI (optimiste) et
//  poussent en best-effort en tâche de fond.
//
//  Limite connue (cf. `load()`) : un effacement total fait sur un appareil ne
//  se propage pas tant qu'un AUTRE appareil a un cache local non vide — pas
//  de réconciliation par horodatage pour l'instant (incrément futur).
//

import Foundation
import Observation

/// Résultat du recalcul local de coucher à partir du prochain réveil réglé
/// dans l'app — cf. `WakeScheduleStore.adaptedBedtime(reco:calendar:now:)`.
struct AdaptedBedtime: Equatable {
    /// Coucher à viser CE SOIR (palier appliqué si besoin).
    let bedtime: String
    /// Cible finale (sans palier) — à afficher quand `stepped` est vrai.
    let targetBedtime: String
    let stepped: Bool
    let wakeMinutes: Int
    let weekday: Int
}

/// DTO d'encodage JSON — `GET`/`PUT api/wake-schedule`, miroir de
/// `WakeSchedule` (`wake.controller.ts`) et `LocalWakeScheduleDTO`
/// (`Local/LocalPulseBackend.swift`). Mêmes clés `String` que la persistance
/// `UserDefaults` existante (`Int` n'est pas codable comme clé de dico par
/// `JSONEncoder`/`JSONDecoder`).
struct WakeScheduleDTO: Codable {
    let schedule: [String: Int]
}

@MainActor
@Observable
final class WakeScheduleStore {
    static let shared = WakeScheduleStore()

    /// Calendar weekday (1 = dimanche … 7 = samedi) → minutes depuis minuit
    /// local (0…1439). Jour absent de la table = pas de réveil ce jour-là.
    private(set) var minutesByWeekday: [Int: Int]

    private let defaults: UserDefaults
    private let client: PulseAPIClient
    private static let key = "pulse-wake-schedule"

    init(defaults: UserDefaults = .standard, client: PulseAPIClient = .shared) {
        self.defaults = defaults
        self.client = client
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            var restored: [Int: Int] = [:]
            for (rawWeekday, minutes) in decoded {
                if let weekday = Int(rawWeekday) { restored[weekday] = minutes }
            }
            minutesByWeekday = restored
        } else {
            minutesByWeekday = [:]
        }
    }

    func minutes(for weekday: Int) -> Int? {
        minutesByWeekday[weekday]
    }

    func set(minutes: Int, weekdays: Set<Int>) {
        for weekday in weekdays { minutesByWeekday[weekday] = minutes }
        persist()
        WakeAlarmScheduler.shared.reschedule(minutesByWeekday)
        Task { await self.pushToBackend() }
    }

    func clear(weekdays: Set<Int>) {
        for weekday in weekdays { minutesByWeekday.removeValue(forKey: weekday) }
        persist()
        WakeAlarmScheduler.shared.reschedule(minutesByWeekday)
        Task { await self.pushToBackend() }
    }

    func clearAll() {
        minutesByWeekday.removeAll()
        persist()
        WakeAlarmScheduler.shared.reschedule(minutesByWeekday)
        Task { await self.pushToBackend() }
    }

    private func persist() {
        // Clés JSON en `String` (Int n'est pas codable comme clé de dico par
        // `JSONEncoder`) — reconverties en `Int` à la lecture.
        let encodable = Dictionary(uniqueKeysWithValues: minutesByWeekday.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            defaults.set(data, forKey: Self.key)
        }
    }

    // MARK: - Synchro backend (`api/wake-schedule`)

    /// Best-effort, ne jette jamais — même esprit que `AuthStore.check()` :
    /// une vérification de routine, pas une action utilisateur à faire
    /// échouer bruyamment.
    func load() async {
        do {
            let dto: WakeScheduleDTO = try await client.get("api/wake-schedule")
            var serverMap: [Int: Int] = [:]
            for (rawWeekday, minutes) in dto.schedule {
                guard let weekday = Int(rawWeekday), weekday >= 1, weekday <= 7,
                      minutes >= 0, minutes <= 1439
                else { continue }
                serverMap[weekday] = minutes
            }
            if serverMap.isEmpty && !minutesByWeekday.isEmpty {
                // Anti-écrasement / migration : le serveur (ou le backend
                // local, selon le mode) n'a encore aucun planning alors que ce
                // cache a déjà des réveils — on ne l'adopte PAS (ce serait
                // effacer silencieusement ce que l'utilisateur a réglé ici) ;
                // on pousse plutôt le cache local vers le backend. Limite
                // connue (cf. en-tête de fichier) : un effacement total fait
                // sur un AUTRE appareil ne se propage donc pas tant que ce
                // cache-ci reste non vide — pas de réconciliation par
                // horodatage pour l'instant.
                await pushToBackend()
                return
            }
            // Adopte la map serveur, même vide quand le cache l'était déjà
            // (vide → vide n'est jamais un effacement délibéré observable).
            // Inchangé (cas courant : relu à chaque démarrage/changement de mode/
            // connexion) : ne pas réaffecter la valeur observable, sinon tous les
            // écrans qui lisent `minutesByWeekday` se réévaluent pour rien. Les
            // rappels, eux, sont toujours reprogrammés (comportement historique).
            if serverMap != minutesByWeekday {
                minutesByWeekday = serverMap
                persist()
            }
            WakeAlarmScheduler.shared.reschedule(minutesByWeekday)
        } catch {
            // Hors-ligne / `.notConfigured` / `.unauthorized` : no-op, on
            // garde le cache tel quel.
        }
    }

    /// PUT la map complète courante — best-effort, avale l'erreur.
    private func pushToBackend() async {
        let encodable = Dictionary(uniqueKeysWithValues: minutesByWeekday.map { (String($0.key), $0.value) })
        let dto = WakeScheduleDTO(schedule: encodable)
        let _: WakeScheduleDTO? = try? await client.put("api/wake-schedule", body: dto)
    }

    /// "HH:mm" zero-paddé — même format que les heures reçues du serveur
    /// (`waketime` / `recommendedBedtime` de `DashboardSleepRecommendation`).
    /// `nonisolated` : pur formatage, appelé aussi depuis du code hors
    /// `@MainActor` (ex. `wakeScheduleSummary` dans `SommeilView.swift`).
    nonisolated static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// Recalcule localement l'heure de coucher conseillée à partir du réveil qui
    /// cadre la **nuit à venir** réglé dans l'app. On ne considère que le réveil
    /// restant d'aujourd'hui puis celui de demain matin (cf. `nextWake`) : à 1 h
    /// du lundi, le réveil de lundi 07:00 est encore devant → c'est LUI (nuit
    /// dim.→lun. en cours) ; un vendredi après-midi sans réveil samedi, on ne
    /// cale PAS le coucher sur le lundi — on renvoie `nil` et l'appelant montre
    /// la reco serveur (lever habituel). C'est un réveil imminent qu'on adapte,
    /// pas une moyenne ni une alarme lointaine.
    ///
    /// On applique ensuite la formule de la reco serveur (bedtime = lever −
    /// (durée cible + éveil habituel + délai d'endormissement)), mais avec
    /// l'heure de lever fixée par l'utilisateur au lieu de la moyenne serveur.
    /// Comme côté serveur, on ne vise la cible finale que si elle n'avance pas
    /// de plus de `stepMin` sur l'habitude (`currentBedtime`) — au-delà, palier
    /// de `stepMin` ce soir — mais seulement si le serveur envoie `stepMin`
    /// (contrat v2) ; un serveur v1 (pas de `stepMin`) ne déclenche jamais de
    /// palier ici, pour rester compatible. `nil` si aucun réveil n'est
    /// programmé pour la nuit à venir (aujourd'hui restant ou demain matin), ou
    /// si le serveur n'a pas encore de durée cible exploitable (nuits
    /// insuffisantes).
    func adaptedBedtime(
        reco: DashboardSleepRecommendation,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> AdaptedBedtime? {
        guard let targetHours = reco.targetHours else { return nil }
        guard let (wakeMinutes, weekday) = nextWake(calendar: calendar, now: now) else { return nil }

        let neededMin = Int((targetHours * 60).rounded()) + (reco.avgAwakeMin ?? 0) + (reco.latencyMin ?? 0)
        // Repli mod 1440 pour gérer le passage minuit (coucher la veille).
        let targetBedMin = ((wakeMinutes - neededMin) % 1_440 + 1_440) % 1_440

        var stepped = false
        var bedMin = targetBedMin
        if let stepMin = reco.stepMin,
           let habitMin = Self.parseHHMM(reco.currentBedtime) {
            let shift = Self.signedDiffMinutes(targetBedMin, habitMin)
            if shift < -stepMin {
                stepped = true
                bedMin = ((habitMin - stepMin) % 1_440 + 1_440) % 1_440
            }
        }

        return AdaptedBedtime(
            bedtime: Self.hhmm(bedMin),
            targetBedtime: Self.hhmm(targetBedMin),
            stepped: stepped,
            wakeMinutes: wakeMinutes,
            weekday: weekday
        )
    }

    /// "HH:mm" → minutes depuis minuit, ou `nil` si absent/mal formé.
    private static func parseHHMM(_ value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    /// Décalage signé le plus court entre deux horaires (minutes depuis
    /// minuit), négatif = `a` avant `b` — même formule que côté serveur.
    private static func signedDiffMinutes(_ a: Int, _ b: Int) -> Int {
        (((a - b) % 1_440 + 1_440 + 720) % 1_440) - 720
    }

    /// Réveil qui cadre la **nuit à venir** (minutes + weekday) — on ne regarde
    /// que le réveil restant d'aujourd'hui (ex. il est 1 h, le réveil de 7 h est
    /// encore devant) puis celui de demain matin. Au-delà (aucun réveil demain),
    /// on renvoie `nil` : l'appelant retombe alors sur la reco serveur (lever
    /// habituel), au lieu de caler le coucher de ce soir sur un réveil situé à
    /// plusieurs jours (ex. un vendredi soir vers le lundi matin).
    private func nextWake(calendar: Calendar, now: Date) -> (minutes: Int, weekday: Int)? {
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard let wakeMinutes = minutes(for: weekday) else { continue }
            let wakeDate = calendar.startOfDay(for: day)
                .addingTimeInterval(TimeInterval(wakeMinutes * 60))
            if wakeDate > now { return (wakeMinutes, weekday) }
        }
        return nil
    }
}
