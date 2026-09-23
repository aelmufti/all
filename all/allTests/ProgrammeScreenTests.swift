//
//  ProgrammeScreenTests.swift
//  allTests
//
//  Tests de décodage de l'écran Programme (`Pulse/Screens/Programme/`) —
//  fixtures JSON en dur reprenant la forme réelle de
//  `custom-connect/server/src/programme/programme.controller.ts` (+
//  `catalogue.ts`/`progress.ts`/`sleep.ts`), **aucun réseau**. Couvre
//  spécifiquement le point le plus fragile de cet écran : le `detail`
//  polymorphe par domaine (`ProgrammeDomainView.init(from:)`), plus quelques
//  fonctions pures de présentation portées depuis `ProgrammeComponent`
//  (Angular) qui méritent une vérification de fidélité (`programmeBadge`,
//  `programmeWeekDays`, `programmeNextLabel`).
//

import Testing
import Foundation
@testable import all

// MARK: - Fixture principale : `GET api/programme`

private let currentJSON = Data(
    """
    {
      "date": "2026-09-23",
      "domains": [
        {
          "kind": "training",
          "label": "Entraînement",
          "drives": "Séances et calendrier",
          "hint": "Les séances se cochent avec les activités importées de la montre.",
          "choices": [
            {"id": "seche-escalade-nutrients-2021", "name": "Sèche — escalade, trois séances", "goal": "Garder le niveau de bloc", "source": "Ruiz-Castellano et al., Nutrients 2021", "weeks": 4, "rules": 0, "perWeek": 3},
            {"id": "debug-course-pipeline", "name": "Debug — course, envoi montre", "goal": "Faire tourner l’envoi de bout en bout", "source": "Programme de test", "weeks": 2, "rules": 0, "perWeek": 2}
          ],
          "active": {
            "programmeId": "debug-course-pipeline",
            "startedOn": "2026-09-16",
            "name": "Debug — course, envoi montre",
            "goal": "Faire tourner l’envoi de bout en bout",
            "source": "Programme de test",
            "week": 2,
            "weeks": 2,
            "days": [1, 3],
            "perWeek": 2,
            "notes": ["Programme de test : rien de ce qu’il contient n’a de valeur d’entraînement."]
          },
          "detail": {
            "focus": [
              {"index": 1, "focus": "Deux séances, deux fichiers : CN01 et CN02"},
              {"index": 2, "focus": null}
            ],
            "sessions": [
              {
                "week": 2,
                "session": {
                  "key": "debug-course-minutee", "name": "Debug A — course minutée", "sport": "running",
                  "subSport": null, "minMinutes": null,
                  "items": [
                    {"name": "Échauffement", "prescription": "5 min de marche", "note": null},
                    {"name": "Course facile", "prescription": "3 min en aisance respiratoire", "note": "Étape à durée."}
                  ]
                },
                "plannedOn": "2026-09-24", "status": "done", "done": true, "date": "2026-09-24", "activityId": 55, "manual": false
              },
              {
                "week": 2,
                "session": {
                  "key": "debug-course-variante", "name": "Debug C — trois fois 1 min", "sport": "running",
                  "subSport": null, "minMinutes": null,
                  "items": [{"name": "Échauffement", "prescription": "1 min de marche", "note": null}]
                },
                "plannedOn": "2026-09-23", "status": "today", "done": false, "date": null, "activityId": null, "manual": false
              }
            ],
            "done": 1, "total": 2, "missed": 0,
            "today": []
          }
        },
        {
          "kind": "nutrition",
          "label": "Alimentation",
          "drives": "Cibles de la page Nutrition",
          "hint": "Les cibles du jour sont recadrées par les règles du programme.",
          "choices": [
            {"id": "seche-nutrients-2021", "name": "Sèche — rétention de masse maigre", "goal": "Perdre du gras en gardant le muscle", "source": "Ruiz-Castellano et al., Nutrients 2021", "weeks": 0, "rules": 4, "perWeek": 0}
          ],
          "active": null,
          "detail": null
        },
        {
          "kind": "sleep",
          "label": "Sommeil",
          "drives": "Lecture des nuits de la montre",
          "hint": "Les nuits déjà importées sont comparées aux critères du programme, il n’y a rien à saisir.",
          "choices": [
            {"id": "sommeil-regularite-nsf-2023", "name": "Sommeil — régularité des horaires", "goal": "Se coucher et se lever à la même heure", "source": "Sletten et al., Sleep Health 2023", "weeks": 0, "rules": 6, "perWeek": 0}
          ],
          "active": {
            "programmeId": "sommeil-regularite-nsf-2023",
            "startedOn": "2026-09-01",
            "name": "Sommeil — régularité des horaires",
            "goal": "Se coucher et se lever à la même heure",
            "source": "Sletten et al., Sleep Health 2023",
            "week": 0,
            "weeks": 0,
            "days": [1, 2, 3, 4, 5],
            "perWeek": 0,
            "notes": ["Le panel a voté trois affirmations."]
          },
          "detail": {
            "from": "2026-09-10", "to": "2026-09-22", "nights": 3, "spanDays": 13, "staleDays": 1,
            "workNights": 2, "freeNights": 1, "pairs": 2,
            "axis": {"onsetMean": 1362.5, "onsetSd": 22.4, "wakeMean": 420.1, "wakeSd": 18.7},
            "strip": [
              {"date": "2026-09-20", "weekday": 0, "workDay": false, "onset": 1380, "wake": 1900, "sleepMin": 430},
              {"date": "2026-09-21", "weekday": 1, "workDay": true, "onset": 1350, "wake": 1860, "sleepMin": 410},
              {"date": "2026-09-22", "weekday": 2, "workDay": true, "onset": 1340, "wake": 1850, "sleepMin": 400}
            ],
            "metrics": [
              {
                "key": "coucher", "label": "Heure de coucher", "detail": "écart-type au plus 30 min",
                "evidence": "MESA, 1992 adultes…", "unit": "min", "informative": false,
                "value": 22, "range": {"min": null, "max": 30}, "scale": {"min": 0, "max": 120},
                "status": "hit", "band": {"upTo": 30, "label": "30 min ou moins", "risk": "catégorie de référence"},
                "note": "Coucher moyen à 22 h 42."
              },
              {
                "key": "sri", "label": "Indice de régularité (SRI)", "detail": "part des minutes",
                "evidence": "Le panel recommande.", "unit": "index", "informative": true,
                "value": 78, "range": {"min": null, "max": null}, "scale": {"min": 0, "max": 100},
                "status": "unknown", "band": {"upTo": 85, "label": "75 à 85", "risk": "horaires réguliers"},
                "note": null
              }
            ],
            "hits": 1, "total": 1
          }
        }
      ]
    }
    """.utf8)

