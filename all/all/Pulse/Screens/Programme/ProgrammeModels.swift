//
//  ProgrammeModels.swift
//  all (bridge-connect)
//
//  Modèles `Codable` de l'écran Programme — miroir de la forme JSON exposée
//  par `custom-connect/server/src/programme/programme.controller.ts` (et
//  `catalogue.ts`/`progress.ts`/`sleep.ts` pour le détail par domaine). La
//  page Angular (`programme.component.ts`) type directement la réponse HTTP
//  sans couche de mapping intermédiaire — les interfaces TypeScript qu'elle
//  déclare SONT le contrat JSON ; ce fichier les traduit 1:1.
//
//  Particularité de cet écran : `GET api/programme` renvoie un `detail`
//  **polymorphe** par domaine (`kind: "training" | "nutrition" | "sleep"`
//  détermine la forme). Nest/Angular n'a pas besoin de le déclarer : c'est un
//  simple union TypeScript. Côté Swift, `Decodable` ne fait pas ça tout seul
//  → décodage manuel dans `ProgrammeDomainView.init(from:)`.
//
//  Convention : tous les types top-level (et leurs sous-vues privées, dans
//  les autres fichiers de ce dossier) sont préfixés `Programme` — même motif
//  que `Screens/Nutrition/NutritionModels.swift` : un seul module partagé
//  entre tous les écrans, les noms génériques (`Detail`, `Session`, `Day`…)
//  entreraient en collision à la compilation.
//
//  Dates : chaînes calendaires `YYYY-MM-DD` (jamais `Date`), cf. le
//  commentaire de `PulseAPIClient.decoder`. `ProgrammeDate` centralise le
//  parsing/formatage utilisé par les vues et par `ProgrammeFormatting.swift`.
//

import Foundation

// MARK: - `GET api/programme`

enum ProgrammeKind: String, Codable {
    case training
    case nutrition
    case sleep
}

struct ProgrammeCurrent: Decodable {
    let date: String
    let domains: [ProgrammeDomainView]
}

/// Un programme catalogué pour un domaine — actif ou simple choix de
/// bibliothèque (`domain.choices[]`).
struct ProgrammeChoice: Codable, Identifiable {
    let id: String
    let name: String
    let goal: String
    let source: String
    let weeks: Int
    let rules: Int
    let perWeek: Int
}

/// Programme actuellement actif pour un domaine (`domain.active`, `null` si
/// aucun).
struct ProgrammeActive: Codable {
    let programmeId: String
    let startedOn: String
    let name: String
    let goal: String
    let source: String
    let week: Int
    let weeks: Int
    /// Jours de la semaine choisis à l'activation — convention JS
    /// `Date.getDay()` (0 = dimanche … 6 = samedi), cf. `ProgrammeDate.weekdayLetters`.
    let days: [Int]
    let perWeek: Int
    let notes: [String]
}

/// Détail polymorphe d'un domaine — la forme dépend de `kind`. Décodé à la
/// main dans `ProgrammeDomainView.init(from:)`, jamais synthétisé.
enum ProgrammeDetail {
    case training(ProgrammeTrainingDetail)
    case nutrition(ProgrammeNutritionDetail)
    case sleep(ProgrammeSleepDetail)
}

struct ProgrammeDomainView: Decodable, Identifiable {
    let kind: ProgrammeKind
    let label: String
    let drives: String
    let hint: String
    let choices: [ProgrammeChoice]
    let active: ProgrammeActive?
    let detail: ProgrammeDetail?

    var id: String { kind.rawValue }

    private enum CodingKeys: String, CodingKey {
        case kind, label, drives, hint, choices, active, detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ProgrammeKind.self, forKey: .kind)
        label = try container.decode(String.self, forKey: .label)
        drives = try container.decode(String.self, forKey: .drives)
        hint = try container.decode(String.self, forKey: .hint)
        choices = try container.decode([ProgrammeChoice].self, forKey: .choices)
        active = try container.decodeIfPresent(ProgrammeActive.self, forKey: .active)

