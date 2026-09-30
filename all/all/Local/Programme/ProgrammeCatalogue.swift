//
//  ProgrammeCatalogue.swift
//  all (bridge-connect)
//
//  Portage Swift du catalogue statique de programmes —
//  `custom-connect/server/src/programme/catalogue.ts` (incrément L7a, cf.
//  `docs/stockage-local.md`). Données STATIQUES reproduites À L'IDENTIQUE
//  (textes français compris) : ce fichier n'a rien à calculer, juste à
//  exister avec le même contenu que la source TS.
//
//  Convention de nommage : préfixe `ProgrammeEngine*` pour tous les types
//  internes au moteur — jamais les types `Programme*` sans suffixe, qui sont
//  les modèles `Codable` de l'écran (`Pulse/Screens/Programme/ProgrammeModels.swift`,
//  MÊME module, une redéclaration entrerait en collision) — même discipline
//  que `NutritionEngine*` dans `Local/NutritionTarget.swift`.
//

import Foundation

enum ProgrammeEngineKind: String {
    case training
    case nutrition
    case sleep
}

struct ProgrammeEngineTrainingItem {
    let name: String
    let prescription: String
    let note: String?
}

struct ProgrammeEngineTrainingSession {
    let key: String
    let name: String
    let sport: String
    let subSport: String?
    let minMinutes: Int?
    let items: [ProgrammeEngineTrainingItem]
}

/// `metric`: `"protein" | "carbs" | "fat" | "kcal" | "fiber"` — chaîne brute
/// (pas d'enum) : passée telle quelle au JSON (`LocalProgrammeRuleRefDTO.metric`)
/// et utilisée par `ProgrammeProgressEngine.checkDay` pour choisir le champ
/// de `ProgrammeEngineDayIntake` à comparer.
struct ProgrammeEngineNutritionRule {
    let key: String
    let label: String
    let detail: String
    let metric: String
    let min: Double?
    let max: Double?
    /// `false` par défaut (miroir de `perKg?: boolean` TS, absent = falsy) —
    /// cf. `ProgrammeEngineNutritionRule` → `LocalProgrammeRuleRefDTO.perKg`
    /// dans `RealLocalPulseBackend` : encodé `nil` (clé omise) quand `false`,
    /// jamais un littéral `false` explicite (même comportement que
    /// `JSON.stringify` omettant une clé `undefined`).
    let perKg: Bool

    init(key: String, label: String, detail: String, metric: String, min: Double? = nil, max: Double? = nil, perKg: Bool = false) {
        self.key = key
        self.label = label
        self.detail = detail
        self.metric = metric
        self.min = min
        self.max = max
        self.perKg = perKg
    }
}

enum ProgrammeEngineSleepMetricKey: String {
    case onsetSd, durationSd, meanDuration, socialJetlag, catchUp, sri
}

enum ProgrammeEngineSleepUnit: String {
    case min
    case duration
    case index
}

struct ProgrammeEngineSleepBand {
    let upTo: Double?
    let label: String
    let risk: String
}

struct ProgrammeEngineSleepRule {
    let key: String
    let label: String
    let detail: String
    let metric: ProgrammeEngineSleepMetricKey
    let unit: ProgrammeEngineSleepUnit
    let min: Double?
    let max: Double?
    let scaleMin: Double
    let scaleMax: Double
    let informative: Bool
    let bands: [ProgrammeEngineSleepBand]
    let evidence: String

    init(
        key: String, label: String, detail: String, metric: ProgrammeEngineSleepMetricKey, unit: ProgrammeEngineSleepUnit,
        min: Double? = nil, max: Double? = nil, scaleMin: Double, scaleMax: Double, informative: Bool = false,
        bands: [ProgrammeEngineSleepBand] = [], evidence: String
    ) {
        self.key = key
        self.label = label
        self.detail = detail
        self.metric = metric
        self.unit = unit
        self.min = min
        self.max = max
        self.scaleMin = scaleMin
        self.scaleMax = scaleMax
        self.informative = informative
        self.bands = bands
        self.evidence = evidence
    }
}

struct ProgrammeEngineWeek {
    let index: Int
    let focus: String?
    let sessions: [ProgrammeEngineTrainingSession]
}

