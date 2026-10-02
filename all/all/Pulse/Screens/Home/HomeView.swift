//
//  HomeView.swift
//  all (bridge-connect)
//
//  Écran Accueil — port 1-1 de `custom-connect/web/src/app/pages/home/home.component.ts`
//  au gabarit **mobile** (<900px, celui qui s'applique réellement à ce
//  téléphone) : FC « Maintenant » (+ mini-graphe + vitaux), entraînement de
//  la semaine + intensité, séance du jour/à venir, « Depuis le réveil »
//  (pas/calories) et « Nuit dernière » (durée, hypnogramme, régularité du
//  coucher). Trois états : chargement (`LoadingView`), erreur (`ErrorView`),
//  données.
//
//  Fidélité structurelle : au gabarit mobile, le web n'enferme PAS chaque
//  section dans une carte à coins arrondis (`section{background:var(--surface);
//  border:1px solid var(--border);border-radius:16px}` n'existe qu'à partir de
//  `@media (min-width:900px)`) — les sections s'enchaînent à plat, séparées
//  par un simple filet (`border-top:1px solid var(--line)`), avec juste
//  « Depuis le réveil » sur fond `--surface`. D'où l'absence de `PulseCard`
//  ci-dessous : chaque section gère son propre padding/filet, pas de carte.
//
//  Couleurs par métrique (cf. `DesignSystem.swift`) : chaque donnée reprend
//  la teinte de sa métrique (FC → `.pulseHR`, sommeil → `.pulseSleep`/phases
//  `.pulseSleep*`) — mais SEULEMENT là où le CSS Angular l'indique
//  explicitly. Vérification faite bloc par bloc : les vitaux « Maintenant »
//  (stress/oxygène/respiration), les valeurs « Depuis le réveil » et la durée/
//  l'horaire « Nuit dernière » n'ont PAS de couleur de métrique dans
//  `home.component.ts` (`.vital-val`, `.metric-val`, `.night-dur`, `.reg-clock`
//  héritent tous de `--text`, sans règle de couleur dédiée) — contrairement à
//  la maquette statique (`Pulse Refonte.dc.html`) qui, pour « Depuis le
//  réveil », dessine des barres horizontales teintées par métrique (widget
//  différent de celui réellement livré par le composant Angular, jauge
//  verticale + point). Écart maquette/Angular tranché en faveur d'Angular
//  (source de structure/fonctionnalités selon la consigne) ; la maquette n'a
//  servi qu'aux tailles/espacements/couleurs qui, elles, concordent.
//
//  `DesignSystem.swift` n'expose pas de jeton séparé pour `--line` (utilisé
//  par les filets `border-top` de section) : `pulseBorder` (`--border`) est
//  réutilisé, le plus proche disponible — pas de hex inventé.
//
//  À brancher dans `PulseShellView`, case `.accueil`, à la place de
//  `ComingSoonView(title: "Accueil", …)` — pas de dépendance de navigation
//  externe : l'écran gère sa propre `NavigationStack`. Divergences assumées
//  vs le web (aucune API de navigation inter-onglets exposée à cet écran) :
//  les liens `routerLink="/programme"` (« Voir le programme », bande
//  « Coucher moyen ») ne sont pas portés. De même, au gabarit mobile, Angular
//  masque déjà lui-même le focus de séance, la liste d'exercices et le lien
//  « Voir le programme » (`.session-focus/.items/.session-more{display:none}`,
//  visibles seulement ≥900px) : la carte séance ne montre donc que titre/
//  horaire, nom/durée, méta et le badge « fait », comme le web mobile.
//
//  FC en direct : `HomeLiveHeartRate` n'expose pas la machine à états
//  `phase` (starting/waiting/measuring/lost) du `LiveHrService` Angular, ni
//  son second signal `note()` distinct de `hint()`. `liveStateLabel`
//  ci-dessous approxime `liveLabel()` à partir des champs disponibles
//  (`enabled/reachable/heartRate/stale`) ; le lien « état du lien » (phase
//  "lost") n'est pas porté (pas d'API de navigation, cf. ci-dessus) ; un seul
//  `live.hint` est affiché (position de `.direct-hint`), au lieu des deux
//  signaux distincts du web.
//

