//
//  ActivityModels.swift
//  all (bridge-connect)
//
//  Modèles `Decodable` de l'écran Activités — forme exacte des réponses
//  NestJS (`custom-connect/server/src/activities/activities.controller.ts`) :
//  `GET api/activities` (liste, `{ total, items }`) et `GET api/activities/:id`
//  (détail — résumé + flux/segments extraits du `.fit` par `FitParserService`,
//  cf. `custom-connect/server/src/ingest/fit-parser.service.ts`).
//
//  Dates : `startTime` est une chaîne ISO 8601 complète (le serveur fait
//  `Date.toISOString()`, cf. `FitParserService.asIsoDate`), pas un epoch —
//  typée `String?` ici, jamais `Date` (règle du socle, cf. commentaire de
//  `PulseAPIClient.decoder`). Le parsing se fait dans `ActivityFormatting.swift`
//  (`ActivityDateFormatting`).
//
//  Champs numériques optionnels : typés `Double` plutôt que `Int` même quand
//  la donnée est "sémantiquement" un entier (bpm, calories...). Certains
//  champs FIT portent réellement une fraction (durée totale, vitesse
//  verticale moyenne) et un décodeur `Int` échoue net sur un JSON `12.0` —
//  `Double` couvre les deux formats sans risque ; la conversion à l'affichage
//  se fait au point d'usage (`Int(x.rounded())`).
//

import Foundation

/// Une activité telle que listée par `GET api/activities` — mêmes colonnes
/// SQL que le socle de `ActivityDetail` (cf. `ACTIVITY_COLUMNS` côté Nest).
struct Activity: Decodable, Identifiable, Hashable {
    let id: Int
    let fileName: String
    let sport: String?
    let subSport: String?
    let startTime: String?
    let durationS: Double?
    let distanceM: Double?
    let calories: Double?
    let avgHr: Double?
    let maxHr: Double?
}

struct ActivityListResponse: Decodable {
    let total: Int
    let items: [Activity]
}

/// Flux temporels alignés (même longueur que `time`) — `null` = trou
/// d'échantillonnage, jamais retiré du tableau côté serveur (un point par
/// enregistrement source, downsample fait à part).
struct ActivityStreams: Decodable {
    let time: [Double?]
    let hr: [Double?]
    let speed: [Double?]
    let altitude: [Double?]
    let distance: [Double?]
}

struct ActivityLap: Decodable, Identifiable, Hashable {
    let index: Int
    let durationS: Double?
    let distanceM: Double?
    let avgHr: Double?
    let maxHr: Double?
    var id: Int { index }
}

struct ActivitySet: Decodable, Identifiable, Hashable {
    let index: Int
    let durationS: Double?
    let category: String?
    let repetitions: Double?
    var id: Int { index }
}

struct ActivitySplit: Decodable, Identifiable, Hashable {
    let index: Int
    let type: String?
    let durationS: Double?
    let ascentM: Double?
    let descentM: Double?
    let calories: Double?
    let avgVertSpeedMs: Double?
    var id: Int { index }
}

struct HrZone: Decodable, Identifiable, Hashable {
    let zone: Int
    let seconds: Double
    let fromBpm: Double?
    let toBpm: Double?
    var id: Int { zone }
}

/// `GET api/activities/:id` — résumé (mêmes champs que `Activity`) + flux/
/// segments extraits à la volée du `.fit` gardé sur Pulse. Si le fichier a
/// été archivé/perdu côté serveur, le contrôleur renvoie le résumé seul avec
/// des tableaux vides et `streams: null` (cf. `activities.controller.ts`,
/// branche `!fs.existsSync(filePath)`) — tout ce qui en dépend est donc
/// optionnel/vide par défaut ici, jamais supposé présent.
struct ActivityDetail: Decodable {
    let id: Int
    let fileName: String
    let sport: String?
    let subSport: String?
    let startTime: String?
    let durationS: Double?
    let distanceM: Double?
    let calories: Double?
    let avgHr: Double?
    let maxHr: Double?
    let track: [[Double]]
    let streams: ActivityStreams?
    let laps: [ActivityLap]
    let sets: [ActivitySet]
    let splits: [ActivitySplit]
    let hrZones: [HrZone]
}
