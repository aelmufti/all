//
//  ActivityFormatting.swift
//  all (bridge-connect)
//
//  Portage des helpers de présentation du front Angular pour l'écran
//  Activités :
//  - `custom-connect/web/src/app/core/sports.ts` (`sportName`, `activityLabel`,
//    `exerciseName`) → `ActivitySport`.
//  - `custom-connect/web/src/app/core/api.types.ts` (`formatDuration`,
//    `formatPace`, `formatPaceSecPerKm`) → `ActivityFormat`.
//  - Parsing/affichage de `startTime` (chaîne ISO 8601, cf. `ActivityModels.swift`)
//    → `ActivityDateFormatting`.
//
//  Les icônes SF Symbols n'ont pas d'équivalent Angular direct (le front
//  utilise `<app-sport-icon>`, un SVG par sport) — mapping choisi ici, pas
//  une traduction 1:1.
//

import Foundation

/// Libellés/icônes par sport — mêmes clés que le front (`running`,
/// `training`, `walking`...).
enum ActivitySport {
    private static let labelsFR: [String: String] = [
        "running": "Course à pied",
        "training": "Entraînement",
        "walking": "Marche",
        "rockClimbing": "Escalade",
        "floorClimbing": "Montée d’étages",
        "swimming": "Natation",
        "cycling": "Vélo",
        "rowing": "Aviron",
        "racket": "Sport de raquette",
        "generic": "Autre",
    ]

    private static let subLabelsFR: [String: String] = [
        "strengthTraining": "Musculation",
        "breathing": "Respiration",
        "yoga": "Yoga",
        "cardioTraining": "Cardio",
        "indoorClimbing": "Escalade en salle",
        "bouldering": "Bloc",
        "lapSwimming": "Natation en piscine",
        "openWater": "Nage en eau libre",
        "indoorWalking": "Marche sur tapis",
        "indoorRunning": "Course sur tapis",
        "treadmill": "Tapis de course",
        "indoorRowing": "Rameur",
        "indoorCycling": "Vélo en salle",
        "padel": "Padel",
        "tennis": "Tennis",
        "badminton": "Badminton",
        "trail": "Trail",
        "hiking": "Randonnée",
    ]

    private static let icons: [String: String] = [
        "running": "figure.run",
        "training": "figure.strengthtraining.traditional",
        "walking": "figure.walk",
        "rockClimbing": "figure.climbing",
        "floorClimbing": "figure.stairs",
        "swimming": "figure.pool.swim",
        "cycling": "figure.outdoor.cycle",
        "rowing": "figure.rower",
        "racket": "figure.tennis",
    ]

    private static let exerciseLabelsFR: [String: String] = [
        "benchPress": "Développé couché",
        "row": "Rowing",
        "curl": "Curl biceps",
        "sitUp": "Relevé de buste",
        "crunch": "Crunch",
        "lateralRaise": "Élévations latérales",
        "tricepsExtension": "Extension triceps",
        "deadlift": "Soulevé de terre",
        "flye": "Écartés",
        "squat": "Squat",
        "pushUp": "Pompes",
        "pullUp": "Tractions",
        "shoulderPress": "Développé épaules",
        "legPress": "Presse à cuisses",
        "lunge": "Fentes",
        "plank": "Gainage",
        "hipRaise": "Relevé de bassin",
        "shrug": "Shrug",
        "calfRaise": "Mollets",
        "legCurl": "Leg curl",
        "legRaise": "Relevé de jambes",
        "runningExercise": "Course",
        "cardio": "Cardio",
    ]

    static func name(sport: String?) -> String {
        labelsFR[sport ?? ""] ?? sport ?? "Autre"
    }

    /// Équivalent `activityLabel` (Angular) : sous-sport connu en priorité,
    /// sinon nom du sport.
    static func label(sport: String?, subSport: String?) -> String {
        if let subSport, subSport != "generic", let sub = subLabelsFR[subSport] {
            return sub
        }
        return name(sport: sport)
    }

    static func icon(sport: String?) -> String {
        icons[sport ?? ""] ?? "figure.mixed.cardio"
    }

    static func exerciseName(_ category: String?) -> String {
        guard let category else { return "Non identifié" }
        if let label = exerciseLabelsFR[category] { return label }
        // Repli : "legCurl" → "leg curl" (même heuristique que le front).
        var out = ""
        for character in category {
            if character.isUppercase {
                out += " "
                out += character.lowercased()
            } else {
                out += String(character)
            }
        }
        return out
    }
}

/// Portage de `formatDuration`/`formatPace`/`formatPaceSecPerKm`
/// (`api.types.ts`) et de quelques petits formats locaux (`clock`, `shortDuration`)
/// utilisés par les pages `ActivitiesComponent`/`ActivityDetailComponent`.
enum ActivityFormat {
    /// "1h05" (≥ 1h) ou "12min05" (< 1h) — `formatDuration`.
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m)min\(String(format: "%02d", s))"
    }

    /// Version courte (ligne de liste) : "12 min" sous 1h, sinon `duration`.
    static func shortDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min" }
        return duration(seconds)
    }

    /// "5'12\"/km" — `formatPace`. `—` sous 100 m (bruit GPS/pas de distance).
    static func pace(durationS: Double?, distanceM: Double?) -> String {
        guard let durationS, let distanceM, distanceM >= 100 else { return "—" }
        return paceSecPerKm(durationS / (distanceM / 1000))
    }

    static func paceSecPerKm(_ secPerKm: Double?) -> String {
        guard let secPerKm, secPerKm.isFinite, secPerKm > 0 else { return "—" }
        let m = Int(secPerKm / 60)
        let s = Int((secPerKm.truncatingRemainder(dividingBy: 60)).rounded())
        return "\(m)'\(String(format: "%02d", s))\"/km"
    }

    /// "12,34 km" — séparateur décimal français, comme le front (`toFixed(2).replace('.', ',')`).
    static func distanceKm(_ meters: Double?) -> String? {
        guard let meters, meters > 0 else { return nil }
        return String(format: "%.2f", meters / 1000).replacingOccurrences(of: ".", with: ",") + " km"
    }

    /// "1:02:03" ou "4:05" — `clock` (Angular, tours/zones).
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// `startTime` est une chaîne ISO 8601 (cf. `ActivityModels.swift`) — parsing
/// centralisé ici, en heure/calendrier **locaux** de l'appareil (comme
/// `new Date(startTime)` côté Angular, qui interprète en fuseau local).
enum ActivityDateFormatting {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from iso: String?) -> Date? {
        guard let iso else { return nil }
        return withFractional.date(from: iso) ?? plain.date(from: iso)
    }

    /// "08:32" — heure locale sur 24h, indépendant du réglage régional de
    /// l'appareil (contrairement à `.formatted(.dateTime...)`, qui peut
    /// bascule en 12h AM/PM sur certaines locales).
    static func clock(_ date: Date?) -> String {
        guard let date else { return "—:—" }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "Lundi 23 septembre" — équivalent `dayLabel` (Angular), toujours en
    /// français (l'app comme Pulse sont francophones), quelle que soit la
    /// locale de l'appareil.
    static func dayLabel(_ date: Date?) -> String {
        guard let date else { return "Date inconnue" }
        let label = date.formatted(
            .dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR"))
        )
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// "lun. 23 sept. · 08:32" — équivalent `rangeLabel` (variante non
    /// embarquée, seule pertinente sur iOS où il n'y a pas de vue cote à
    /// cote).
    static func rangeLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let short = date.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "fr_FR"))
        )
        return "\(short) · \(clock(date))"
    }
}
