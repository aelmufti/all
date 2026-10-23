//
//  PulseDayPicker.swift
//  all (bridge-connect)
//
//  Sélection de jour partagée par Santé, Sommeil et Nutrition :
//  - `PulseDayPickerHeader` : titre de l'écran + bouton date « 23 oct. ▾ » +
//    bande semaine (lundi → dimanche, balayage = semaine précédente/suivante) ;
//  - `PulseDayCalendarSheet` : grille de mois maison (toucher un jour = choisir
//    et fermer ; changer de mois ne ferme pas — contrairement au `DatePicker`
//    système dont la sélection bouge avec le mois affiché).
//
//  Tout est piloté par des clés `YYYY-MM-DD`. La logique de dates est dans
//  `PulseDayPicker` (fonctions pures, testables) ; la conversion clé ↔ date
//  réutilise `SommeilDatePicking` (midi local : insensible au DST).
//

import SwiftUI

// MARK: - Logique pure

enum PulseDayPicker {
    /// Borne basse par défaut quand l'écran ne connaît pas la première donnée.
    static let defaultLowerBound = "2015-01-01"

    /// Initiales lundi → dimanche.
    static let weekdayInitials = ["L", "M", "M", "J", "V", "S", "D"]

    /// Grégorien, locale fr_FR, semaine commençant le lundi.
    static func makeCalendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "fr_FR")
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        return calendar
    }

    /// Clé décalée de `days` jours (nil si la clé est illisible).
    static func addDays(_ key: String, _ days: Int, calendar: Calendar = makeCalendar()) -> String? {
        guard let date = SommeilDatePicking.pickerDate(forKey: key, calendar: calendar),
              let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return SommeilDatePicking.key(forPickerDate: shifted, calendar: calendar)
    }

    /// Nombre de jours depuis le premier jour de semaine (0 = lundi).
    private static func weekdayOffset(of date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7
    }

    /// Lundi de la semaine contenant `key`.
    static func weekStart(containing key: String, calendar: Calendar = makeCalendar()) -> String? {
        guard let date = SommeilDatePicking.pickerDate(forKey: key, calendar: calendar) else { return nil }
        return addDays(key, -weekdayOffset(of: date, calendar: calendar), calendar: calendar)
    }

    /// Les 7 clés (lundi → dimanche) de la semaine contenant `key`.
    static func week(containing key: String, calendar: Calendar = makeCalendar()) -> [String] {
        guard let start = weekStart(containing: key, calendar: calendar) else { return [] }
        return (0..<7).compactMap { addDays(start, $0, calendar: calendar) }
    }

    /// Lundis de `lowerKey` à `upperKey` inclus (semaines affichables).
    static func weekStarts(from lowerKey: String, to upperKey: String,
                           calendar: Calendar = makeCalendar()) -> [String] {
        guard var current = weekStart(containing: lowerKey, calendar: calendar),
              let last = weekStart(containing: upperKey, calendar: calendar), current <= last else { return [] }
        var result: [String] = []
        while current <= last, result.count < 5_000 {
            result.append(current)
            guard let next = addDays(current, 7, calendar: calendar) else { break }
            current = next
        }
        return result
    }

    /// Premier jour du mois de `key` (pur texte : `YYYY-MM-01`).
    static func monthStart(of key: String) -> String? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, Int(parts[0]) != nil, Int(parts[1]) != nil else { return nil }
        return "\(parts[0])-\(parts[1])-01"
    }

    /// Premier jour du mois décalé de `months` mois.
    static func shiftMonth(_ key: String, by months: Int, calendar: Calendar = makeCalendar()) -> String? {
        guard let start = monthStart(of: key),
              let date = SommeilDatePicking.pickerDate(forKey: start, calendar: calendar),
              let shifted = calendar.date(byAdding: .month, value: months, to: date) else { return nil }
        return SommeilDatePicking.key(forPickerDate: shifted, calendar: calendar)
    }

    /// Cases du mois contenant `key` : `nil` pour le décalage avant le 1er
    /// (lundi-first), puis une clé par jour du mois.
    static func monthGrid(containing key: String, calendar: Calendar = makeCalendar()) -> [String?] {
        guard let start = monthStart(of: key),
              let first = SommeilDatePicking.pickerDate(forKey: start, calendar: calendar),
              let days = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let lead = weekdayOffset(of: first, calendar: calendar)
        let prefix = String(start.dropLast(2))
        return Array(repeating: nil, count: lead) + (1...days).map { Optional(prefix + String(format: "%02d", $0)) }
    }

    /// Jour sélectionnable : dans la plage (comparaison lexicographique des clés).
    static func isSelectable(_ key: String, in range: ClosedRange<String>) -> Bool {
        range.contains(key)
    }

    static func clamp(_ key: String, to range: ClosedRange<String>) -> String {
        min(max(key, range.lowerBound), range.upperBound)
    }

    /// Plage cohérente (borne basse ≤ borne haute).
    static func normalized(lower: String, upper: String) -> ClosedRange<String> {
        min(lower, upper)...upper
    }

    // MARK: Libellés (jour calendaire lu en UTC, comme `HealthViewModel`)

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    private static let keyFormatter: DateFormatter = {
        let f = formatter("yyyy-MM-dd")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func parseUTC(_ key: String) -> Date? { keyFormatter.date(from: key) }

    private static let longFormatter = formatter("EEEE d MMMM")
    private static let shortFormatter = formatter("d MMM")
    private static let shortYearFormatter = formatter("d MMM yyyy")
    private static let monthFormatter = formatter("LLLL yyyy")

    /// « jeudi 23 octobre » (VoiceOver).
    static func longLabel(_ key: String) -> String {
        parseUTC(key).map { longFormatter.string(from: $0) } ?? key
    }

    /// « 23 oct. » (+ année si ce n'est pas l'année d'aujourd'hui), « Aujourd'hui » pour aujourd'hui.
    static func buttonLabel(_ key: String, today: String) -> String {
        if key == today { return "Aujourd'hui" }
        guard let date = parseUTC(key) else { return key }
        let sameYear = key.prefix(4) == today.prefix(4)
        return (sameYear ? shortFormatter : shortYearFormatter).string(from: date)
    }

    /// « Octobre 2026 ».
    static func monthLabel(_ key: String) -> String {
        guard let date = parseUTC(key) else { return key }
        return monthFormatter.string(from: date).capitalized(with: Locale(identifier: "fr_FR"))
    }

    static func dayNumber(_ key: String) -> Int {
        Int(key.suffix(2)) ?? 0
    }
}