import SwiftUI

struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    /// Paramètres (roue crantée) — hors barre d'onglets, regroupe le
    /// secondaire iPhone (Apparence, Synchro, Profil, Statut, Montre, Compte).
    @State private var showSystemMenu = false

    var body: some View {
        NavigationStack {
            content
                .background(Color.pulseBackground)
                // En-tête porté en contenu (titre 24pt + thème + roue, cf.
                // `homeHeader`) comme les autres écrans : barre système masquée
                // pour un cadrage uniforme (fini le grand titre et son vide).
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showSystemMenu) {
                    SettingsView()
                }
        }
        .task { await viewModel.load() }
        .task {
            // FC en direct : rafraîchissement périodique tant que l'écran est
            // visible — annulé automatiquement par SwiftUI à sa disparition.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await viewModel.refreshLive()
            }
        }
        // Bascule de jour : à minuit local et au retour premier plan, recharge
        // « aujourd'hui » (l'Accueil est toujours sur le jour courant).
        .refreshesAtDayChange { await viewModel.load() }
        // Synchro montre en mode Téléphone/Les deux pendant que l'écran est
        // ouvert (cf. `LocalIngestor.ingestIfNeeded`) : mêmes données que
        // `.refreshesAtDayChange`, mais déclenché par l'arrivée réelle d'un
        // nouveau fichier plutôt que par le calendrier.
        .reloadsOnLocalDataChange { await viewModel.load() }
        .reloadsOnStorageModeChange { await viewModel.load() }
    }

    /// En-tête en contenu : titre « Accueil » 24pt + roue crantée (Paramètres).
    private var homeHeader: some View {
        HStack(spacing: PulseSpacing.lg) {
            Text("Accueil")
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(Color.pulseTextPrimary)
            Spacer()
            Button {
                showSystemMenu = true
            } label: {
                Image(systemName: "gearshape")
            }
            .tint(Color.pulseTextPrimary)
            .accessibilityLabel("Paramètres")
        }
        .padding(.horizontal, PulseSpacing.lg)
        .padding(.top, PulseSpacing.lg)
        .padding(.bottom, PulseSpacing.md)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingView(message: "Chargement de l'accueil…")
        case .failed(let message):
            ErrorView(message: message) {
                Task { await viewModel.load() }
            }
        case .loaded:
            ScrollView {
                VStack(spacing: 0) {
                    homeHeader
                    NowSection(viewModel: viewModel)
                    WeekTrainingSection(viewModel: viewModel)
                    if let session = viewModel.session {
                        SessionSection(session: session)
                    }
                    WakeSection(viewModel: viewModel)
                    NightSection(viewModel: viewModel)
                }
                // SCSS `:host{padding-bottom:16px}` — marge basse de toute la page.
                .padding(.bottom, 16)
            }
            .pulseTabBarClearance()
            .background(Color.pulseBackground)
        }
    }
}

// MARK: - Filet de séparation entre sections (`border-top:1px solid var(--line)`)

private extension View {
    func homeTopDivider() -> some View {
        overlay(alignment: .top) {
            Rectangle().fill(Color.pulseBorder).frame(height: 1)
        }
    }
}

// MARK: - Étiquette de section (`.lab` — PAS `SectionHeader`/`PulseFont.sectionTitle`,
// réservé aux titres de carte d'autres écrans : l'Accueil web n'a pas de gros
// titres de section, seulement ces petites étiquettes discrètes mono/majuscules).

private struct HomeLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, design: .rounded))
            // `.12em` de 10px ≈ 1.2pt.
            .tracking(1.2)
            .foregroundStyle(Color.pulseTextSecondary)
    }
}

// MARK: - Pastille « périmé » (`.stale-pill`)

private struct StalePill: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.pulseStress).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color.pulseTextPrimary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Color.pulseSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.pulseBorder, lineWidth: 1))
    }
}

// MARK: - Filet pointillé (`.f-lead`, jauge de séparation nom/valeur des « facts »)