        guard container.contains(.detail), try !container.decodeNil(forKey: .detail) else {
            detail = nil
            return
        }
        switch kind {
        case .training:
            detail = .training(try container.decode(ProgrammeTrainingDetail.self, forKey: .detail))
        case .nutrition:
            detail = .nutrition(try container.decode(ProgrammeNutritionDetail.self, forKey: .detail))
        case .sleep:
            detail = .sleep(try container.decode(ProgrammeSleepDetail.self, forKey: .detail))
        }
    }
}

// MARK: - Détail entraînement (`kind == "training"`)

struct ProgrammeWeekFocus: Codable {
    let index: Int
    let focus: String?
}

struct ProgrammeTrainingItem: Codable {
    let name: String
    let prescription: String
    let note: String?
}

struct ProgrammeSession: Codable {
    let key: String
    let name: String
    let sport: String
    let subSport: String?
    let minMinutes: Int?
    let items: [ProgrammeTrainingItem]
}

enum ProgrammeSessionStatus: String, Codable {
    case done
    case today
    case upcoming
    case missed
}

struct ProgrammeSessionProgress: Codable, Identifiable {
    let week: Int
    let session: ProgrammeSession
    let plannedOn: String?
    let status: ProgrammeSessionStatus
    let done: Bool
    let date: String?
    let activityId: Int?
    /// `true` si pointée à la main (`programme_done`), `false` si appariée
    /// automatiquement à une activité importée — détermine si la coche est
    /// modifiable (cf. `Sess.done && !Sess.manual` côté Angular : verrouillée
    /// quand elle vient de l'appariement auto).
    let manual: Bool

    var id: String { "\(week)-\(session.key)" }
}

struct ProgrammeTrainingDetail: Codable {
    let focus: [ProgrammeWeekFocus]
    let sessions: [ProgrammeSessionProgress]
    let done: Int
    let total: Int
    let missed: Int
    let today: [ProgrammeSessionProgress]
}

// MARK: - Détail alimentation (`kind == "nutrition"`)

/// Sous-ensemble de la règle catalogue utile à l'affichage — mêmes clés que
/// `RuleProgress.rule` côté Angular (`min`/`max` catalogue non repris : la
/// fourchette déjà recadrée par kilo vit dans `ProgrammeRuleProgress.target`).
struct ProgrammeNutritionRuleRef: Codable {
    let key: String
    let label: String
    let detail: String
    /// `"protein" | "carbs" | "fat" | "kcal" | "fiber"` — clé d'unité, cf.
    /// `ProgrammeFormatting.macroUnit`.
    let metric: String
    let perKg: Bool?
}

/// Fourchette min/max — réutilisée par `ProgrammeRuleProgress.target`
/// (alimentation) et `ProgrammeSleepMetric.range` (sommeil), même forme
/// `{ min: number|null; max: number|null }` côté serveur pour les deux.
struct ProgrammeRange: Codable {
    let min: Double?
    let max: Double?
}

enum ProgrammeStatus: String, Codable {
    case hit
    case under
    case over
    case unknown
}

struct ProgrammeRuleProgress: Codable, Identifiable {
    let rule: ProgrammeNutritionRuleRef
    let target: ProgrammeRange
    let value: Double?
    let status: ProgrammeStatus

    var id: String { rule.key }
}

struct ProgrammeDayProgress: Codable, Identifiable {
    let date: String
    let logged: Bool
    let rules: [ProgrammeRuleProgress]
    let hits: Int
    let total: Int

    var id: String { date }
}

struct ProgrammeNutritionDetail: Codable {
    let today: ProgrammeDayProgress
    let days: [ProgrammeDayProgress]
    let weightKg: Double?
}

// MARK: - Détail sommeil (`kind == "sleep"`)

struct ProgrammeSleepAxis: Codable {
    let onsetMean: Double
    let onsetSd: Double
    let wakeMean: Double
    let wakeSd: Double
}

struct ProgrammeNightPoint: Codable, Identifiable {
    let date: String
    /// Convention JS `Date.getUTCDay()` (0 = dimanche … 6 = samedi).
    let weekday: Int
    let workDay: Bool
    let onset: Double
    let wake: Double
    let sleepMin: Double

    var id: String { date }
}

enum ProgrammeSleepUnit: String, Codable {
    case min
    case duration
    case index
}

struct ProgrammeSleepBand: Codable {
    let upTo: Double?
    let label: String
    let risk: String
}

