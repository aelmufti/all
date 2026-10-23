//
//  PulseDayPickerTests.swift
//  Logique pure du sélecteur de jour (semaine lundi-first, grille du mois,
//  bornes, conversion clé ↔ date). Données synthétiques, hors réseau.
//

import Foundation
import Testing
@testable import all

struct PulseDayPickerTests {
    private func cal(_ tz: String = "Europe/Paris") -> Calendar {
        PulseDayPicker.makeCalendar(timeZone: TimeZone(identifier: tz)!)
    }

    @Test func weekIsMondayFirst() {
        // 2026-10-23 est un vendredi.
        let week = PulseDayPicker.week(containing: "2026-10-23", calendar: cal())
        #expect(week == ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22",
                         "2026-10-23", "2026-10-24", "2026-10-25"])
        #expect(PulseDayPicker.week(containing: "2026-10-19", calendar: cal()).first == "2026-10-19")
        #expect(PulseDayPicker.week(containing: "2026-10-25", calendar: cal()).first == "2026-10-19")
    }

    @Test func weekCrossesMonthAndYear() {
        // 2026-12-31 est un jeudi.
        let week = PulseDayPicker.week(containing: "2026-12-31", calendar: cal())
        #expect(week.first == "2026-12-28")
        #expect(week.last == "2027-01-03")
        #expect(week.count == 7)
        #expect(PulseDayPicker.week(containing: "2026-03-01", calendar: cal()).first == "2026-02-23")
    }

    @Test func weekAcrossDST() {
        // Bascule heure d'été Europe/Paris : 2026-03-29 ; heure d'hiver : 2026-10-25.
        for tz in ["Europe/Paris", "America/New_York", "Pacific/Auckland"] {
            let c = cal(tz)
            let spring = PulseDayPicker.week(containing: "2026-03-29", calendar: c)
            #expect(spring.count == 7)
            #expect(spring.last == "2026-03-29", "\(tz)")
            #expect(Set(spring).count == 7)
            let autumn = PulseDayPicker.week(containing: "2026-10-25", calendar: c)
            #expect(autumn == ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22",
                               "2026-10-23", "2026-10-24", "2026-10-25"], "\(tz)")
            #expect(PulseDayPicker.addDays("2026-10-24", 1, calendar: c) == "2026-10-25")
            #expect(PulseDayPicker.addDays("2026-10-25", 1, calendar: c) == "2026-10-26")
        }
    }

    @Test func weekStartsSpanRange() {
        let starts = PulseDayPicker.weekStarts(from: "2026-10-01", to: "2026-10-23", calendar: cal())
        #expect(starts == ["2026-09-28", "2026-10-05", "2026-10-12", "2026-10-19"])
        #expect(PulseDayPicker.weekStarts(from: "2026-10-23", to: "2026-10-01", calendar: cal()).isEmpty)
    }

    @Test func monthGridOffsetAndCount() {
        // Octobre 2026 : le 1er est un jeudi (3 cases vides), 31 jours.
        let oct = PulseDayPicker.monthGrid(containing: "2026-10-23", calendar: cal())
        #expect(oct.count == 3 + 31)
        #expect(oct.prefix(3).allSatisfy { $0 == nil })
        #expect(oct[3] == "2026-10-01")
        #expect(oct.last! == "2026-10-31")
        // Juin 2026 : le 1er est un lundi (aucun vide), 30 jours.
        let june = PulseDayPicker.monthGrid(containing: "2026-06-15", calendar: cal())
        #expect(june.count == 30)
        #expect(june.first! == "2026-06-01")
        // Février bissextile 2028 : le 1er est un mardi, 29 jours.
        let feb = PulseDayPicker.monthGrid(containing: "2028-02-10", calendar: cal())
        #expect(feb.count == 1 + 29)
        // Mois finissant un dimanche : novembre 2026 commence un dimanche (6 vides).
        let nov = PulseDayPicker.monthGrid(containing: "2026-11-30", calendar: cal())
        #expect(nov.count == 6 + 30)
        #expect(PulseDayPicker.monthGrid(containing: "n/a").isEmpty)
    }

    @Test func monthShiftAndStart() {
        #expect(PulseDayPicker.monthStart(of: "2026-10-23") == "2026-10-01")
        #expect(PulseDayPicker.shiftMonth("2026-10-23", by: 1, calendar: cal()) == "2026-11-01")
        #expect(PulseDayPicker.shiftMonth("2026-01-31", by: -1, calendar: cal()) == "2025-12-01")
        #expect(PulseDayPicker.shiftMonth("2026-12-05", by: 1, calendar: cal()) == "2027-01-01")
    }

    @Test func boundsAndClamp() {
        let range = "2026-10-05"..."2026-10-23"
        #expect(PulseDayPicker.isSelectable("2026-10-05", in: range))
        #expect(PulseDayPicker.isSelectable("2026-10-23", in: range))
        #expect(!PulseDayPicker.isSelectable("2026-10-04", in: range))
        #expect(!PulseDayPicker.isSelectable("2026-10-24", in: range))
        #expect(PulseDayPicker.clamp("2026-12-01", to: range) == "2026-10-23")
        #expect(PulseDayPicker.clamp("2020-01-01", to: range) == "2026-10-05")
        let n = PulseDayPicker.normalized(lower: "2026-11-01", upper: "2026-10-01")
        #expect(n.lowerBound <= n.upperBound)
    }

    @Test func keyRoundTripAndLabels() throws {
        let c = cal()
        let date = try #require(SommeilDatePicking.pickerDate(forKey: "2026-10-23", calendar: c))
        #expect(SommeilDatePicking.key(forPickerDate: date, calendar: c) == "2026-10-23")
        #expect(PulseDayPicker.longLabel("2026-10-23") == "vendredi 23 octobre")
        #expect(PulseDayPicker.buttonLabel("2026-10-23", today: "2026-10-23") == "Aujourd'hui")
        #expect(PulseDayPicker.buttonLabel("2026-10-20", today: "2026-10-23").hasPrefix("20 oct"))
        #expect(PulseDayPicker.buttonLabel("2025-10-20", today: "2026-10-23").hasSuffix("2025"))
        #expect(PulseDayPicker.monthLabel("2026-10-01") == "Octobre 2026")
        #expect(PulseDayPicker.dayNumber("2026-10-07") == 7)
    }
}