private struct DotLeader: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
            }
            .stroke(Color.pulseBorder, style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        }
        .frame(minWidth: 10, maxWidth: .infinity)
        .frame(height: 1)
    }
}

// MARK: - Formatage nombre groupé (`| number:'1.0-0'`, ex. « 8 420 »)

private enum HomeNumberFormat {
    /// Espace fine insécable comme le `DecimalPipe` Angular (locale fr).
    static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = "\u{202F}"
        formatter.groupingSize = 3
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: "fr_FR")
        return formatter
    }()

    static func grouped(_ value: Double) -> String {
        integerFormatter.string(from: NSNumber(value: value.rounded()))
            ?? String(Int(value.rounded()))
    }
}

// MARK: - « Maintenant » (FC + entraînement direct + vitaux)

private struct NowSection: View {
    let viewModel: HomeViewModel
    /// Valeur survolée sur le mini-graphe (bpm) — écrase `shownHr` tant que le
    /// doigt reste sur la courbe, cf. `HeartRateSparkline`.
    @State private var hover: Int?

    var body: some View {
        // SCSS `.now { padding:26px 22px 24px; gap:22px; }`.
        VStack(alignment: .leading, spacing: 22) {
            header

            // `.pulse` : colonne bpm+sous-titre à gauche, mini-graphe à
            // droite, alignés sur la ligne de base basse (`align-items:flex-end`).
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    bpmRow
                    Text(nowSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                HeartRateSparkline(
                    samples: viewModel.hrSparkline,
                    stale: viewModel.staleLabel != nil && !viewModel.isLiveNow,
                    hover: $hover
                )
                .frame(maxWidth: .infinity)
            }

            // `.now-head`/`.direct` : `margin-top:-8px` sur un `gap:22px` ⇒
            // écart net ≈14px.
            liveControl
                .padding(.top, -8)

            if let hint = viewModel.live?.hint {
                // `.direct-hint { margin:-10px 0 0; font-size:12px; line-height:1.5; }`.
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.pulseTextSecondary)
                    .padding(.top, -10)
            }

            vitals
        }
        .padding(.top, 26)
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
    }

    /// Miroir de `.head` (h1 + pastille périmé) — le gear `routerLink="/parametres"`
    /// est déjà porté par la roue crantée de la barre d'outils native
    /// (`SystemMenuView`), pas dupliqué ici.
    private var header: some View {
        HStack {
            Text(viewModel.staleLabel == nil ? "Maintenant" : "Dernier relevé")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.pulseTextPrimary)
            Spacer()
            if let staleLabel = viewModel.staleLabel {
                StalePill(label: staleLabel)
            }
        }
    }

    private var bpmRow: some View {
        HStack(spacing: 11) {
            // `hover` (survol du mini-graphe) prime sur `shownHr` tant que le
            // doigt est posé sur la courbe — revient à `shownHr` au relâcher.
            Text(hover.map(String.init) ?? (viewModel.shownHr.map(String.init) ?? "—"))
                .font(.system(size: 60, weight: .semibold, design: .rounded))
                .foregroundStyle(bpmColor)
                .contentTransition(.numericText())
                // Largeur réservée pour 3 chiffres (mono 60pt ≈ 36pt/chiffre) :
                // sans ça, un passage 2→3 chiffres de la FC en direct élargit
                // cette colonne, rétrécit le mini-graphe voisin et le fait
                // « bouger » sous le doigt pendant le survol.
                .frame(minWidth: 108, alignment: .leading)
            if isLiveBeating {
                Image(systemName: "heart.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.pulseHR)
                    .symbolEffect(.pulse, options: .repeating)
                    .accessibilityLabel("En direct")
            }
        }
    }

    private var isLiveBeating: Bool {
        viewModel.live?.heartRate != nil && viewModel.live?.enabled == true
            && viewModel.live?.reachable == true
    }

    /// `.bpm.empty{color:--absent}` / `.bpm.stale{color:--text-dim}` — au
    /// gabarit web les deux classes ont même spécificité, `.stale` déclarée
    /// après l'emporte quand elle s'applique : un jour périmé prime toujours
    /// sur « valeur absente ».
    private var bpmColor: Color {
        if viewModel.staleLabel != nil { return .pulseTextSecondary }
        if viewModel.shownHr == nil { return .pulseAbsent }
        return .pulseHR
    }

    private var nowSubtitle: String {
        var parts: [String] = []
        if let live = viewModel.live, live.heartRate != nil, live.enabled, live.reachable, !live.stale {
            parts.append("en direct")
        } else if viewModel.staleLabel != nil, let date = viewModel.day?.date {
            parts.append("dernier relevé le \(HomeViewModel.shortDate(date))")
        } else if viewModel.live?.enabled == true {
            parts.append("dernier relevé enregistré")
        } else {
            parts.append("battements par minute")
        }
        if let rest = viewModel.restingHr {
            parts.append("repos \(rest)")
        }
        return parts.joined(separator: " · ")
    }

    /// `.direct` : bouton fantôme (pilule, pas l'accent bleu) + état en
    /// direct — `liveStateLabel` approxime `liveLabel()` (cf. en-tête du
    /// fichier, `HomeLiveHeartRate` n'a pas de champ `phase`).
    @ViewBuilder
    private var liveControl: some View {
        HStack(spacing: PulseSpacing.md) {
            Button {
                Task {
                    if viewModel.live?.enabled == true {
                        await viewModel.stopLive()
                    } else {
                        await viewModel.startLive()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if viewModel.live?.enabled != true {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.pulseHR)
                    }
                    Text(viewModel.live?.enabled == true ? "Arrêter" : "Reprendre la mesure")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.pulseTextSecondary)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .overlay(Capsule().strokeBorder(Color.pulseBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)

            if let label = liveStateLabel {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }

    private var liveStateLabel: String? {
        guard let live = viewModel.live, live.enabled else { return nil }
        if live.heartRate != nil, live.reachable, !live.stale { return "Mesure en direct" }
        if !live.reachable { return "En attente de la montre…" }
        return "Mesure interrompue"
    }

    /// `.vitals` : stress/oxygène/respiration, jamais teintés par métrique
    /// ici (`.vital-val` hérite de `--text`, cf. en-tête du fichier) +
    /// « il y a N min » poussé à droite (`margin-left:auto`).
    private var vitals: some View {
        HStack(alignment: .bottom, spacing: 20) {
            ForEach(viewModel.vitals) { vital in
                VStack(alignment: .leading, spacing: 3) {
                    Text(vital.label)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.pulseTextSecondary)
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        Text(vital.value.map(String.init) ?? "—")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(vitalValueColor)
                        if vital.value != nil, !vital.unit.isEmpty {
                            Text(" \(vital.unit)")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                    }
                }
            }
            if viewModel.staleLabel == nil, let ago = viewModel.lastReadingLabel {
                Spacer(minLength: 0)
                Text(ago)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }

    private var vitalValueColor: Color {
        viewModel.staleLabel == nil ? .pulseTextPrimary : .pulseTextSecondary
    }
}

/// Mini-graphe FC des 60 derniers relevés du jour — port du `spark()` SVG
/// côté Angular (ligne + aire teintées `.pulseHR`, estompées si périmé,
/// jamais l'accent bleu générique : c'est une donnée FC).
private struct HeartRateSparkline: View {
    let samples: [HomeSample]
    let stale: Bool
    /// bpm survolé, remonté à `NowSection` pour écraser `shownHr` en direct.
    @Binding var hover: Int?

    /// Index (dans `points`) du dernier point touché — sert uniquement au
    /// dessin du marqueur local, `hover` porte la valeur vers l'appelant.
    @State private var selectedIndex: Int?

    private var points: [HomeSample] { Array(samples.suffix(60)) }

    var body: some View {
        if points.count < 2 {
            EmptyView()
        } else {
            let color: Color = stale ? .pulseTextSecondary : .pulseHR
            GeometryReader { geo in
                let values = points.map(\.value)
                let minValue = values.min() ?? 0
                let span = max((values.max() ?? 0) - minValue, 1)
                let coords = points.enumerated().map { index, sample -> CGPoint in
                    CGPoint(
                        x: geo.size.width * CGFloat(index) / CGFloat(points.count - 1),
                        y: geo.size.height - CGFloat((sample.value - minValue) / span) * geo.size.height)
                }

                ZStack {
                    Path { path in
                        guard let first = coords.first, let last = coords.last else { return }
                        path.move(to: CGPoint(x: first.x, y: geo.size.height))
                        for point in coords { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.1))

                    Path { path in
                        guard let first = coords.first else { return }
                        path.move(to: first)
                        for point in coords.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    if let last = coords.last {
                        Circle().fill(color).frame(width: 7, height: 7).position(last)
                    }

                    // Marqueur de survol : trait vertical + point plein sur
                    // l'échantillon touché (miroir du `RuleMark`/`PointMark`
                    // de `SampleLineChart`, en dessiné-main ici).
                    if let selectedIndex, coords.indices.contains(selectedIndex) {
                        let point = coords[selectedIndex]
                        Path { path in
                            path.move(to: CGPoint(x: point.x, y: 0))
                            path.addLine(to: CGPoint(x: point.x, y: geo.size.height))
                        }
                        .stroke(Color.pulseTextSecondary.opacity(0.4), lineWidth: 1)
                        Circle().fill(color).frame(width: 9, height: 9).position(point)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(1, value.location.x / max(geo.size.width, 1)))
                            let index = Int((fraction * CGFloat(points.count - 1)).rounded())
                            let clamped = max(0, min(points.count - 1, index))
                            selectedIndex = clamped
                            hover = Int(points[clamped].value.rounded())
                        }
                        .onEnded { _ in
                            selectedIndex = nil
                            hover = nil
                        }
                )
            }
            .frame(height: 48)
            .opacity(stale ? 0.45 : 1)
        }
    }
}

// MARK: - Entraînement de la semaine (+ intensité)

private struct WeekTrainingSection: View {
    let viewModel: HomeViewModel

    private static let dayLetters = ["L", "M", "M", "J", "V", "S", "D"]

    var body: some View {
        // SCSS `.week { border-top:1px solid var(--line); padding:16px 22px; gap:18px; }`.
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                HomeLabel(text: "Entraînement de la semaine")
                Spacer()
                Text(viewModel.weekRangeLabel)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            let lead = viewModel.weekLead
            VStack(alignment: .leading, spacing: 7) {
                HomeLabel(text: lead.label)
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text(lead.value)
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pulseTextPrimary)
                        // `letter-spacing:.01em` de 42px ≈ 0.42pt.
                        .tracking(0.42)
                    Text(lead.sub)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }

            plot

            facts
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 22)
        .homeTopDivider()
    }

    private var plot: some View {
        VStack(spacing: 9) {
            WeekProgressChart(training: viewModel.trainingShare, intensity: viewModel.intensityShare)

            HStack(spacing: 0) {
                ForEach(Self.dayLetters.indices, id: \.self) { index in
                    let today = index == todayIndex
                    Text(Self.dayLetters[index])
                        .font(.system(size: 10, weight: today ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(today ? Color.pulseTextPrimary : Color.pulseTextSecondary)
                        .frame(maxWidth: .infinity)
                }
            }

            if !viewModel.intensityShare.isEmpty {
                HStack(spacing: 16) {
                    if !viewModel.trainingShare.isEmpty {
                        WeekChartLegend(color: .pulseTextPrimary, label: "Séances", dashed: false)
                    }
                    WeekChartLegend(color: .pulseHR, label: "Intensité", dashed: true)
                }
            }
        }
    }

    /// Miroir de `weekIndex()` (VM, privé) recalculé ici à partir des
    /// utilitaires publics (`parseDateKey`/`startOfWeek`) — pas d'accès à la
    /// propriété privée de la VM, celle-ci reste figée (cf. périmètre).
    private var todayIndex: Int? {
        guard let dateString = viewModel.day?.date,
            let refDate = HomeViewModel.parseDateKey(dateString)
        else { return nil }
        let monday = HomeViewModel.startOfWeek(refDate)
        let days =
            Calendar.current.dateComponents(
                [.day], from: monday, to: Calendar.current.startOfDay(for: refDate)
            ).day ?? 0
        return max(0, min(6, days))
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(viewModel.weekFacts) { fact in
                HStack(spacing: 8) {
                    Text(fact.name)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.pulseTextPrimary)
                        .lineLimit(1)
                    DotLeader()
                    Text(fact.value)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(Color.pulseTextPrimary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.top, 15)
        .homeTopDivider()
    }
}

/// Mini-graphe de progression hebdomadaire — port du SVG `weekCurve()` côté
/// Angular : trait plein (entraînement) + aire, pointillé oblique
/// (« rythme régulier »), ligne d'objectif horizontale + point creux à
/// l'objectif, pointillé FC (intensité) + point plein. La boîte (hauteur +
/// filet bas) reste affichée même sans donnée, comme `.chart` côté web.
private struct WeekProgressChart: View {
    let training: [Double]
    let intensity: [Double]

    private static let headroom = 0.9

    private var hasGoal: Bool { !training.isEmpty || !intensity.isEmpty }

    private var top: Double {
        let highest = max(1, training.max() ?? 0, intensity.max() ?? 0)
        return highest / Self.headroom
    }

    private var goalFraction: Double { 1 - 1 / top }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let goalY = size.height * CGFloat(goalFraction)

            ZStack(alignment: .topLeading) {
                if hasGoal {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: goalY))
                        path.addLine(to: CGPoint(x: size.width, y: goalY))
                    }
                    .stroke(
                        Color.pulseTextPrimary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))

                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height))
                        path.addLine(to: CGPoint(x: size.width, y: goalY))
                    }
                    .stroke(
                        Color.pulseTextPrimary.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }

                if !training.isEmpty {
                    area(training, size: size).fill(Color.pulseTextPrimary.opacity(0.08))
                    line(training, size: size)
                        .stroke(
                            Color.pulseTextPrimary,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                if !intensity.isEmpty {
                    line(intensity, size: size)
                        .stroke(
                            Color.pulseHR,
                            style: StrokeStyle(
                                lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [6, 4]))
                }

                if let point = endPoint(training, size: size) {
                    Circle().fill(Color.pulseTextPrimary).frame(width: 9, height: 9).position(point)
                }
                if let point = endPoint(intensity, size: size) {
                    Circle().fill(Color.pulseHR).frame(width: 9, height: 9).position(point)
                }
                if hasGoal {
                    Circle()
                        .fill(Color.pulseBackground)
                        .overlay(Circle().strokeBorder(Color.pulseTextPrimary.opacity(0.5), lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .position(x: size.width, y: goalY)
                }
            }
        }
        .frame(height: 104)
        // SCSS `.chart { border-bottom:1px solid var(--border); }` — filet BAS
        // uniquement (pas de filet haut ici, `homeTopDivider()` ne s'applique
        // qu'entre sections).
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.pulseBorder).frame(height: 1)
        }
    }

    private func points(_ values: [Double], size: CGSize) -> [CGPoint] {
        func point(_ index: Int, _ value: Double) -> CGPoint {
            CGPoint(x: size.width * CGFloat(index) / 7, y: size.height * (1 - CGFloat(value / top)))
        }
        return ([0.0] + values).enumerated().map { index, value in point(index, value) }
    }

    private func line(_ values: [Double], size: CGSize) -> Path {
        Path { path in
            let pts = points(values, size: size)
            guard let first = pts.first else { return }
            path.move(to: first)
            for point in pts.dropFirst() { path.addLine(to: point) }
        }
    }

    private func area(_ values: [Double], size: CGSize) -> Path {
        Path { path in
            let pts = points(values, size: size)
            guard let first = pts.first, let last = pts.last else { return }
            path.move(to: CGPoint(x: first.x, y: size.height))
            for point in pts { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
        }
    }

    private func endPoint(_ values: [Double], size: CGSize) -> CGPoint? {
        guard !values.isEmpty else { return nil }
        return points(values, size: size).last
    }
}

/// Puce de légende du mini-graphe — miroir de `.lg` côté web (`i` plein pour
/// les séances, `i.int` pointillé pour l'intensité).
private struct WeekChartLegend: View {
    let color: Color
    let label: String
    var dashed: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if dashed {
                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: 14, y: 0))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                .frame(width: 14, height: 2)
            } else {
                Rectangle().fill(color).frame(width: 14, height: 2)
            }
            Text(label)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