struct ProgrammeEngineDomain {
    let kind: ProgrammeEngineKind
    let label: String
    let drives: String
    let hint: String
}

struct ProgrammeEngineProgramme {
    let id: String
    let kind: ProgrammeEngineKind
    let name: String
    let goal: String
    let source: String
    let weeks: [ProgrammeEngineWeek]
    let rules: [ProgrammeEngineNutritionRule]
    let sleepRules: [ProgrammeEngineSleepRule]
    let notes: [String]

    init(
        id: String, kind: ProgrammeEngineKind, name: String, goal: String, source: String,
        weeks: [ProgrammeEngineWeek] = [], rules: [ProgrammeEngineNutritionRule] = [],
        sleepRules: [ProgrammeEngineSleepRule] = [], notes: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.goal = goal
        self.source = source
        self.weeks = weeks
        self.rules = rules
        self.sleepRules = sleepRules
        self.notes = notes
    }
}

enum ProgrammeCatalogue {
    static let domains: [ProgrammeEngineDomain] = [
        ProgrammeEngineDomain(
            kind: .training, label: "Entraînement", drives: "Séances et calendrier",
            hint: "Les séances se cochent avec les activités importées de la montre."),
        ProgrammeEngineDomain(
            kind: .nutrition, label: "Alimentation", drives: "Cibles de la page Nutrition",
            hint: "Les cibles du jour sont recadrées par les règles du programme."),
        ProgrammeEngineDomain(
            kind: .sleep, label: "Sommeil", drives: "Lecture des nuits de la montre",
            hint: "Les nuits déjà importées sont comparées aux critères du programme, il n’y a rien à saisir."),
    ]

    // MARK: - Sèche escalade (CLIMB_BLOCK)

    private static let climbSessions: [ProgrammeEngineTrainingSession] = [
        ProgrammeEngineTrainingSession(
            key: "escalade-intensite", name: "Escalade — intensité", sport: "rockClimbing",
            subSport: "indoorClimbing", minMinutes: 45,
            items: [
                ProgrammeEngineTrainingItem(name: "Échauffement progressif", prescription: "15 min, blocs faciles en montant", note: nil),
                ProgrammeEngineTrainingItem(
                    name: "Blocs limites", prescription: "5 à 8 essais maximum, 3 à 5 min de repos entre chaque",
                    note: "C’est la séance qui garde le niveau pendant le déficit : essais courts, repos longs."),
                ProgrammeEngineTrainingItem(name: "Retour au calme", prescription: "10 min de blocs faciles", note: nil),
            ]),
        ProgrammeEngineTrainingSession(
            key: "escalade-volume", name: "Escalade — volume", sport: "rockClimbing",
            subSport: "indoorClimbing", minMinutes: 45,
            items: [
                ProgrammeEngineTrainingItem(name: "Échauffement", prescription: "10 à 15 min", note: nil),
                ProgrammeEngineTrainingItem(name: "Blocs deux crans sous le max", prescription: "10 à 15 blocs, repos court", note: nil),
                ProgrammeEngineTrainingItem(name: "Travail de pieds", prescription: "10 min en silence, sans lâcher les prises", note: nil),
            ]),
        ProgrammeEngineTrainingSession(
            key: "renfo", name: "Renfo complémentaire", sport: "training",
            subSport: "strengthTraining", minMinutes: 25,
            items: [
                ProgrammeEngineTrainingItem(
                    name: "Poussée : développé couché ou pompes lestées", prescription: "4 × 6 à 8, deux répétitions en réserve",
                    note: "L’escalade ne tire que d’un côté : la poussée équilibre l’épaule."),
                ProgrammeEngineTrainingItem(name: "Jambes : squat ou presse", prescription: "3 × 6 à 10", note: nil),
                ProgrammeEngineTrainingItem(name: "Rotateurs externes", prescription: "3 × 15 à l’élastique", note: nil),
                ProgrammeEngineTrainingItem(name: "Gainage anti-rotation", prescription: "3 × 30 s par côté", note: nil),
            ]),
    ]