// MARK: - Cellule jour (bande + calendrier)

private struct PulseDayCell: View {
    let key: String
    let isSelected: Bool
    let isToday: Bool
    let isEnabled: Bool
    let hasData: Bool
    var weekdayInitial: String?
    let onTap: () -> Void

    @ScaledMetric(relativeTo: .body) private var circle: CGFloat = 34

    private var numberColor: Color {
        if !isEnabled { return .pulseAbsent }
        if isSelected { return .pulseBackground }
        return isToday ? .pulseAccent : .pulseTextPrimary
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                if let weekdayInitial {
                    Text(weekdayInitial)
                        .font(.caption2)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                Text("\(PulseDayPicker.dayNumber(key))")
                    .font(.body.monospacedDigit().weight(isToday && !isSelected ? .semibold : .regular))
                    .foregroundStyle(numberColor)
                    .frame(width: circle, height: circle)
                    .background {
                        if isSelected { Circle().fill(Color.pulseTextPrimary) }
                    }
                Circle()
                    .fill(hasData && isEnabled ? Color.pulseTextSecondary : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(PulseDayPicker.longLabel(key))
        .accessibilityValue(hasData ? "avec données" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Bande semaine

struct PulseDayStrip: View {
    let selected: String
    let range: ClosedRange<String>
    let daysWithData: Set<String>
    let onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var weekID: String?
    @State private var taps = 0

    /// Semaines affichables : de la plage (au plus ~2 ans avant le jour choisi,
    /// pour garder le défilement léger — le calendrier couvre le reste) à la
    /// semaine de la borne haute. Jamais de semaine entièrement future.
    private var weekStarts: [String] {
        let cal = PulseDayPicker.makeCalendar()
        let anchor = min(selected, range.upperBound)
        let windowStart = PulseDayPicker.addDays(anchor, -7 * 104, calendar: cal) ?? range.lowerBound
        return PulseDayPicker.weekStarts(
            from: max(range.lowerBound, windowStart), to: range.upperBound, calendar: cal)
    }

    private var selectedWeek: String? {
        PulseDayPicker.weekStart(containing: PulseDayPicker.clamp(selected, to: range))
    }

    var body: some View {
        let today = HealthViewModel.todayKey()
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(weekStarts, id: \.self) { start in
                    HStack(spacing: 0) {
                        ForEach(Array(PulseDayPicker.week(containing: start).enumerated()), id: \.element) { index, key in
                            PulseDayCell(
                                key: key,
                                isSelected: key == selected,
                                isToday: key == today,
                                isEnabled: PulseDayPicker.isSelectable(key, in: range),
                                hasData: daysWithData.contains(key),
                                weekdayInitial: PulseDayPicker.weekdayInitials[index]
                            ) {
                                taps += 1
                                onSelect(key)
                            }
                        }
                    }
                    .containerRelativeFrame(.horizontal)
                    .id(start)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $weekID)
        .sensoryFeedback(.selection, trigger: taps)
        .onAppear { weekID = selectedWeek }
        // Le jour choisi change (calendrier, autre écran) : la bande se recale.
        .onChange(of: selected) { recenter() }
        .onChange(of: range) { recenter() }
    }

    private func recenter() {
        guard let target = selectedWeek, weekID != target else { return }
        if reduceMotion {
            weekID = target
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { weekID = target }
        }
    }
}

// MARK: - En-tête : titre + bouton date + bande

struct PulseDayPickerHeader: View {
    let title: String
    let selected: String
    let range: ClosedRange<String>
    var daysWithData: Set<String> = []
    let onSelect: (String) -> Void

    @State private var showCalendar = false

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
            // Aligné sur la ligne de base : le titre reste à la même hauteur que sur
            // les écrans sans sélecteur ; la zone tactile de 44 pt déborde sans
            // repousser la ligne (padding puis padding négatif).
            HStack(alignment: .firstTextBaseline, spacing: PulseSpacing.md) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.pulseTextPrimary)
                Spacer()
                Button { showCalendar = true } label: {
                    HStack(spacing: 4) {
                        Text(PulseDayPicker.buttonLabel(selected, today: HealthViewModel.todayKey()))
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.pulseTextPrimary)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .padding(.vertical, -12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choisir une date")
                .accessibilityValue(PulseDayPicker.longLabel(selected))
            }
            PulseDayStrip(selected: selected, range: range, daysWithData: daysWithData, onSelect: onSelect)
        }
        .sheet(isPresented: $showCalendar) {
            PulseDayCalendarSheet(
                selected: selected, range: range, daysWithData: daysWithData, onSelect: onSelect)
        }
    }
}

// MARK: - Calendrier (feuille)

struct PulseDayCalendarSheet: View {
    let selected: String
    let range: ClosedRange<String>
    let daysWithData: Set<String>
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var month: String
    @State private var taps = 0

    init(selected: String, range: ClosedRange<String>, daysWithData: Set<String>,
         onSelect: @escaping (String) -> Void) {
        self.selected = selected
        self.range = range
        self.daysWithData = daysWithData
        self.onSelect = onSelect
        let focus = PulseDayPicker.clamp(selected, to: range)
        _month = State(initialValue: PulseDayPicker.monthStart(of: focus) ?? focus)
    }

    private var canGoBack: Bool {
        month > (PulseDayPicker.monthStart(of: range.lowerBound) ?? range.lowerBound)
    }

    private var canGoForward: Bool {
        month < (PulseDayPicker.monthStart(of: range.upperBound) ?? range.upperBound)
    }

    private func move(_ delta: Int) {
        guard delta < 0 ? canGoBack : canGoForward,
              let next = PulseDayPicker.shiftMonth(month, by: delta) else { return }
        if reduceMotion { month = next } else { withAnimation(.easeInOut(duration: 0.2)) { month = next } }
    }

    var body: some View {
        let today = HealthViewModel.todayKey()
        NavigationStack {
            VStack(spacing: PulseSpacing.md) {
                HStack {
                    Button { move(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }
                    .disabled(!canGoBack)
                    .accessibilityLabel("Mois précédent")
                    Spacer()
                    Text(PulseDayPicker.monthLabel(month))
                        .font(.headline)
                        .foregroundStyle(Color.pulseTextPrimary)
                    Spacer()
                    Button { move(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    }
                    .disabled(!canGoForward)
                    .accessibilityLabel("Mois suivant")
                }
                .foregroundStyle(Color.pulseTextPrimary)

                let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
                LazyVGrid(columns: columns, spacing: 0) {
                    ForEach(0..<7, id: \.self) { index in
                        Text(PulseDayPicker.weekdayInitials[index])
                            .font(.caption2)
                            .foregroundStyle(Color.pulseTextSecondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                }
                LazyVGrid(columns: columns, spacing: 0) {
                    ForEach(Array(PulseDayPicker.monthGrid(containing: month).enumerated()), id: \.offset) { _, key in
                        if let key {
                            PulseDayCell(
                                key: key,
                                isSelected: key == selected,
                                isToday: key == today,
                                isEnabled: PulseDayPicker.isSelectable(key, in: range),
                                hasData: daysWithData.contains(key)
                            ) {
                                taps += 1
                                onSelect(key)
                                dismiss()
                            }
                        } else {
                            Color.clear.frame(height: 44)
                        }
                    }
                }
                .id(month)
                Spacer(minLength: 0)
            }
            .padding(PulseSpacing.lg)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.pulseBackground)
            // Balayage horizontal = mois précédent/suivant (le toucher d'un jour,
            // lui, passe par les boutons des cellules).
            .gesture(
                DragGesture(minimumDistance: 30).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    move(value.translation.width < 0 ? 1 : -1)
                }
            )
            .sensoryFeedback(.selection, trigger: taps)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if PulseDayPicker.isSelectable(today, in: range) {
                        Button("Aujourd'hui") {
                            taps += 1
                            onSelect(today)
                            dismiss()
                        }
                        .tint(Color.pulseAccent)
                    }
                }
                SheetCloseButton { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Jours avec données (points du sélecteur)

/// Alimentation des points « jour avec données » : valeur en cache d'abord, puis
/// lecture fraîche. Un échec laisse l'ensemble tel quel (pas d'erreur affichée) ;
/// tant qu'aucune source n'a répondu, l'appelant garde un ensemble vide (pas de
/// points partiels).
enum PulseDaysWithData {
    @MainActor
    static func load<T: Decodable>(
        client: PulseAPIClient, path: String, query: [String: String] = [:],
        dates: ([T]) -> Set<String>, apply: @MainActor (Set<String>) -> Void
    ) async {
        if let stale: [T] = await client.cachedValue(path, query: query) {
            apply(dates(stale))
        }
        if let fresh: [T] = try? await client.getCached(path, query: query) {
            apply(dates(fresh))
        }
    }
}
