//
//  NutritionViewModel.swift
//  all (bridge-connect)
//
//  État + chargement de l'écran Nutrition. Un seul `load()` déclenche les cinq
//  appels de lecture en parallèle (jour, objectif, moyenne 7 j, timing,
//  aliments fréquents) — miroir de `NutritionComponent.ngOnInit`
//  côté Angular, qui les lance aussi indépendamment.
//
//  Écritures : suppression d'une entrée, ajout rapide depuis un aliment
//  fréquent, et le parcours complet d'ajout d'un
//  aliment (recherche bibliothèque, recherche Open Food Facts, saisie
//  manuelle) ouvert depuis le bouton flottant « + » — miroir du sous-arbre
//  mobile de `NutritionComponent` (`sheetView`/`pending`/`addPending`…), à
//  l'exception du scan de code-barres (caméra, hors périmètre — cf. rendu de
//  l'agent) et de la modification d'une entrée déjà journalisée (`editEntry`,
//  non demandée).
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

    /// Plein écran de chargement/erreur seulement tant qu'il n'y a rien à
    /// afficher (premier chargement) : ensuite un rechargement garde le contenu.
    private(set) var state: ScreenState = .loading
    var date: String {
        didSet { weight.selectDate(date) }
    }
    /// Échec d'un rechargement ou d'une écriture alors que l'écran est déjà
    /// rempli : bandeau discret, le contenu reste (avant : tout l'écran était
    /// remplacé par l'`ErrorView`).
    private(set) var actionError: String?
    /// Vrai pendant que les données d'une AUTRE date chargent : celles de
    /// l'ancienne date sont vidées (jamais montrées sous la nouvelle date), la
    /// vue garde la structure de la page avec des emplacements réservés.
    private(set) var isDateLoading = false

    var day: NutritionDay?
    var targetInfo: NutritionTargetInfo?
    var weekly: NutritionWeekly?
    var mealTiming: NutritionMealTiming?
    var frequent: [NutritionFrequentFood] = []
    /// Carte Poids (déplacée depuis Santé) : état à part, une panne
    /// `api/weight` ne fait pas échouer l'écran.
    let weight: WeightViewModel

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

    /// « Aujourd'hui » en calendrier **local** (pas UTC) — cale sur la bascule
    /// de jour du serveur (`todayKey()` côté Nest = jour local du process, même
    /// fuseau que le téléphone) : sans ça, l'UTC retarde d'1-2 h et le jour ne
    /// change pas à minuit. La chaîne reste tz-agnostique (les formateurs
    /// d'affichage la round-trippent sans décalage).
    static func today() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `date` par défaut `nil` plutôt que `= Self.today()` : une valeur par
    /// défaut est évaluée dans un contexte synchrone non isolé même quand
    /// l'initialiseur appartient à un type `@MainActor`, donc appeler
    /// `today()` (main-actor-isolée) directement en position de défaut
    /// échoue à la compilation. On résout plutôt `nil` en "aujourd'hui" dans
    /// le corps de l'initialiseur, où l'isolation MainActor est bien acquise.
    init(client: PulseAPIClient = .shared, date: String? = nil) {
        self.client = client
        let initialDate = date ?? Self.today()
        self.date = initialDate
        self.weight = WeightViewModel(client: client, date: initialDate)
    }

    var isToday: Bool { date == Self.today() }

    /// Fusionne les rechargements (retour au premier plan, synchro, changement de
    /// source) — cf. `ReloadGate`. Le changement de date, lui, ne passe pas par
    /// la garde : il doit remplacer le chargement en cours.
    private let gate = ReloadGate()
    /// Numéro du dernier `load()` lancé : la réponse d'une date quittée
    /// entre-temps ne remplace pas la plus récente.
    private var loadGeneration = 0

    /// Dernier « aujourd'hui » connu — pour n'avancer d'un jour à minuit que si
    /// l'utilisateur était sur le jour courant (pas s'il consulte le passé).
    private var todayKeyCache = NutritionViewModel.today()

    /// Déclenché au changement de jour local (`refreshesAtDayChange`) : avance
    /// au nouveau jour si l'utilisateur était sur aujourd'hui, sinon rafraîchit
    /// s'il y est déjà — ne touche pas à une consultation de jour passé.
    func reloadForNewDay(trailing: Bool = false) async {
        let newToday = Self.today()
        let wasOnToday = date == todayKeyCache
        todayKeyCache = newToday
        if wasOnToday && date != newToday {
            date = newToday
            clearDateData()
            await load()
        } else if date == newToday {
            await reload(trailing: trailing)
        }
    }

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
        clearDateData()
        Task { await load() }
    }

    /// Tap sur une pesée de l'historique (carte Poids) : va à ce jour.
    func selectDate(_ newDate: String) {
        guard newDate != date, newDate <= Self.today() else { return }
        date = newDate
        clearDateData()
        Task { await load() }
    }

    /// Autre date : on vide ce qui dépend de la date (jamais l'ancienne date sous
    /// la nouvelle) ; les aliments fréquents, eux, n'en dépendent pas.
    private func clearDateData() {
        day = nil
        targetInfo = nil
        weekly = nil
        mealTiming = nil
        isDateLoading = true
    }

    // MARK: - Chargement

    /// Rechargement fusionné : un déclencheur pendant un rechargement en cours
    /// le rejoint au lieu de relancer les cinq requêtes. `trailing` : la donnée
    /// vient de changer (synchro, changement de source) — un seul rechargement
    /// est rejoué après le courant.
    func reload(trailing: Bool = false) async {
        await gate.run(trailing: trailing) { [self] in await self.load() }
    }

    /// Garde le contenu affiché pendant le rechargement ; un échec ne le vide
    /// pas (bandeau discret `actionError`).
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if case .loaded = state {} else { state = .loading }
        do {
            async let dayResult = fetchDay()
            async let targetResult = fetchTargets()
            async let weeklyResult = fetchWeekly()
            async let timingResult = fetchTiming()
            async let frequentResult = fetchFrequent()

            let (day, target, weekly, timing, frequent) = try await (
                dayResult, targetResult, weeklyResult, timingResult, frequentResult
            )
            guard generation == loadGeneration else { return }
            self.day = day
            self.targetInfo = target
            self.weekly = weekly
            self.mealTiming = timing.meal
            self.frequent = frequent
            state = .loaded
            actionError = nil
            isDateLoading = false
            await weight.load()
        } catch {
            guard generation == loadGeneration else { return }
            isDateLoading = false
            if case .loaded = state {
                actionError = Self.message(for: error)
            } else {
                state = .failed(Self.message(for: error))
            }
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

    private func fetchFrequent() async throws -> [NutritionFrequentFood] {
        try await client.get("api/nutrition/frequent")
    }

    // MARK: - Écritures (read-only par défaut, cf. rendu de l'agent)

    /// `DELETE api/nutrition/log/:id`. Recharge uniquement la journée (les
    /// objectifs/moyenne 7 j ne changent pas assez pour justifier
    /// un rechargement complet à chaque suppression).
    func deleteEntry(_ id: Int) async {
        guard !isMutating else { return }
        isMutating = true
        actionError = nil
        defer { isMutating = false }
        do {
            try await client.delete("api/nutrition/log/\(id)")
            day = try await fetchDay()
        } catch {
            actionError = Self.message(for: error)
        }
    }

    /// Ajout en un geste de la portion habituelle d'un aliment fréquent.
    /// `foodId` sert de repli au serveur si l'aliment existe encore en base ;
    /// les macros pour-100 g de `food` couvrent le cas contraire.
    func quickAdd(_ food: NutritionFrequentFood) async {
        guard !isMutating else { return }
        isMutating = true
        actionError = nil
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
            actionError = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        (error as? PulseAPIError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Ajout d'un aliment (feuille ouverte depuis le bouton « + »)
    //
    // Miroir du sous-arbre mobile de `NutritionComponent` (`sheetOpen`/
    // `sheetView`/`pending`…). Trois destinations dans la feuille, comme sur
    // le web : `.menu` (recherche + entrées vers scan/fréquents/manuel —
    // scan omis), `.frequent` (liste complète, cf. `freqList`), `.manual`
    // (formulaire, cf. `pendingForm`). `sheetBack` retient d'où on vient pour
    // le bouton retour, exactement comme `sheetBack` côté Angular.

    enum AddSheetView: Equatable {
        case menu
        case scan
        case frequent
        case manual
    }

    var addSheetOpen = false
    var sheetView: AddSheetView = .menu
    private(set) var sheetBack: AddSheetView = .menu

    // Recherche (menu)
    var query = ""
    private(set) var results: [NutritionFoodLite] = []
    private(set) var searchMsg: String?
    private(set) var searchSource: String = "local"
    private(set) var onlineDone = false
    private var searchTask: Task<Void, Never>?

    // Scan de code-barres (vue caméra `.scan`) — état du lookup Pulse.
    private(set) var lookupMsg: String?
    private(set) var isLookingUp = false

    // Formulaire (saisie manuelle / aliment repéré) — miroir des champs
    // `pName`/`pKcal`/…/`amount`/`pTime`/`saveToLib` (Angular).
    private var pId: Int?
    private var pBarcode: String?
    /// Id de l'entrée du journal en cours d'édition (`nil` = ajout). Miroir de
    /// `editingId` (Angular) : bascule `addPending` de `POST log` vers
    /// `PUT log/:id`, et adapte titre/bouton/retour de la feuille.
    private(set) var editingEntryId: Int?
    var pName = ""
    var pKcal: Double?
    var pProtein: Double?
    var pCarbs: Double?
    var pFiber: Double?
    var pFat: Double?
    var pUnitLabel = ""
    var pUnitGrams: Double?
    private(set) var unitMode = false
    var amount: Double? = 100
    var pTime = ""
    var saveToLib = true

    /// Ouvre la feuille sur le menu — bouton flottant « + ». Miroir de
    /// `openAdd()` (Angular).
    func openAddSheet() {
        clearSearch()
        cancelPending()
        lookupMsg = nil
        sheetView = .menu
        sheetBack = .menu
        addSheetOpen = true
    }

    func closeAddSheet() {
        addSheetOpen = false
        cancelPending()
        clearSearch()
    }

    /// Bouton retour de la feuille (sauf sur `.menu`, qui n'en a pas — miroir
    /// de `[back]="sheetView() !== 'menu'"`). Repart de `sheetBack`, comme
    /// `sheetBackStep()`.
    func sheetGoBack() {
        cancelPending()
        sheetView = sheetBack
    }

    func openFrequentList() {
        sheetBack = .menu
        sheetView = .frequent
    }

    /// Ligne « Scanner un code-barres » du menu — ouvre la vue caméra. Miroir
    /// de `openSheet('scan')` (Angular).
    func openScan() {
        lookupMsg = nil
        sheetBack = .menu
        sheetView = .scan
    }

    /// Code-barres lu par la caméra : résout le produit via Pulse
    /// (`GET api/nutrition/barcode/{code}`), pré-remplit le formulaire manuel
    /// si trouvé (avec `sheetBack = .scan` pour revenir au scanner), sinon
    /// affiche un message. Miroir de `onBarcode()` (Angular). Réseau autorisé
    /// explicitement (même serveur Pulse que la recherche en ligne).
    func lookupBarcode(_ code: String) async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // Le serveur n'accepte qu'un EAN/UPC de 6 à 14 chiffres — filtrage
        // client pour ignorer une lecture parasite sans provoquer un 400.
        guard trimmed.range(of: "^[0-9]{6,14}$", options: .regularExpression) != nil else { return }
        // Anti-rebond : la caméra rappelle en rafale le même code.
        guard !isLookingUp, sheetView == .scan else { return }
        isLookingUp = true
        lookupMsg = "Recherche du code-barres…"
        defer { isLookingUp = false }
        do {
            let result: NutritionBarcodeResult = try await client.get("api/nutrition/barcode/\(trimmed)")
            guard sheetView == .scan else { return } // l'utilisateur a quitté entre-temps
            if result.found, let food = result.food {
                setPending(food)
                sheetBack = .scan
                sheetView = .manual
                lookupMsg = nil
            } else {
                lookupMsg = "Code-barres inconnu — saisis l'aliment à la main."
            }
        } catch {
            lookupMsg = "Erreur de recherche du code-barres."
        }
    }

    /// Ligne « Saisie manuelle » du menu — formulaire vierge. Miroir de
    /// `openManual()` (Angular ; le retour se fait toujours vers `.menu` ici,
    /// `.scan` n'existant pas dans cette reprise).
    func openManual() {
        setPending(NutritionFoodLite(
            id: nil, barcode: nil, name: "", kcal: nil, protein: nil,
            carbs: nil, fiber: nil, fat: nil, unitLabel: nil, unitGrams: nil
        ))
        sheetBack = .menu
        sheetView = .manual
    }

    /// Ouvre le formulaire pré-rempli sur une entrée déjà journalisée pour la
    /// modifier (`PUT log/:id` à l'enregistrement). Miroir de `editEntry()`
    /// (Angular) : les macros stockées sont absolues (valeurs de la portion) ;
    /// on les reconvertit en /100 g pour le formulaire (valeur / grammes × 100).
    func editEntry(_ entry: NutritionEntry) {
        func per100(_ value: Double?) -> Double? {
            guard let value, entry.grams > 0 else { return value }
            return (value / entry.grams * 100 * 10).rounded() / 10
        }
        pId = nil
        pBarcode = nil
        pName = entry.name
        pKcal = per100(entry.kcal)
        pProtein = per100(entry.protein)
        pCarbs = per100(entry.carbs)
        pFiber = per100(entry.fiber)
        pFat = per100(entry.fat)
        pUnitLabel = entry.unitLabel ?? ""
        if let units = entry.unitQty, units > 0, entry.unitLabel?.isEmpty == false {
            pUnitGrams = (entry.grams / units * 10).rounded() / 10
            unitMode = true
            amount = units
        } else {
            pUnitGrams = nil
            unitMode = false
            amount = entry.grams
        }
        pTime = Self.hm(from: entry.ts)
        saveToLib = false
        editingEntryId = entry.id
        sheetBack = .menu
        sheetView = .manual
        addSheetOpen = true
    }

    // MARK: Recherche

    func clearSearch() {
        searchTask?.cancel()
        query = ""
        results = []
        searchMsg = nil
        searchSource = "local"
        onlineDone = false
    }

    /// Appelé à chaque frappe (le débounce 250 ms vit ici, pas dans la vue) —
    /// miroir de `onQueryInput()` (Angular).
    func onQueryChanged() {
        searchTask?.cancel()
        searchSource = "local"
        onlineDone = false
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            searchMsg = nil
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.searchLocal()
        }
    }

    /// `GET api/nutrition/foods?q=` — bibliothèque locale. Silencieux en cas
    /// d'échec réseau (comme le web, qui ne pose pas de `catch` ici).
    private func searchLocal() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        searchMsg = nil
        guard let res: [NutritionFoodLite] = try? await client.get("api/nutrition/foods", query: ["q": q]) else { return }
        guard !Task.isCancelled else { return }
        results = res
        searchSource = "local"
        searchMsg = res.isEmpty ? "Rien dans ta bibliothèque pour ce mot." : nil
    }

    /// `GET api/nutrition/search?q=` — Open Food Facts, déclenché par le
    /// bouton/la ligne « … en ligne ». Miroir de `searchOnline()` (Angular).
    func searchOnline() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        searchTask?.cancel()
        onlineDone = true
        searchMsg = "Recherche en ligne…"
        do {
            let res: [NutritionFoodLite] = try await client.get("api/nutrition/search", query: ["q": q])
            if res.isEmpty {
                searchMsg = "Aucun résultat en ligne — vérifie l'orthographe ou saisis à la main."
            } else {
                results = res
                searchSource = "online"
                searchMsg = nil
            }
        } catch {
            searchMsg = "Erreur de recherche en ligne."
        }
    }

    /// Résultat de recherche (local ou en ligne) choisi — bascule directement
    /// sur le formulaire, portion pré-remplie. Miroir de `pick()`.
    func pick(_ food: NutritionFoodLite) {
        setPending(food)
        results = []
        query = ""
        searchSource = "local"
        searchMsg = nil
        sheetBack = .menu
        sheetView = .manual
    }

    // MARK: Aliments fréquents (dans la feuille)

    /// Touche le nom d'un aliment fréquent : ouvre le formulaire pré-rempli
    /// (quantité/heure modifiables) plutôt que de journaliser tel quel.
    /// Miroir de `openFrequent()`.
    func openFrequentItem(_ food: NutritionFrequentFood) {
        setPending(NutritionFoodLite(
            id: food.foodId, barcode: nil, name: food.name,
            kcal: food.kcal, protein: food.protein, carbs: food.carbs,
            fiber: food.fiber, fat: food.fat,
            unitLabel: food.unitLabel, unitGrams: food.unitGrams
        ))
        if let units = food.units, food.unitGrams != nil {
            unitMode = true
            amount = units
        } else {
            unitMode = false
            amount = food.grams
        }
        sheetBack = .frequent
        sheetView = .manual
    }

    /// Touche le « + » d'un aliment fréquent dans la feuille : journalise la
    /// portion habituelle sans passer par le formulaire, puis referme la
    /// feuille. Miroir de `addFrequent()` (réutilise `quickAdd`, déjà
    /// équivalent à `logFrequent`).
    func addFrequentFromSheet(_ food: NutritionFrequentFood) async {
        await quickAdd(food)
        addSheetOpen = false
    }

    // MARK: Formulaire (saisie manuelle)

    private func setPending(_ food: NutritionFoodLite) {
        editingEntryId = nil
        pId = food.id
        pBarcode = food.barcode
        pName = food.name
        pKcal = food.kcal
        pProtein = food.protein
        pCarbs = food.carbs
        pFiber = food.fiber
        pFat = food.fat
        pUnitLabel = food.unitLabel ?? ""
        pUnitGrams = food.unitGrams
        unitMode = food.unitGrams != nil
        amount = food.unitGrams != nil ? 1 : 100
        pTime = Self.nowHM()
        saveToLib = true
    }

    /// Bascule quantité en grammes ↔ en objets (case « pièce »/« tranche »…).
    /// Miroir de `toggleUnit()`.
    func toggleUnit() {
        guard let unitGrams = pUnitGrams, unitGrams > 0 else { return }
        let next = !unitMode
        let value = amount ?? 0
        amount = next
            ? max((value / unitGrams * 10).rounded() / 10, 0.1)
            : (value * unitGrams).rounded()
        unitMode = next
    }

    /// Grammes réellement journalisés pour la quantité saisie. Miroir de
    /// `resolvedGrams()`.
    func resolvedGrams() -> Double {
        let value = amount ?? 0
        if unitMode, let unitGrams = pUnitGrams {
            return (value * unitGrams * 10).rounded() / 10
        }
        return value
    }

    /// Libellé du bouton d'unité (« g » ou le nom pluralisé de l'objet).
    /// Miroir de `amountUnit()`.
    func amountUnitText() -> String {
        if unitMode, pUnitGrams != nil {
            return Self.pluralize(Self.unitName(pUnitLabel), amount ?? 0)
        }
        return "g"
    }

    /// Texte d'aide sous le champ quantité. Miroir de `amountHint()`.
    func amountHintText() -> String {
        guard let unitGrams = pUnitGrams, unitGrams > 0 else {
            return "Renseigne un objet et son poids pour compter en pièces."
        }
        if unitMode {
            return "= \(Self.fr(resolvedGrams())) g"
        }
        return "1 \(Self.unitName(pUnitLabel)) = \(Self.fr(unitGrams)) g"
    }

    func cancelPending() {
        editingEntryId = nil
        pId = nil
        pBarcode = nil
        pName = ""
        pKcal = nil
        pProtein = nil
        pCarbs = nil
        pFiber = nil
        pFat = nil
        pUnitLabel = ""
        pUnitGrams = nil
        unitMode = false
        amount = 100
        pTime = ""
        saveToLib = true
    }

    /// Bouton « Annuler » du formulaire — revient à l'étape précédente
    /// (menu ou liste des fréquents), sans fermer la feuille. Miroir de
    /// `dismissPending()` côté mobile (la branche desktop ne s'applique pas
    /// ici, cet écran n'a qu'une mise en page).
    func dismissPending() {
        sheetGoBack()
    }

    /// `POST api/nutrition/log` (+ `POST`/`PUT api/nutrition/foods` si
    /// « Enregistrer dans ma bibliothèque » est cochée). Miroir de
    /// `addPending()`, restreint au cas « ajout » (`editingId == null` côté
    /// Angular) — la modification d'une entrée déjà journalisée n'est pas
    /// reprise ici, cf. en-tête du fichier.
    func addPending() async {
        guard let amount, amount > 0, !pName.isEmpty, !isMutating else { return }
        isMutating = true
        defer { isMutating = false }

        let unitLabelForRequest = pUnitGrams != nil ? Self.unitName(pUnitLabel) : nil
        do {
            // En édition d'une entrée du journal, on ne (re)crée pas d'aliment
            // en bibliothèque : on met seulement à jour la ligne journalisée.
            if saveToLib, editingEntryId == nil {
                let foodBody = NutritionFoodCreateRequest(
                    name: pName, barcode: pBarcode,
                    kcal: pKcal, protein: pProtein, carbs: pCarbs, fiber: pFiber, fat: pFat,
                    unitLabel: unitLabelForRequest, unitGrams: pUnitGrams
                )
                if let pId {
                    let _: NutritionFoodLite = try await client.put("api/nutrition/foods/\(pId)", body: foodBody)
                } else {
                    let _: NutritionFoodLite = try await client.post("api/nutrition/foods", body: foodBody)
                }
            }

            var logBody = NutritionLogRequest(date: date, name: pName)
            logBody.kcal = pKcal
            logBody.protein = pProtein
            logBody.carbs = pCarbs
            logBody.fiber = pFiber
            logBody.fat = pFat
            logBody.ts = pendingTimestamp()
            if unitMode, let unitGrams = pUnitGrams {
                logBody.units = amount
                logBody.unitLabel = unitLabelForRequest
                logBody.unitGrams = unitGrams
            } else {
                logBody.grams = amount
            }
            if let editId = editingEntryId {
                let _: NutritionOkResponse = try await client.put("api/nutrition/log/\(editId)", body: logBody)
            } else {
                let _: NutritionLogResponse = try await client.post("api/nutrition/log", body: logBody)
            }

            cancelPending()
            clearSearch()
            addSheetOpen = false
            sheetView = .menu
            day = try await fetchDay()
            frequent = try await fetchFrequent()
        } catch {
            actionError = Self.message(for: error)
        }
    }

    /// `${date}T${pTime}:00` interprété en heure locale, comme
    /// `Date.parse` côté Angular (une chaîne datetime sans fuseau explicite
    /// est résolue dans le fuseau courant). Repli sur l'instant présent si
    /// l'heure n'a pas été saisie.
    private func pendingTimestamp() -> Int {
        guard !pTime.isEmpty else { return Int(Date().timeIntervalSince1970) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let parsed = formatter.date(from: "\(date) \(pTime)") else {
            return Int(Date().timeIntervalSince1970)
        }
        return Int(parsed.timeIntervalSince1970)
    }

    private static func nowHM() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }

    /// « HH:mm » local d'un epoch (heure d'une entrée éditée) — `nowHM()` si nil.
    private static func hm(from ts: Int?) -> String {
        guard let ts else { return nowHM() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private static func unitName(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "unité" : trimmed
    }

    /// Pluriel naïf façon `plural()` (Angular) : rien si la quantité est
    /// ≤ 1, si le libellé contient un espace, ou s'il finit déjà par s/x/z.
    private static func pluralize(_ label: String, _ qty: Double) -> String {
        if qty <= 1 || label.contains(" ") { return label }
        if let last = label.lowercased().last, "sxz".contains(last) { return label }
        return label + "s"
    }

    private static func fr(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }
}

/// Réponse minimale `{ ok }` de `PUT api/nutrition/log/:id`.
struct NutritionOkResponse: Decodable {
    let ok: Bool?
}