// MARK: - Séance (jour ou à venir)
//
// Gabarit mobile Angular : `.session-focus`/`.items`/`.session-more` sont
// `display:none` (réapparaissent seulement ≥900px, cf. en-tête du fichier).
// La carte mobile ne montre donc que titre/horaire, nom/durée, méta et le
// badge « fait ».

private struct SessionSection: View {
    let session: HomeViewModel.SessionCardModel

    var body: some View {
        // SCSS `.session { border-top:1px solid var(--line); padding:16px 22px; gap:9px; }`.
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                HomeLabel(text: session.title)
                Spacer()
                if let when = session.when {
                    Text(when)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(session.late ? Color.pulseDanger : Color.pulseTextPrimary)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(session.name)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.pulseTextPrimary)
                Spacer()
                if let duration = session.duration {
                    Text(duration)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(Color.pulseTextPrimary)
                }
            }

            Text(session.meta)
                .font(.system(size: 10, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(Color.pulseTextSecondary)

            if session.done {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                    Text(session.doneLabel)
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color.pulseSuccess)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 22)
        .homeTopDivider()
    }
}

// MARK: - Depuis le réveil (pas + calories)

private struct WakeSection: View {
    let viewModel: HomeViewModel

    var body: some View {
        // SCSS `.wake { background:var(--surface); border-top:1px solid var(--line); padding:18px 22px; gap:14px; }`.
        VStack(alignment: .leading, spacing: 14) {
            HomeLabel(text: "Depuis le réveil")
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(viewModel.wake.enumerated()), id: \.element.id) { index, metric in
                    WakeMetricView(metric: metric)
                        .frame(maxWidth: .infinity)
                        .padding(.leading, index == 0 ? 0 : 12)
                        .overlay(alignment: .leading) {
                            if index > 0 {
                                Rectangle().fill(Color.pulseBorder).frame(width: 1)
                            }
                        }
                }
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .background(Color.pulseSurface)
        .homeTopDivider()
    }
}