    private static let weekFocus = [
        "Prise de repères : on garde le niveau de blocs d’avant le déficit",
        "Même intensité, on ne rallonge pas les séances",
        "Le niveau baisse un peu : on garde les essais durs, on coupe le volume",
        "Semaine allégée : deux séances suffisent si la récupération traîne",
    ]

    private static func buildClimbWeeks() -> [ProgrammeEngineWeek] {
        weekFocus.enumerated().map { ProgrammeEngineWeek(index: $0.offset + 1, focus: $0.element, sessions: climbSessions) }
    }

    private static let fatLoss = ProgrammeEngineProgramme(
        id: "seche-nutrients-2021", kind: .nutrition, name: "Sèche — rétention de masse maigre",
        goal: "Perdre du gras en gardant le muscle", source: "Ruiz-Castellano et al., Nutrients 2021;13:3255",
        rules: [
            ProgrammeEngineNutritionRule(
                key: "protein", label: "Protéines", detail: "2,2 à 3,0 g par kg de poids", metric: "protein",
                min: 2.2, max: 3, perKg: true),
            ProgrammeEngineNutritionRule(
                key: "carbs", label: "Glucides", detail: "2 à 5 g par kg de poids", metric: "carbs",
                min: 2, max: 5, perKg: true),
            ProgrammeEngineNutritionRule(
                key: "fat", label: "Lipides", detail: "0,5 à 1,0 g par kg de poids", metric: "fat",
                min: 0.5, max: 1, perKg: true),
            ProgrammeEngineNutritionRule(
                key: "fiber", label: "Fibres", detail: "au moins 25 g par jour", metric: "fiber", min: 25),
        ],
        notes: [
            "Viser le bas de la fourchette de perte : plus la descente est lente, moins la masse maigre part avec le gras.",
            "Répartir les protéines sur trois à six prises, dont une dans les deux à trois heures avant la séance et une après.",
            "Les glucides passent avant les lipides une fois les protéines servies : c’est l’ordre de priorité de la revue.",
        ])

    private static let climbBlock = ProgrammeEngineProgramme(
        id: "seche-escalade-nutrients-2021", kind: .training, name: "Sèche — escalade, trois séances",
        goal: "Garder le niveau de bloc pendant le déficit", source: "Ruiz-Castellano et al., Nutrients 2021;13:3255",
        weeks: buildClimbWeeks(),
        notes: [
            "Trois séances par semaine : deux d’escalade, une de renfo. C’est le rythme de tes huit dernières semaines, pas une cible à dépasser.",
            "Pendant un déficit, l’intensité protège le muscle, pas le volume : garder les essais durs et couper le reste.",
            "La marche quotidienne fait déjà la dépense : inutile d’ajouter du cardio par-dessus, il ronge la récupération.",
        ])

    // MARK: - Sommeil — régularité (SLEEP_REGULARITY)

    private static let onsetBands: [ProgrammeEngineSleepBand] = [
        ProgrammeEngineSleepBand(upTo: 30, label: "30 min ou moins", risk: "catégorie de référence"),
        ProgrammeEngineSleepBand(upTo: 60, label: "31 à 60 min", risk: "évènements cardiovasculaires ×1,16"),
        ProgrammeEngineSleepBand(upTo: 90, label: "61 à 90 min", risk: "évènements cardiovasculaires ×1,52"),
        ProgrammeEngineSleepBand(upTo: nil, label: "plus de 90 min", risk: "évènements cardiovasculaires ×2,11"),
    ]

    private static let durationBands: [ProgrammeEngineSleepBand] = [
        ProgrammeEngineSleepBand(upTo: 60, label: "60 min ou moins", risk: "catégorie de référence"),
        ProgrammeEngineSleepBand(upTo: 90, label: "61 à 90 min", risk: "évènements cardiovasculaires ×1,09"),
        ProgrammeEngineSleepBand(upTo: 120, label: "91 à 120 min", risk: "évènements cardiovasculaires ×1,59"),
        ProgrammeEngineSleepBand(upTo: nil, label: "plus de 120 min", risk: "évènements cardiovasculaires ×2,14"),
    ]