private let pushPendingJSON = Data(#"{"status": "pending", "files": 3}"#.utf8)
private let pushAlreadyJSON = Data(#"{"status": "pending", "already": true, "files": 2}"#.utf8)
private let pushStatusRunningJSON = Data(#"{"state": "running", "at": null}"#.utf8)
private let pushStatusOkJSON = Data(#"{"state": "ok", "at": "2026-09-20T10:00:00.000Z"}"#.utf8)

// MARK: - Décodage de `ProgrammeCurrent`

struct ProgrammeCurrentDecodingTests {
    @Test func decodesThreeDomainsWithPolymorphicDetail() throws {
        let current = try JSONDecoder().decode(ProgrammeCurrent.self, from: currentJSON)
        #expect(current.date == "2026-09-23")
        #expect(current.domains.count == 3)
        #expect(current.domains.map(\.kind) == [.training, .nutrition, .sleep])
    }

    @Test func decodesTrainingDetailAndLocksAutoMatchedSession() throws {
        let current = try JSONDecoder().decode(ProgrammeCurrent.self, from: currentJSON)
        let training = current.domains[0]
        #expect(training.active?.programmeId == "debug-course-pipeline")
        #expect(training.active?.days == [1, 3])
        #expect(training.choices.count == 2)

        guard case .training(let detail) = training.detail else {
            Issue.record("attendu .training")
            return
        }
        #expect(detail.sessions.count == 2)
        #expect(detail.focus.first(where: { $0.index == 2 })?.focus == nil)
        let done = detail.sessions.first { $0.done }
        #expect(done?.manual == false)
        #expect(done?.activityId == 55)
        let pending = detail.sessions.first { !$0.done }
        #expect(pending?.status == .today)
    }

    @Test func decodesNutritionDomainWithoutActiveProgramme() throws {
        let current = try JSONDecoder().decode(ProgrammeCurrent.self, from: currentJSON)
        let nutrition = current.domains[1]
        #expect(nutrition.active == nil)
        #expect(nutrition.detail == nil)
        #expect(nutrition.choices.first?.rules == 4)
    }

    @Test func decodesSleepDetailWithInformativeAndScoredMetrics() throws {
        let current = try JSONDecoder().decode(ProgrammeCurrent.self, from: currentJSON)
        let sleep = current.domains[2]
        guard case .sleep(let detail) = sleep.detail else {
            Issue.record("attendu .sleep")
            return
        }
        #expect(detail.nights == 3)
        #expect(detail.strip.count == 3)
        #expect(detail.axis?.onsetSd == 22.4)

        let scored = detail.metrics.first { $0.key == "coucher" }
        #expect(scored?.informative == false)
        #expect(scored?.status == .hit)
        #expect(scored?.band?.label == "30 min ou moins")

        let informative = detail.metrics.first { $0.key == "sri" }
        #expect(informative?.informative == true)
        #expect(informative?.status == .unknown)
        #expect(informative?.note == nil)
    }
}

// MARK: - Corps de requêtes (sans réseau)

struct ProgrammeRequestEncodingTests {
    @Test func encodesActivateRequestWithProgrammeIdAndDays() throws {
        let body = ProgrammeActivateRequest(programmeId: "debug-course-pipeline", days: [1, 3, 5])
        let data = try JSONEncoder().encode(body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["programmeId"] as? String == "debug-course-pipeline")
        #expect(object?["days"] as? [Int] == [1, 3, 5])
    }

    @Test func encodesSessionRequestUncheckingWithoutActivity() throws {
        let body = ProgrammeSessionRequest(week: 2, session: "debug-course-variante", done: false, date: nil, activityId: nil)
        let data = try JSONEncoder().encode(body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["week"] as? Int == 2)
        #expect(object?["session"] as? String == "debug-course-variante")
        #expect(object?["done"] as? Bool == false)
    }
}

// MARK: - Envoi à la montre

struct ProgrammePushDecodingTests {
    @Test func decodesPushResponsePending() throws {
        let response = try JSONDecoder().decode(ProgrammePushResponse.self, from: pushPendingJSON)
        #expect(response.status == "pending")
        #expect(response.files == 3)
        #expect(response.already == nil)
    }

    @Test func decodesPushResponseAlreadyPending() throws {
        let response = try JSONDecoder().decode(ProgrammePushResponse.self, from: pushAlreadyJSON)
        #expect(response.already == true)
        #expect(response.files == 2)
    }

    @Test func decodesPushStatusRunningAndOk() throws {
        let running = try JSONDecoder().decode(ProgrammePushStatus.self, from: pushStatusRunningJSON)
        #expect(running.state == "running")
        #expect(running.at == nil)

        let ok = try JSONDecoder().decode(ProgrammePushStatus.self, from: pushStatusOkJSON)
        #expect(ok.state == "ok")
        #expect(ok.at == "2026-09-20T10:00:00.000Z")
    }
}

// MARK: - Fonctions pures de présentation (portage Angular)

struct ProgrammeFormattingTests {
    @Test func badgeShowsWeekOverWeeksWhenNotFinished() throws {
        let current = try JSONDecoder().decode(ProgrammeCurrent.self, from: currentJSON)
        #expect(programmeBadge(current.domains[0]) == "semaine 2 / 2")
    }

    @Test func nextLabelReportsPendingSessionOfShownWeek() throws {
        let current = try JSONDecoder().decode(ProgrammeCurrent.self, from: currentJSON)
        guard case .training(let detail) = current.domains[0].detail else {
            Issue.record("attendu .training")
            return
        }
        let label = programmeNextLabel(detail: detail, shownWeek: 2)
        #expect(label.hasPrefix("Debug C — trois fois 1 min"))
    }

    @Test func weekDaysMarksDoneAndPlannedCellsFromSessions() throws {
        let current = try JSONDecoder().decode(ProgrammeCurrent.self, from: currentJSON)
        let domain = current.domains[0]
        guard case .training(let detail) = domain.detail else {
            Issue.record("attendu .training")
            return
        }
        let cells = programmeWeekDays(domain: domain, detail: detail, shownWeek: 2)
        #expect(cells.count == 7)
        // startedOn "2026-09-16" + (shownWeek 2 - 1) * 7 jours → la semaine
        // affichée commence le 2026-09-23, cf. `addDays` (`progress.ts`).
        #expect(cells.first?.date == "2026-09-23")
        let doneCell = cells.first { $0.date == "2026-09-24" }
        #expect(doneCell?.state == "done")
        let plannedCell = cells.first { $0.date == "2026-09-23" }
        #expect(plannedCell?.state == "planned")
    }

    @Test func macroUnitMapsKcalAndGrams() {
        #expect(programmeMacroUnit("kcal") == "kcal")
        #expect(programmeMacroUnit("protein") == "g")
        #expect(programmeMacroUnit("unknown-metric") == "")
    }
}

// MARK: - `ProgrammeDate`

struct ProgrammeDateTests {
    @Test func weekdayMatchesJsGetDayConvention() {
        // 2026-09-20 est un dimanche.
        #expect(ProgrammeDate.weekday(of: "2026-09-20") == 0)
        #expect(ProgrammeDate.weekday(of: "2026-09-21") == 1)
    }

    @Test func addDaysShiftsCalendarKey() {
        #expect(ProgrammeDate.addDays("2026-09-23", 7) == "2026-09-30")
        #expect(ProgrammeDate.addDays("2026-09-23", -3) == "2026-09-20")
    }

    @Test func daysBetweenComputesDifference() {
        #expect(ProgrammeDate.daysBetween("2026-09-16", "2026-09-23") == 7)
        #expect(ProgrammeDate.daysBetween("2026-09-23", "2026-09-23") == 0)
    }
}