/// Une jauge « Depuis le réveil » : trait vertical + point de position
/// (rythme atteint), valeur et écart au rythme — port de `.metric`/`.wake-gauge`
/// côté web. Valeur/nom NEUTRES (`.metric-val` hérite de `--text`, aucune
/// teinte de métrique dans le CSS Angular — cf. en-tête du fichier).
private struct WakeMetricView: View {
    let metric: HomeViewModel.WakeMetric

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    Capsule()
                        .fill(Color.pulseSurfaceAlt)
                        .frame(width: 6, height: geo.size.height)
                    if let reached = metric.reached {
                        Circle()
                            .fill(Color.pulseTextPrimary)
                            .frame(width: 11, height: 11)
                            .offset(y: max(geo.size.height - 11, 0) * CGFloat(1 - max(reached, 0)))
                    }
                }
            }
            .frame(width: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(metric.label.uppercased())
                    .font(.system(size: 10, design: .rounded))
                    // `.08em` de 10px ≈ 0.8pt.
                    .tracking(0.8)
                    .foregroundStyle(Color.pulseTextSecondary)
                Text(metric.value.map(HomeNumberFormat.grouped) ?? "—")
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                    .foregroundStyle(metric.value == nil ? Color.pulseTextSecondary : Color.pulseTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let delta = metric.delta {
                    // Écart au rythme : ambre par défaut, succès si tenu —
                    // même choix que `.wake-delta`/`.wake-delta.hit` côté web
                    // (couleur d'écart, pas la couleur de la métrique).
                    Text("\(delta.sign)\(Int(delta.value))")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(delta.hit ? Color.pulseSuccess : Color.pulseStress)
                }
            }
        }
        .frame(height: 76)
    }
}