    private static let sriBands: [ProgrammeEngineSleepBand] = [
        ProgrammeEngineSleepBand(upTo: 60, label: "sous 60", risk: "horaires très dispersés"),
        ProgrammeEngineSleepBand(upTo: 75, label: "60 à 75", risk: "horaires dispersés"),
        ProgrammeEngineSleepBand(upTo: 85, label: "75 à 85", risk: "horaires réguliers"),
        ProgrammeEngineSleepBand(upTo: nil, label: "au-dessus de 85", risk: "horaires très réguliers"),
    ]

    private static let sleepRegularity = ProgrammeEngineProgramme(
        id: "sommeil-regularite-nsf-2023", kind: .sleep, name: "Sommeil — régularité des horaires",
        goal: "Se coucher et se lever à la même heure, tous les jours",
        source: "Sletten et al., Sleep Health 2023 — consensus NSF sur la variabilité des horaires",
        sleepRules: [
            ProgrammeEngineSleepRule(
                key: "coucher", label: "Heure de coucher", detail: "écart-type au plus 30 min", metric: .onsetSd,
                unit: .min, max: 30, scaleMin: 0, scaleMax: 120, bands: onsetBands,
                evidence: "MESA, 1992 adultes suivis en actigraphie puis 4,9 ans : au-delà de 90 min d’écart-type sur l’heure d’endormissement, le risque d’évènement cardiovasculaire est multiplié par 2,11 (IC 95 % 1,13–3,91) face à la catégorie 30 min ou moins. Chaque heure d’écart-type en plus vaut +18 %."),
            ProgrammeEngineSleepRule(
                key: "duree-ecart", label: "Durée des nuits", detail: "écart-type au plus 60 min", metric: .durationSd,
                unit: .min, max: 60, scaleMin: 0, scaleMax: 180, bands: durationBands,
                evidence: "Même cohorte : au-delà de 120 min d’écart-type sur la durée, le risque cardiovasculaire est multiplié par 2,14 (IC 95 % 1,24–3,68). Sur 2003 adultes, chaque heure d’écart-type en plus vaut +27 % de syndrome métabolique."),
            ProgrammeEngineSleepRule(
                key: "duree-moyenne", label: "Durée moyenne", detail: "entre 7 h et 9 h par nuit", metric: .meanDuration,
                unit: .duration, min: 420, max: 540, scaleMin: 240, scaleMax: 600,
                evidence: "Recommandation de durée de la National Sleep Foundation pour l’adulte, que ce consensus complète sans la remplacer : la régularité s’ajoute à la durée, elle ne la rachète pas."),
            ProgrammeEngineSleepRule(
                key: "decalage-social", label: "Décalage social", detail: "le milieu de nuit ne doit pas glisser de plus d’1 h",
                metric: .socialJetlag, unit: .min, max: 60, scaleMin: 0, scaleMax: 180,
                evidence: "Écart entre le milieu de nuit des jours libres et celui des jours travaillés. Le papier en fait la forme la plus courante d’irrégularité des pays industrialisés, associée à l’obésité, au diabète de type 2 et au syndrome métabolique."),
            ProgrammeEngineSleepRule(
                key: "rattrapage", label: "Rattrapage des jours libres", detail: "1 à 2 h de plus, seulement si la semaine est courte",
                metric: .catchUp, unit: .min, scaleMin: -60, scaleMax: 180,
                evidence: "Troisième vote du panel : quand la semaine ne suffit pas, dormir 1 à 2 h de plus les jours libres est associé à moins d’obésité, d’inflammation et de mortalité. Au-delà, le réveil tardif retarde la phase circadienne et se paie au premier réveil imposé."),
            ProgrammeEngineSleepRule(
                key: "sri", label: "Indice de régularité (SRI)", detail: "part des minutes passées dans le même état d’un jour au suivant",
                metric: .sri, unit: .index, scaleMin: 0, scaleMax: 100, informative: true, bands: sriBands,
                evidence: "Le panel recommande le SRI comme métrique commune, tout en refusant de fixer un seuil : ces paliers sont descriptifs, pas des valeurs de consensus. L’indice compare minute par minute l’état veille/sommeil d’un jour et du suivant — 100 = deux journées identiques."),
        ],
        notes: [
            "Le panel a voté trois affirmations : la régularité quotidienne compte pour la santé, elle compte pour la performance, et quand la semaine est trop courte le rattrapage des jours libres est utile.",
            "Aucun seuil n’a fait consensus — le papier dit explicitement qu’il n’y a pas assez de preuves pour fixer un chiffre. Les bandes affichées reprennent les catégories des deux seules études prospectives de la revue, sur 1992 et 2003 adultes.",
            "La fenêtre porte sur les quatorze dernières nuits enregistrées par la montre. Une sieste n’est pas comptée : la montre ne remonte qu’un épisode principal par nuit.",
        ])

