//
//  NutritionViewModel.swift
//  all (bridge-connect)
//
//  État + chargement de l'écran Nutrition. Un seul `load()` déclenche les six
//  appels de lecture en parallèle (jour, objectif, moyenne 7 j, timing,
//  suggestions, aliments fréquents) — miroir de `NutritionComponent.ngOnInit`
//  côté Angular, qui les lance aussi indépendamment. Écritures gardées
//  volontairement minimales (cf. rendu de l'agent) : suppression d'une
//  entrée, ajout rapide depuis un aliment fréquent, ajout d'une suggestion.
//

import Foundation
import Observation

@MainActor
@Observable
final class NutritionViewModel {
    enum ScreenState {
        case loading
        case loaded
        case failed(String)
    }

    private let client: PulseAPIClient

    private(set) var state: ScreenState = .loading
    var date: String

    var day: NutritionDay?
    var targetInfo: NutritionTargetInfo?
    var weekly: NutritionWeekly?
    var mealTiming: NutritionMealTiming?
    var suggestions: [NutritionSuggestionItem] = []
    var frequent: [NutritionFrequentFood] = []

    /// `true` pendant une suppression/ajout — désactive les boutons concernés
    /// pour éviter les doubles taps sans bloquer tout l'écran (pas de
    /// nouveau chargement plein écran pour une simple mutation).
    private(set) var isMutating = false

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func today() -> String {
        dayFormatter.string(from: Date())
    }

    /// `date` par défaut `nil` plutôt que `= Self.today()` : une valeur par
    /// défaut est évaluée dans un contexte synchrone non isolé même quand
    /// l'initialiseur appartient à un type `@MainActor`, donc appeler
    /// `today()` (main-actor-isolée) directement en position de défaut
    /// échoue à la compilation. On résout plutôt `nil` en "aujourd'hui" dans
    /// le corps de l'initialiseur, où l'isolation MainActor est bien acquise.
    init(client: PulseAPIClient = .shared, date: String? = nil) {
        self.client = client
        self.date = date ?? Self.today()
    }

    var isToday: Bool { date == Self.today() }

    /// Libellé long façon `dateLabel()` Angular (`"lundi 23 septembre 2026"`),
    /// en interprétant la chaîne calendaire à midi UTC pour ne jamais glisser
    /// d'un jour selon le fuseau de l'appareil.
    var dateLabel: String {
        guard let parsed = Self.dayFormatter.date(from: date) else { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter.string(from: parsed)
    }

    func shiftDay(by delta: Int) {
        guard let parsed = Self.dayFormatter.date(from: date) else { return }
        guard let shifted = Calendar(identifier: .gregorian).date(byAdding: .day, value: delta, to: parsed) else { return }
        let next = Self.dayFormatter.string(from: shifted)
        guard delta <= 0 || next <= Self.today() else { return }
        date = next
        Task { await load() }
    }

    // MARK: - Chargement

    func load() async {
        state = .loading
        do {
            async let dayResult = fetchDay()
            async let targetResult = fetchTargets()
            async let weeklyResult = fetchWeekly()
            async let timingResult = fetchTiming()
            async let suggestionsResult = fetchSuggestions()
            async let frequentResult = fetchFrequent()

            let (day, target, weekly, timing, suggestions, frequent) = try await (
                dayResult, targetResult, weeklyResult, timingResult, suggestionsResult, frequentResult
            )
            self.day = day
            self.targetInfo = target
            self.weekly = weekly
            self.mealTiming = timing.meal
            self.suggestions = suggestions.items
            self.frequent = frequent
            state = .loaded
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private func fetchDay() async throws -> NutritionDay {
        try await client.get("api/nutrition/day/\(date)")
    }

    private func fetchTargets() async throws -> NutritionTargetInfo {
        try await client.get("api/nutrition/targets", query: ["date": date])
    }

    private func fetchWeekly() async throws -> NutritionWeekly {
        try await client.get("api/nutrition/weekly", query: ["date": date])
    }

    private func fetchTiming() async throws -> NutritionTimingResponse {
        try await client.get("api/nutrition/timing/\(date)")
    }

    private func fetchSuggestions() async throws -> NutritionSuggestionsResponse {
        try await client.get("api/nutrition/suggestions/\(date)")
    }

    private func fetchFrequent() async throws -> [NutritionFrequentFood] {
        try await client.get("api/nutrition/frequent")
    }

    // MARK: - Écritures (read-only par défaut, cf. rendu de l'agent)

    /// `DELETE api/nutrition/log/:id`. Recharge uniquement la journée (les
    /// objectifs/moyenne 7 j/suggestions ne changent pas assez pour justifier
    /// un rechargement complet à chaque suppression).
    func deleteEntry(_ id: Int) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await client.delete("api/nutrition/log/\(id)")
            day = try await fetchDay()
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Ajout en un geste de la portion habituelle d'un aliment fréquent.
    /// `foodId` sert de repli au serveur si l'aliment existe encore en base ;
    /// les macros pour-100 g de `food` couvrent le cas contraire.
    func quickAdd(_ food: NutritionFrequentFood) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }

        var body = NutritionLogRequest(date: date, name: food.name)
        body.foodId = food.foodId
        body.kcal = food.kcal
        body.protein = food.protein
        body.carbs = food.carbs
        body.fiber = food.fiber
        body.fat = food.fat
        body.ts = Int(Date().timeIntervalSince1970)
        if let units = food.units, let unitGrams = food.unitGrams {
            body.units = units
            body.unitLabel = food.unitLabel
            body.unitGrams = unitGrams
        } else {
            body.grams = food.grams
        }

        do {
            let _: NutritionLogResponse = try await client.post("api/nutrition/log", body: body)
            day = try await fetchDay()
            frequent = try await fetchFrequent()
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Ajoute une suggestion telle quelle. Contrairement à `quickAdd`, on ne
    /// renvoie pas de macros dans le corps : `item.kcal`/`protein`/… sont déjà
    /// la quantité absolue pour `item.grams`, pas des valeurs pour-100 g, donc
    /// les envoyer ferait remettre le serveur à l'échelle une seconde fois
    /// (`Sync/…` — non, ici c'est `addLog` — multiplie par `grams / 100`).
    /// `foodId` suffit : le serveur relit la fiche produit pour les macros
    /// (même logique que `NutritionComponent.addSuggestion` côté Angular).
    func addSuggestion(_ item: NutritionSuggestionItem) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }

        var body = NutritionLogRequest(date: date, name: item.name)
        body.foodId = item.foodId
        if let units = item.units, let unitGrams = item.unitGrams {
            body.units = units
            body.unitLabel = item.unitLabel
            body.unitGrams = unitGrams
        } else {
            body.grams = item.grams
        }

        do {
            let _: NutritionLogResponse = try await client.post("api/nutrition/log", body: body)
            day = try await fetchDay()
            suggestions = try await fetchSuggestions().items
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        (error as? PulseAPIError)?.errorDescription ?? error.localizedDescription
    }
}