// MARK: - Nuit dernière (durée, hypnogramme, coucher moyen)

private struct NightSection: View {
    let viewModel: HomeViewModel

    var body: some View {
        // SCSS `.night { padding:20px 22px 24px; gap:14px; }` — pas de filet haut.
        VStack(alignment: .leading, spacing: 14) {
            HomeLabel(text: "Nuit dernière")

            if let duration = viewModel.nightDurationLabel {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(duration)
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pulseTextPrimary)
                        .tracking(-0.72)  // `-0.02em` de 36px.
                    if let delta = viewModel.nightDelta {
                        Text(delta.label)
                            .font(.system(size: 12))
                            .foregroundStyle(delta.short ? Color.pulseDanger : Color.pulseTextSecondary)
                    }
                }
                if let blocks = viewModel.hypnogram {
                    Hypnogram(blocks: blocks)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(viewModel.nightMissing.title)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.pulseTextPrimary)
                    Text(viewModel.nightMissing.sub)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }

            if let bedtime = viewModel.bedtime {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        HomeLabel(text: "Coucher moyen")
                        Spacer()
                        Text(bedtime.clock)
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.pulseTextPrimary)
                    }
                    BedtimeSpread(bedtime: bedtime)
                    Text(bedtime.note)
                        .font(.system(size: 10, design: .rounded))
                        .lineSpacing(5)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                .padding(.top, 14)
                .homeTopDivider()
            }
        }
        .padding(.top, 20)
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
    }
}