    // MARK: - Debug (DEBUG_RUN)

    private static let debugRepeated = ProgrammeEngineTrainingSession(
        key: "debug-course-minutee", name: "Debug A — course minutée", sport: "running", subSport: nil, minMinutes: nil,
        items: [
            ProgrammeEngineTrainingItem(name: "Échauffement", prescription: "5 min de marche", note: nil),
            ProgrammeEngineTrainingItem(
                name: "Course facile", prescription: "3 min en aisance respiratoire",
                note: "Étape à durée : la montre doit enchaîner seule à la fin."),
            ProgrammeEngineTrainingItem(name: "Retour au calme", prescription: "2 min de marche", note: nil),
        ])

    private static let debugOpen = ProgrammeEngineTrainingSession(
        key: "debug-course-ouverte", name: "Debug B — étape ouverte", sport: "running", subSport: nil, minMinutes: nil,
        items: [
            ProgrammeEngineTrainingItem(name: "Échauffement", prescription: "5 min de marche", note: nil),
            ProgrammeEngineTrainingItem(
                name: "Tour libre", prescription: "sans durée, appuyer sur lap pour passer",
                note: "Étape ouverte : la montre doit attendre l’appui."),
            ProgrammeEngineTrainingItem(name: "Retour au calme", prescription: "2 min de marche", note: nil),
        ])

    private static let debugShort = ProgrammeEngineTrainingSession(
        key: "debug-course-variante", name: "Debug C — trois fois 1 min", sport: "running", subSport: nil, minMinutes: nil,
        items: [
            ProgrammeEngineTrainingItem(name: "Échauffement", prescription: "1 min de marche", note: nil),
            ProgrammeEngineTrainingItem(name: "Accélération", prescription: "1 min plus vite", note: nil),
            ProgrammeEngineTrainingItem(name: "Retour au calme", prescription: "1 min de marche", note: nil),
        ])

    private static let debugRun = ProgrammeEngineProgramme(
        id: "debug-course-pipeline", kind: .training, name: "Debug — course, envoi montre",
        goal: "Faire tourner l’envoi de bout en bout", source: "Programme de test, à retirer une fois la chaîne validée",
        weeks: [
            ProgrammeEngineWeek(index: 1, focus: "Deux séances, deux fichiers : CN01 et CN02", sessions: [debugRepeated, debugOpen]),
            ProgrammeEngineWeek(
                index: 2, focus: "Debug A revient à l’identique et ne repart pas : seul CN03 s’ajoute",
                sessions: [debugRepeated, debugShort]),
        ],
        notes: [
            "Programme de test : rien de ce qu’il contient n’a de valeur d’entraînement.",
            "Trois fichiers attendus — CN01 la séance commune aux deux semaines, CN02 la semaine 1, CN03 la semaine 2.",
            "Debug A enchaîne trois étapes minutées, Debug B tient sur une étape ouverte qui attend l’appui, Debug C tient en trois minutes.",
            "Aucune durée minimale : une sortie de trois minutes suffit à cocher la séance au retour de synchro.",
        ])

    static let programmes: [ProgrammeEngineProgramme] = [fatLoss, climbBlock, sleepRegularity, debugRun]

    static func programme(byId id: String) -> ProgrammeEngineProgramme? {
        programmes.first { $0.id == id }
    }

    static func ruleCount(_ programme: ProgrammeEngineProgramme) -> Int {
        programme.kind == .sleep ? programme.sleepRules.count : programme.rules.count
    }
}