struct ProgrammeSleepScale: Codable {
    let min: Double
    let max: Double
}

struct ProgrammeSleepMetric: Codable, Identifiable {
    let key: String
    let label: String
    let detail: String
    let evidence: String
    let unit: ProgrammeSleepUnit
    let informative: Bool
    let value: Double?
    let range: ProgrammeRange
    let scale: ProgrammeSleepScale
    let status: ProgrammeStatus
    let band: ProgrammeSleepBand?
    let note: String?

    var id: String { key }
}

struct ProgrammeSleepDetail: Codable {
    let from: String?
    let to: String?
    let nights: Int
    let spanDays: Int
    let staleDays: Int
    let workNights: Int
    let freeNights: Int
    let pairs: Int
    let axis: ProgrammeSleepAxis?
    let strip: [ProgrammeNightPoint]
    let metrics: [ProgrammeSleepMetric]
    let hits: Int
    let total: Int
}

// MARK: - Corps de requêtes (écritures)

/// `POST api/programme/activate` — mêmes clés que `activate()` (Angular) :
/// pas de `startedOn`, le serveur défaut à aujourd'hui.
struct ProgrammeActivateRequest: Encodable {
    var programmeId: String
    var days: [Int]
}

struct ProgrammeStopRequest: Encodable {
    var kind: String
}

/// `POST api/programme/session`. `activityId`/`date` restent `nil` — cet
/// écran simplifie la bascule d'une séance (cf. `ProgrammeViewModel`), le
/// rapprochement avec une activité importée (`api/programme/candidates`)
/// n'est pas câblé.
struct ProgrammeSessionRequest: Encodable {
    var week: Int
    var session: String
    var done: Bool
    var date: String?
    var activityId: Int?
}

struct ProgrammePushResponse: Decodable {
    let status: String
    let files: Int?
    let already: Bool?
}

struct ProgrammePushStatus: Decodable {
    let state: String
    let at: String?
}

// MARK: - Dates calendaires

/// Parsing/formatage des chaînes `YYYY-MM-DD` de cet écran — toujours en UTC
/// pour rester aligné avec le serveur (`weekOf`/`addDays`/`weekdayOf` dans
/// `progress.ts` calculent tous en `Z`), et pour éviter qu'une même clé
/// calendaire glisse de jour selon le fuseau de l'appareil.
enum ProgrammeDate {
    static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Lettres courtes des jours — index 0 dimanche … 6 samedi, même
    /// convention que `Date.getDay()`/`getUTCDay()` JS et que
    /// `ProgrammeActive.days`/`ProgrammeNightPoint.weekday`.
    static let weekdayLetters = ["D", "L", "M", "M", "J", "V", "S"]

    static func today() -> String { keyFormatter.string(from: Date()) }

    static func date(from key: String) -> Date? { keyFormatter.date(from: key) }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func addDays(_ key: String, _ days: Int) -> String? {
        guard let date = date(from: key),
              let shifted = utcCalendar().date(byAdding: .day, value: days, to: date)
        else { return nil }
        return keyFormatter.string(from: shifted)
    }

    /// Jour de semaine JS-style (0 = dimanche … 6 = samedi) d'une clé
    /// calendaire.
    static func weekday(of key: String) -> Int? {
        guard let date = date(from: key) else { return nil }
        // `Calendar.component(.weekday)` : 1 = dimanche … 7 = samedi.
        return utcCalendar().component(.weekday, from: date) - 1
    }

    /// Nombre de jours calendaires entre deux clés (`to` − `from`), `nil` si
    /// l'une des deux est invalide — équivalent `daysBetween`/le calcul de
    /// `since` côté Angular, mais en différence de dates plutôt que de
    /// millisecondes (évite les soucis de fuseau/heure d'été).
    static func daysBetween(_ from: String, _ to: String) -> Int? {
        guard let fromDate = date(from: from), let toDate = date(from: to) else { return nil }
        return utcCalendar().dateComponents([.day], from: fromDate, to: toDate).day
    }

    /// "23 sept." — équivalent `dayLabel()` (Angular), toujours en français.
    static func shortLabel(_ key: String?) -> String {
        guard let key, let date = date(from: key) else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }
}