/// Barre d'hypnogramme — un segment par phase, largeur proportionnelle à sa
/// durée, teinte par phase (`.pulseSleepDeep/Light/Rem/Awake`, miroir des
/// `--p-*` du web).
private struct Hypnogram: View {
    let blocks: [HomeViewModel.HypnogramBlock]

    var body: some View {
        GeometryReader { geo in
            let total = blocks.reduce(0) { $0 + $1.width }
            HStack(spacing: 0) {
                ForEach(blocks) { block in
                    color(for: block.stage)
                        .frame(width: total > 0 ? geo.size.width * CGFloat(block.width / total) : 0)
                }
            }
        }
        .frame(height: 24)
        // SCSS `.hyp { border-radius:7px; }`.
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func color(for stage: HomeSleepStageKind) -> Color {
        switch stage {
        case .deep: return .pulseSleepDeep
        case .light: return .pulseSleepLight
        case .rem: return .pulseSleepRem
        case .awake: return .pulseSleepAwake
        }
    }
}

/// Bande de régularité du coucher : piste neutre, bande moyenne ± écart type
/// et point moyen teintés `.pulseSleep`, un point par nuit récente — port de
/// `.spread`/`.sp-*` côté web.
private struct BedtimeSpread: View {
    let bedtime: HomeViewModel.Bedtime

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let midY = geo.size.height / 2
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Color.pulseSurfaceAlt)
                        .frame(height: 4)
                        .position(x: geo.size.width / 2, y: midY)

