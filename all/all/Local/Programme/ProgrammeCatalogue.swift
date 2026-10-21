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
    /// Alimentation : variation de poids visée, en % du poids par semaine,
    /// signée (+ prise, 0 maintien, − perte). Fixe le bilan énergétique.
    let weeklyWeightPct: Double?

    init(
        id: String, kind: ProgrammeEngineKind, name: String, goal: String, source: String,
        weeks: [ProgrammeEngineWeek] = [], rules: [ProgrammeEngineNutritionRule] = [],
        sleepRules: [ProgrammeEngineSleepRule] = [], notes: [String] = [], weeklyWeightPct: Double? = nil
    ) {
        self.weeklyWeightPct = weeklyWeightPct
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

    private static let maintainNutrition = ProgrammeEngineProgramme(
        id: "maintien-nutrition-acsm-2016", kind: .nutrition, name: "Maintien — poids stable",
        goal: "Garder le poids et nourrir l’entraînement",
        source: "Thomas et al., J Acad Nutr Diet 2016;116:501 — position ACSM/AND/DC",
        rules: [
            ProgrammeEngineNutritionRule(
                key: "protein", label: "Protéines", detail: "1,6 à 2,0 g par kg de poids", metric: "protein",
                min: 1.6, max: 2, perKg: true),
            ProgrammeEngineNutritionRule(
                key: "carbs", label: "Glucides", detail: "3 à 5 g par kg de poids", metric: "carbs",
                min: 3, max: 5, perKg: true),
            ProgrammeEngineNutritionRule(
                key: "fiber", label: "Fibres", detail: "au moins 25 g par jour", metric: "fiber", min: 25),
        ],
        notes: [
            "La cible du jour est la dépense du jour : ni déficit ni surplus, le poids reste stable.",
            "Répartir les protéines sur trois à cinq prises.",
            "Caler les glucides sur les jours d’entraînement.",
        ],
        weeklyWeightPct: 0)

    private static let leanMass = ProgrammeEngineProgramme(
        id: "masse-seche-nutrition-iraki-2019", kind: .nutrition, name: "Masse sèche — léger surplus",
        goal: "Prendre du muscle sans prendre de gras", source: "Iraki et al., Sports 2019;7:154",
        rules: [
            ProgrammeEngineNutritionRule(
                key: "protein", label: "Protéines", detail: "1,6 à 2,2 g par kg de poids", metric: "protein",
                min: 1.6, max: 2.2, perKg: true),
            ProgrammeEngineNutritionRule(
                key: "carbs", label: "Glucides", detail: "3 à 5 g par kg de poids", metric: "carbs",
                min: 3, max: 5, perKg: true),
            ProgrammeEngineNutritionRule(
                key: "fat", label: "Lipides", detail: "0,5 à 1,5 g par kg de poids", metric: "fat",
                min: 0.5, max: 1.5, perKg: true),
            ProgrammeEngineNutritionRule(
                key: "fiber", label: "Fibres", detail: "au moins 25 g par jour", metric: "fiber", min: 25),
        ],
        notes: [
            "Viser 0,25 % du poids par semaine, le bas de la fourchette de la revue (0,25 à 0,5 %) : au-delà, le surplus part surtout en gras chez un pratiquant entraîné.",
            "Si la balance ne bouge pas en trois semaines, ajouter une centaine de kcal.",
            "Répartir les protéines sur trois à six prises.",
        ],
        weeklyWeightPct: 0.25)

    private static let climbBlock = ProgrammeEngineProgramme(
        id: "seche-escalade-nutrients-2021", kind: .training, name: "Sèche — escalade, trois séances",
        goal: "Garder le niveau de bloc pendant le déficit", source: "Ruiz-Castellano et al., Nutrients 2021;13:3255",
        weeks: buildClimbWeeks(),
        notes: [
            "Trois séances par semaine : deux d’escalade, une de renfo. C’est le rythme de tes huit dernières semaines, pas une cible à dépasser.",
            "Pendant un déficit, l’intensité protège le muscle, pas le volume : garder les essais durs et couper le reste.",
            "La marche quotidienne fait déjà la dépense : inutile d’ajouter du cardio par-dessus, il ronge la récupération.",
        ])

    // MARK: - Escalade partagée (climbIntensity / climbVolume)

    private static func climbIntensity(key: String, note: String) -> ProgrammeEngineTrainingSession {
        ProgrammeEngineTrainingSession(
            key: key, name: "Escalade — intensité", sport: "rockClimbing",
            subSport: "indoorClimbing", minMinutes: 45,
            items: [
                ProgrammeEngineTrainingItem(name: "Échauffement progressif", prescription: "15 min, blocs faciles en montant", note: nil),
                ProgrammeEngineTrainingItem(
                    name: "Blocs limites", prescription: "5 à 8 essais maximum, repos long entre chaque", note: note),
                ProgrammeEngineTrainingItem(name: "Retour au calme", prescription: "10 min de blocs faciles", note: nil),
            ])
    }

    private static func climbVolume(key: String) -> ProgrammeEngineTrainingSession {
        ProgrammeEngineTrainingSession(
            key: key, name: "Escalade — volume", sport: "rockClimbing",
            subSport: "indoorClimbing", minMinutes: 45,
            items: [
                ProgrammeEngineTrainingItem(name: "Échauffement", prescription: "10 à 15 min", note: nil),
                ProgrammeEngineTrainingItem(name: "Blocs deux crans sous le max", prescription: "10 à 15 blocs, repos court", note: nil),
                ProgrammeEngineTrainingItem(name: "Travail de pieds", prescription: "10 min en silence, sans lâcher les prises", note: nil),
            ])
    }

    // MARK: - Maintien (MAINTAIN_BLOCK)

    private static let maintainClimbHard = climbIntensity(
        key: "maintien-escalade-intensite",
        note: "Garder les essais au niveau max : c’est l’intensité qui maintient, pas le volume.")
    private static let maintainClimbVolume = climbVolume(key: "maintien-escalade-volume")

    private static let maintainLift = ProgrammeEngineTrainingSession(
        key: "maintien-muscu", name: "Muscu — entretien", sport: "training",
        subSport: "strengthTraining", minMinutes: 30,
        items: [
            ProgrammeEngineTrainingItem(name: "Échauffement", prescription: "10 min, montée en charge sur le squat", note: nil),
            ProgrammeEngineTrainingItem(
                name: "Squat ou presse", prescription: "2 × 6 à 8, une à deux répétitions en réserve",
                note: "Garder la charge lourde : une séance par semaine suffit si l’intensité ne baisse pas."),
            ProgrammeEngineTrainingItem(name: "Développé couché", prescription: "2 × 6 à 10, une à deux répétitions en réserve", note: nil),
            ProgrammeEngineTrainingItem(name: "Soulevé de terre roumain", prescription: "2 × 8 à 10, deux répétitions en réserve", note: nil),
            ProgrammeEngineTrainingItem(name: "Développé militaire", prescription: "2 × 8 à 10, deux répétitions en réserve", note: nil),
            ProgrammeEngineTrainingItem(name: "Rotateurs externes", prescription: "2 × 15 à l’élastique", note: nil),
            ProgrammeEngineTrainingItem(name: "Gainage anti-rotation", prescription: "2 × 30 s par côté", note: nil),
        ])

    private static let maintainLiftLight = ProgrammeEngineTrainingSession(
        key: "maintien-muscu-allegee", name: "Muscu — semaine allégée", sport: "training",
        subSport: "strengthTraining", minMinutes: 20,
        items: [
            ProgrammeEngineTrainingItem(name: "Échauffement", prescription: "10 min", note: nil),
            ProgrammeEngineTrainingItem(name: "Squat ou presse", prescription: "1 × 6, mêmes charges, trois répétitions en réserve", note: nil),
            ProgrammeEngineTrainingItem(name: "Développé couché", prescription: "1 × 6, mêmes charges, trois répétitions en réserve", note: nil),
            ProgrammeEngineTrainingItem(name: "Soulevé de terre roumain", prescription: "1 × 8, mêmes charges", note: nil),
            ProgrammeEngineTrainingItem(name: "Rotateurs externes", prescription: "2 × 15 à l’élastique", note: nil),
        ])

    private static let maintainFocus = [
        "Prise de repères : noter les charges et les blocs de référence",
        "Mêmes charges, mêmes blocs : l’intensité suffit à maintenir",
        "Une série passe avec trois répétitions en réserve : ajouter un cran",
        "Semaine allégée : muscu réduite, escalade au plaisir",
        "Reprise aux charges de la semaine 3",
        "On tient les charges, on ne rallonge pas les séances",
        "Tenter un bloc au-dessus du niveau de référence",
        "Semaine allégée : muscu réduite, escalade au plaisir",
        "Reprise aux charges de la semaine 7",
        "Même intensité, volume inchangé",
        "Dernière semaine pleine : comparer aux repères de la semaine 1",
        "Semaine allégée et bilan du bloc",
    ]

    private static func buildMaintainWeeks() -> [ProgrammeEngineWeek] {
        maintainFocus.enumerated().map { i, focus in
            ProgrammeEngineWeek(
                index: i + 1, focus: focus,
                sessions: [maintainClimbHard, (i + 1) % 4 == 0 ? maintainLiftLight : maintainLift, maintainClimbVolume])
        }
    }

    private static let maintainBlock = ProgrammeEngineProgramme(
        id: "maintien-escalade-muscu-jscr-2021", kind: .training, name: "Maintien — escalade et muscu",
        goal: "Garder force, muscle et niveau de bloc avec le minimum efficace",
        source: "Spiering et al., J Strength Cond Res 2021;35:1449",
        weeks: buildMaintainWeeks(),
        notes: [
            "Trois séances par semaine : deux d’escalade, une de muscu. La revue montre que force et masse se maintiennent avec une séance par semaine, une à trois séries par exercice.",
            "Le volume peut baisser, l’intensité jamais : garder des charges lourdes et des essais durs, c’est ce qui retient les acquis.",
            "Une semaine allégée toutes les quatre. Trois cycles de quatre semaines, puis le bloc se relance.",
        ])

    // MARK: - Masse sèche (MASS_BLOCK)

    private struct MassCycle {
        let key: String
        let heavy: String
        let accessory: String
        let focus: [String]
    }

    private static let massCycles: [MassCycle] = [
        MassCycle(
            key: "c1",
            heavy: "3 × 8 à 10, deux à trois répétitions en réserve",
            accessory: "3 × 10 à 12, deux répétitions en réserve",
            focus: [
                "Prise de repères : charges à deux ou trois répétitions de l’échec",
                "Ajouter une répétition par série avant d’ajouter du poids",
                "Haut de fourchette atteint sur toutes les séries : monter la charge",
            ]),
        MassCycle(
            key: "c2",
            heavy: "4 × 8 à 10, une à deux répétitions en réserve",
            accessory: "4 × 10 à 12, une à deux répétitions en réserve",
            focus: [
                "Une série de plus sur chaque mouvement",
                "Se rapprocher de l’échec : une à deux répétitions en réserve",
                "Pic de volume du bloc",
            ]),
        MassCycle(
            key: "c3",
            heavy: "4 × 6 à 8, une à deux répétitions en réserve",
            accessory: "3 × 8 à 10, une répétition en réserve",
            focus: [
                "Charges plus lourdes, répétitions plus basses",
                "Progresser en charge, pas en séries",
                "Dernière semaine pleine : comparer aux repères de la semaine 1",
            ]),
    ]

    private static func massLiftA(cycle: Int, heavy: String, accessory: String) -> ProgrammeEngineTrainingSession {
        ProgrammeEngineTrainingSession(
            key: "masse-muscu-a-\(cycle > 0 ? "c\(cycle)" : "allegee")",
            name: cycle > 0 ? "Muscu A — cycle \(cycle)" : "Muscu A — semaine allégée",
            sport: "training", subSport: "strengthTraining", minMinutes: cycle > 0 ? 40 : 25,
            items: [
                ProgrammeEngineTrainingItem(name: "Échauffement", prescription: "10 min, montée en charge sur le squat", note: nil),
                ProgrammeEngineTrainingItem(
                    name: "Squat", prescription: heavy,
                    note: "Repos de deux à trois minutes. Monter la charge dès que le haut de la fourchette passe partout."),
                ProgrammeEngineTrainingItem(name: "Développé couché", prescription: heavy, note: nil),
                ProgrammeEngineTrainingItem(
                    name: "Rowing haltère", prescription: accessory,
                    note: "L’escalade fait déjà travailler le dos : le rowing complète sans user les doigts."),
                ProgrammeEngineTrainingItem(name: "Élévations latérales", prescription: accessory, note: nil),
                ProgrammeEngineTrainingItem(name: "Rotateurs externes", prescription: "2 × 15 à l’élastique", note: nil),
            ])
    }

    private static func massLiftB(cycle: Int, heavy: String, accessory: String) -> ProgrammeEngineTrainingSession {
        ProgrammeEngineTrainingSession(
            key: "masse-muscu-b-\(cycle > 0 ? "c\(cycle)" : "allegee")",
            name: cycle > 0 ? "Muscu B — cycle \(cycle)" : "Muscu B — semaine allégée",
            sport: "training", subSport: "strengthTraining", minMinutes: cycle > 0 ? 40 : 25,
            items: [
                ProgrammeEngineTrainingItem(name: "Échauffement", prescription: "10 min, montée en charge sur le soulevé", note: nil),
                ProgrammeEngineTrainingItem(name: "Soulevé de terre roumain", prescription: heavy, note: nil),
                ProgrammeEngineTrainingItem(name: "Développé militaire", prescription: heavy, note: nil),
                ProgrammeEngineTrainingItem(name: "Fentes bulgares", prescription: "\(accessory), par jambe", note: nil),
                ProgrammeEngineTrainingItem(name: "Dips ou pompes lestées", prescription: accessory, note: nil),
                ProgrammeEngineTrainingItem(name: "Gainage anti-rotation", prescription: "3 × 30 s par côté", note: nil),
            ])
    }

    private static let massLightHeavy = "2 × 8, mêmes charges que la semaine précédente"
    private static let massLightAccessory = "2 × 10, mêmes charges"
    private static let massClimbHard = climbIntensity(
        key: "masse-escalade-intensite",
        note: "Le poids monte : garder les essais durs pour que le niveau suive la balance.")
    private static let massClimbVolume = climbVolume(key: "masse-escalade-volume")

    private static func buildMassWeeks() -> [ProgrammeEngineWeek] {
        let lightA = massLiftA(cycle: 0, heavy: massLightHeavy, accessory: massLightAccessory)
        let lightB = massLiftB(cycle: 0, heavy: massLightHeavy, accessory: massLightAccessory)
        var weeks: [ProgrammeEngineWeek] = []
        for (c, cycle) in massCycles.enumerated() {
            let liftA = massLiftA(cycle: c + 1, heavy: cycle.heavy, accessory: cycle.accessory)
            let liftB = massLiftB(cycle: c + 1, heavy: cycle.heavy, accessory: cycle.accessory)
            for (w, focus) in cycle.focus.enumerated() {
                weeks.append(
                    ProgrammeEngineWeek(
                        index: c * 4 + w + 1, focus: focus,
                        sessions: [liftA, massClimbHard, liftB, massClimbVolume]))
            }
            weeks.append(
                ProgrammeEngineWeek(
                    index: c * 4 + 4,
                    focus: c == massCycles.count - 1
                        ? "Semaine allégée et bilan du bloc"
                        : "Semaine allégée : moitié des séries, mêmes charges",
                    sessions: [lightA, massClimbHard, lightB, massClimbVolume]))
        }
        return weeks
    }

    private static let massBlock = ProgrammeEngineProgramme(
        id: "masse-seche-muscu-escalade-schoenfeld", kind: .training, name: "Masse sèche — muscu et escalade",
        goal: "Prendre du muscle sans prendre de gras",
        source: "Schoenfeld et al., Sports Med 2016;46:1689 et J Sports Sci 2017;35:1073",
        weeks: buildMassWeeks(),
        notes: [
            "Quatre séances par semaine : deux de muscu, deux d’escalade. Chaque muscle travaille deux fois par semaine, la fréquence qui fait le plus grossir à volume égal.",
            "Le volume monte d’un cycle à l’autre jusqu’à une dizaine de séries par grand groupe musculaire et par semaine, là où la relation dose-réponse reste nette.",
            "Une semaine allégée toutes les quatre : moitié des séries, mêmes charges. C’est elle qui permet de repartir plus lourd.",
            "Sans gras, la prise de poids se règle à l’assiette : côté entraînement, ce qui compte, c’est que les charges montent. Noter chaque séance.",
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

    static let programmes: [ProgrammeEngineProgramme] = [fatLoss, maintainNutrition, leanMass, climbBlock, maintainBlock, massBlock, sleepRegularity, debugRun]

    static func programme(byId id: String) -> ProgrammeEngineProgramme? {
        programmes.first { $0.id == id }
    }

    static func ruleCount(_ programme: ProgrammeEngineProgramme) -> Int {
        programme.kind == .sleep ? programme.sleepRules.count : programme.rules.count
    }
}