                    Capsule()
                        .fill(Color.pulseSleep.opacity(0.16))
                        .frame(width: max(geo.size.width * CGFloat(bedtime.bandWidth), 0), height: 12)
                        .position(
                            x: geo.size.width * CGFloat(bedtime.bandLeft + bedtime.bandWidth / 2),
                            y: midY)

                    Rectangle()
                        .fill(Color.pulseSleep.opacity(0.55))
                        .frame(width: 1, height: geo.size.height - 2)
                        .position(x: geo.size.width * CGFloat(bedtime.meanAt), y: midY)

                    ForEach(bedtime.dots) { dot in
                        Group {
                            if dot.free {
                                Circle().strokeBorder(Color.pulseSleep.opacity(0.6), lineWidth: 1.5)
                            } else {
                                Circle().fill(Color.pulseSleep.opacity(0.75))
                            }
                        }
                        .frame(width: 7, height: 7)
                        .position(x: geo.size.width * CGFloat(dot.at), y: midY)
                        .accessibilityLabel(dot.title)
                    }
                }
            }
            .frame(height: 18)

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(bedtime.ticks) { tick in
                        Text(tick.label)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Color.pulseTextSecondary)
                            .position(x: geo.size.width * CGFloat(tick.at), y: geo.size.height / 2)
                    }
                }
            }
            .frame(height: 12)
        }
    }
}

#Preview {
    HomeView()
}
