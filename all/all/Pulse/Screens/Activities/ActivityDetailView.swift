//
//  ActivityDetailView.swift
//  all (bridge-connect)
//
//  Détail d'une activité (poussée depuis `ActivitiesView`) — portage de
//  `ActivityDetailComponent` (Angular, page `/activity/:id`, gabarit
//  **standalone** — `:host(:not(.embedded))`, le seul pertinent ici, l'app
//  n'a pas de vue côte-à-côte desktop) : en-tête (icône-retour + libellé +
//  plage horaire), stats, parcours (carte), courbe (cardio/allure/altitude),
//  zones de FC, voies d'escalade, séries de muscu, tours. Chaque section est
//  masquée quand la donnée sous-jacente est absente, comme les `@if` Angular
//  — même ordre DOM que `activity-detail.component.ts` (en-tête+stats, PUIS
//  carte, PUIS courbe…), qui diffère de l'ordre visuel de la maquette (carte
//  avant stats) : l'ordre Angular fait foi ici (règle du prompt).
//
//  Détail visuel 1-1 avec la maquette (`Pulse Refonte.dc.html`, lignes
//  1113-1192, variante sombre non fournie pour cet écran — couleurs
//  `Color.pulse*` déjà dynamiques light/dark) :
//  - En-tête maison (barre système masquée une fois chargé, comme
//    `ActivitiesView`/`NutritionView`) : pastille retour 40×40 (même style
//    que `NutritionDayPillStyle`) + titre 20pt/plage horaire mono 12pt,
//    SANS carte (transparent) — la carte est réservée aux stats, cf. CSS
//    Angular `:host(:not(.embedded)) .hero { background:none }` /
//    `.stats { background:var(--surface)… }`, qui confirme la maquette.
//    Pendant le chargement/l'erreur, la barre système reste visible (retour
//    natif) — seul l'état chargé bascule sur l'en-tête maison.
//  - Stats : tuile locale 19pt/10pt (`ActivityStatTile`), PAS la `StatTile`
//    partagée de `DesignSystem.swift` (36pt, conçue pour l'Accueil) — trop
//    grande pour `.st`/`.sv`/`.sl` (maquette + CSS Angular, 19px/10px).
//  - Courbe : onglets maison façon `<app-seg>` (pastille pleine `--text` au
//    lieu du `Picker` segmenté système, qui n'a pas cette apparence), aire
//    sous la courbe (10 % d'opacité, valeur de la maquette — le composant
//    partagé Angular utilise 16 % par défaut, mais la maquette citée prime
//    ici), 2 lignes de repère horizontales, et l'axe temporel (« 0 min » /
//    milieu / fin) que la version précédente n'avait pas.
//  - Carte : plus de `SectionHeader("Parcours")` ni de fond `PulseCard`
//    (absents de la maquette) — bordure+rayon directs, légende « départ »/
//    « arrivée » en incrustation (comme `.map-foot`/`.lg`), SANS le chip
//    « © OpenStreetMap » (fond de carte réel = tuiles Apple via MapKit, pas
//    OSM — l'attribution du web serait inexacte ici) ni les boutons
//    zoom/plein écran (MapKit gère déjà le pincer-zoomer nativement).
//  - Tours : plus de `Grid` partagé — colonnes maison (largeurs fixes 26/52pt
//    façon `.lap`), et la colonne **Distance est retirée** : le CSS Angular
//    la masque explicitement en mobile (`.lap .dist{display:none}`), et la
//    maquette (mobile) ne montre que # / Temps / Allure / bpm — cohérent
//    avec le gabarit unique de cet écran (jamais desktop). La colonne
//    « Temps » reprend `ActivityFormat.clock` (format « 13:49 », déjà
//    utilisé ailleurs sur cet écran pour les zones/voies) plutôt que
//    `ActivityFormat.duration` (« 13min49 ») : c'est le format que montre la
//    maquette pour cette colonne précise.
//  - Zones/Voies/Séries : non citées dans la maquette, laissées telles
//    quelles (déjà `PulseCard`/`SectionHeader`, aucune contradiction à
//    corriger).
//
//  Suppression et carte interactive plein écran restent hors périmètre
//  (lecture seule).
//

import SwiftUI
import Charts
import MapKit

struct ActivityDetailView: View {
    @State private var vm: ActivityDetailViewModel

    init(activityId: Int) {
        _vm = State(initialValue: ActivityDetailViewModel(activityId: activityId))
    }

    var body: some View {
        content
            .background(Color.pulseBackground)
            .navigationTitle("Activité")
            .navigationBarTitleDisplayMode(.inline)
            // La barre système ne s'efface qu'une fois les données chargées
            // (l'en-tête maison, qui la remplace visuellement, a besoin du
            // libellé/de l'heure de l'activité) — pendant le chargement/
            // l'erreur, le chevron de retour natif reste le seul moyen de
            // sortir.
            .toolbar(isLoaded ? .hidden : .visible, for: .navigationBar)
            .task { await vm.load() }
    }

    private var isLoaded: Bool {
        if case .loaded = vm.state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .loading:
            LoadingView(message: "Chargement de l'activité…")
        case .failed(let message):
            ErrorView(message: message) {
                Task { await vm.load() }
            }
        case .loaded(let detail):
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ActivityHeaderRow(detail: detail)
                        .padding(.horizontal, PulseSpacing.lg)
                        .padding(.bottom, PulseSpacing.md)

                    VStack(alignment: .leading, spacing: PulseSpacing.md) {
                        ActivityStatsCard(detail: detail)

                        if detail.track.count > 1 {
                            ActivityMapCard(coordinates: coordinates(from: detail.track), sport: detail.sport)
                        }

                        if let streams = detail.streams {
                            ActivityMetricChartCard(detail: detail, streams: streams)
                        }

                        if !detail.hrZones.isEmpty {
                            ActivityZonesCard(zones: detail.hrZones)
                        }

                        ActivityClimbsCard(splits: detail.splits)
                        ActivityExercisesCard(sets: detail.sets)
                        ActivityLapsCard(laps: detail.laps)
                    }
                    .padding(.horizontal, PulseSpacing.lg)
                    .padding(.bottom, PulseSpacing.lg)
                }
            }
            .pulseTabBarClearance()
        }
    }

    private func coordinates(from track: [[Double]]) -> [CLLocationCoordinate2D] {
        track.compactMap { point in
            guard point.count == 2 else { return nil }
            return CLLocationCoordinate2D(latitude: point[0], longitude: point[1])
        }
    }
}

// MARK: - En-tête

/// Pastille retour + libellé sport/plage horaire, transparent (pas de
/// carte) — maquette lignes 1119-1125.
private struct ActivityHeaderRow: View {
    let detail: ActivityDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .center, spacing: PulseSpacing.md) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.pulseTextSecondary)
                    .frame(width: 40, height: 40)
                    .background(Color.pulseSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.pulseBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .accessibilityLabel("Retour")

            VStack(alignment: .leading, spacing: 2) {
                Text(ActivitySport.label(sport: detail.sport, subSport: detail.subSport))
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.pulseTextPrimary)
                Text(ActivityDateFormatting.rangeLabel(ActivityDateFormatting.date(from: detail.startTime)))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }
}

// MARK: - Stats

/// Carte de stats — équivalent `.stats`/`.st`/`.sv`/`.sl` (maquette, lignes
/// 1151-1155) : grille 3 colonnes, tuiles locales 19pt/10pt (pas la
/// `StatTile` partagée, trop grande ici). Durée toujours, distance/allure/FC
/// moy/FC max/kcal si présents — même garde que `ActivityDetailComponent`.
private struct ActivityStatsCard: View {
    let detail: ActivityDetail

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
            spacing: 14
        ) {
            ActivityStatTile(label: "Durée", value: ActivityFormat.duration(detail.durationS))
            if let distanceM = detail.distanceM, distanceM > 0 {
                ActivityStatTile(label: "Distance", value: ActivityFormat.distanceKm(distanceM) ?? "—")
                ActivityStatTile(
                    label: "Allure /km",
                    value: ActivityFormat.pace(durationS: detail.durationS, distanceM: distanceM)
                )
            }
            if let avgHr = detail.avgHr, avgHr > 0 {
                ActivityStatTile(label: "FC moy", value: "\(Int(avgHr.rounded()))", accent: .pulseHR)
            }
            if let maxHr = detail.maxHr, maxHr > 0 {
                ActivityStatTile(label: "FC max", value: "\(Int(maxHr.rounded()))", accent: .pulseHR)
            }
            if let calories = detail.calories, calories > 0 {
                ActivityStatTile(label: "kcal", value: "\(Int(calories.rounded()))", accent: .pulseCalories)
            }
        }
        .padding(14)
        .background(Color.pulseSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.pulseBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ActivityStatTile: View {
    let label: String
    let value: String
    var accent: Color = .pulseTextPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(Color.pulseTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Carte

/// Parcours GPS — équivalent `.map-card` (maquette, lignes 1129-1149) sans
/// les boutons zoom/plein écran (MapKit gère le pincer-zoomer nativement) ni
/// le chip d'attribution (tuiles Apple via MapKit, pas OpenStreetMap — le
/// texte du web serait inexact ici). Tracé et marqueur de départ reprennent
/// la couleur du sport (`sportColor`, Angular `renderMap`/`resolveColor`),
/// jamais l'accent bleu générique ; l'arrivée reste neutre (`pulseTextPrimary`,
/// dynamique clair/sombre — le web fixe `#1c2124` même en thème sombre, pas
/// repris ici).
private struct ActivityMapCard: View {
    let coordinates: [CLLocationCoordinate2D]
    let sport: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Map(initialPosition: cameraPosition) {
                MapPolyline(coordinates: coordinates)
                    .stroke(routeColor, lineWidth: 4)
                if let first = coordinates.first {
                    Marker("Départ", coordinate: first)
                        .tint(routeColor)
                }
                if let last = coordinates.last {
                    Marker("Arrivée", coordinate: last)
                        .tint(Color.pulseTextPrimary)
                }
            }

            legend
                .padding(10)
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.pulseBorder, lineWidth: 1)
        )
    }

    /// Légende « départ »/« arrivée » — équivalent `.map-foot`/`.lg`.
    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(routeColor, lineWidth: 2)
                    .background(Circle().fill(Color.pulseSurface))
                    .frame(width: 8, height: 8)
                Text("départ")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.pulseTextPrimary)
                    .frame(width: 8, height: 8)
                Text("arrivée")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.pulseSurface.opacity(0.9))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.pulseBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var routeColor: Color {
        ActivitySport.color(sport: sport)
    }

    private var cameraPosition: MapCameraPosition {
        guard let region = boundingRegion else { return .automatic }
        return .region(region)
    }

    private var boundingRegion: MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude)
            maxLng = max(maxLng, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.003),
            longitudeDelta: max((maxLng - minLng) * 1.4, 0.003)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

// MARK: - Courbe

/// Onglets Cardio/Allure/Altitude — équivalent `<app-seg>` (maquette, lignes
/// 1158-1160) : pastille pleine `pulseTextPrimary` active, contour clair
/// inactive — PAS le `Picker` segmenté système (apparence différente). Un
/// onglet n'apparaît que si son flux a au moins une valeur exploitable,
/// même condition que le front.
private enum ActivityChartTab: String, CaseIterable, Identifiable, Equatable {
    case cardio, allure, altitude
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cardio: return "Cardio"
        case .allure: return "Allure"
        case .altitude: return "Altitude"
        }
    }
}

private struct ActivityMetricChartCard: View {
    let detail: ActivityDetail
    let streams: ActivityStreams
    @State private var tab: ActivityChartTab

    init(detail: ActivityDetail, streams: ActivityStreams) {
        self.detail = detail
        self.streams = streams
        let available = Self.availableTabs(detail: detail, streams: streams)
        _tab = State(initialValue: available.first ?? .cardio)
    }

    static func availableTabs(detail: ActivityDetail, streams: ActivityStreams) -> [ActivityChartTab] {
        var tabs: [ActivityChartTab] = []
        if streams.hr.contains(where: { $0 != nil }) { tabs.append(.cardio) }
        if let distanceM = detail.distanceM, distanceM > 100, streams.speed.contains(where: { $0 != nil }) {
            tabs.append(.allure)
        }
        if !detail.track.isEmpty, streams.altitude.contains(where: { $0 != nil }) {
            tabs.append(.altitude)
        }
        return tabs
    }

    var body: some View {
        let tabs = Self.availableTabs(detail: detail, streams: streams)
        if !tabs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if tabs.count > 1 {
                    ActivityChartTabsRow(tabs: tabs, selection: $tab)
                }

                VStack(alignment: .leading, spacing: PulseSpacing.md) {
                    let head = chartHead(for: tab)
                    HStack(alignment: .lastTextBaseline) {
                        HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.xs) {
                            Text(head.value)
                                .font(.system(size: 32, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.pulseTextPrimary)
                            Text(head.unit)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                        Spacer()
                        if !head.range.isEmpty {
                            Text(head.range)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                    }

                    chart(for: tab)
                        .frame(height: 100)

                    axisLabels(for: tab)
                }
                .padding(16)
                .background(Color.pulseSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.pulseBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .onChange(of: tabs) { _, newTabs in
                if !newTabs.contains(tab) { tab = newTabs.first ?? .cardio }
            }
        }
    }

    private func points(_ values: [Double?]) -> [(time: Double, value: Double)] {
        var out: [(Double, Double)] = []
        for (index, value) in values.enumerated() {
            guard let value else { continue }
            let time = streams.time.indices.contains(index) ? (streams.time[index] ?? Double(index)) : Double(index)
            out.append((time, value))
        }
        return out
    }

    private func seriesAndColor(for tab: ActivityChartTab) -> ([(time: Double, value: Double)], Color) {
        switch tab {
        case .cardio:
            return (points(streams.hr), .pulseHR)
        case .allure:
            let series = points(streams.speed).map { entry in
                (time: entry.time, value: entry.value > 0.5 ? 1000 / entry.value : 0)
            }
            return (series, .pulseAccent)
        case .altitude:
            return (points(streams.altitude), .pulseSteps)
        }
    }

    /// Aire (10 % d'opacité, valeur de la maquette) + ligne, plus 2 repères
    /// horizontaux (à ~1/3 et ~2/3 de la hauteur, comme les `<line>` du SVG
    /// de la maquette) — la courbe SwiftUI Charts n'a pas d'axes visibles
    /// (`.chartXAxis(.hidden)`/`.chartYAxis(.hidden)`), l'échelle Y réelle
    /// n'a pas besoin de correspondre aux repères, purement décoratifs comme
    /// dans la maquette.
    @ViewBuilder
    private func chart(for tab: ActivityChartTab) -> some View {
        let (series, color) = seriesAndColor(for: tab)
        ZStack {
            GeometryReader { geo in
                Path { path in
                    let y1 = geo.size.height * 0.32
                    let y2 = geo.size.height * 0.68
                    path.move(to: CGPoint(x: 0, y: y1))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y1))
                    path.move(to: CGPoint(x: 0, y: y2))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y2))
                }
                .stroke(Color.pulseSurfaceAlt, lineWidth: 1)
            }

            Chart(series.indices, id: \.self) { i in
                AreaMark(x: .value("Temps", series[i].time), y: .value("Valeur", series[i].value))
                    .foregroundStyle(color.opacity(0.10))
                LineMark(x: .value("Temps", series[i].time), y: .value("Valeur", series[i].value))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
    }

    /// « 0 min » / milieu / fin — équivalent `.xaxis`/`elapsedFormat`
    /// (maquette, ligne 1175).
    private func axisLabels(for tab: ActivityChartTab) -> some View {
        let maxTime = streams.time.compactMap { $0 }.last ?? detail.durationS ?? 0
        return HStack {
            Text(elapsedLabel(0))
            Spacer()
            Text(elapsedLabel(maxTime / 2))
            Spacer()
            Text(elapsedLabel(maxTime))
        }
        .font(.system(size: 10, design: .rounded))
        .foregroundStyle(Color.pulseTextSecondary)
    }

    /// "0 min" / "24 min" (< 1h) ou "1h05" (≥ 1h) — équivalent
    /// `elapsedFormat` (Angular).
    private func elapsedLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m) min"
    }

    private struct ChartHead {
        let value: String
        let unit: String
        let range: String
    }

    private func chartHead(for tab: ActivityChartTab) -> ChartHead {
        switch tab {
        case .cardio:
            let values = streams.hr.compactMap { $0 }
            guard !values.isEmpty else { return ChartHead(value: "—", unit: "bpm en moyenne", range: "") }
            let average = detail.avgHr ?? (values.reduce(0, +) / Double(values.count))
            let low = values.min() ?? 0
            let high = values.max() ?? 0
            return ChartHead(
                value: "\(Int(average.rounded()))",
                unit: "bpm en moyenne",
                range: "\(Int(low)) – \(Int(high))"
            )
        case .allure:
            let pace = ActivityFormat.pace(durationS: detail.durationS, distanceM: detail.distanceM)
            let speeds = streams.speed.compactMap { $0 }.filter { $0 > 0.5 }
            guard let minSpeed = speeds.min(), let maxSpeed = speeds.max() else {
                return ChartHead(value: pace, unit: "/km en moyenne", range: "")
            }
            let range = "\(ActivityFormat.paceSecPerKm(1000 / maxSpeed)) – \(ActivityFormat.paceSecPerKm(1000 / minSpeed))"
            return ChartHead(value: pace, unit: "/km en moyenne", range: range)
        case .altitude:
            let values = streams.altitude.compactMap { $0 }
            guard !values.isEmpty else { return ChartHead(value: "—", unit: "m de dénivelé", range: "") }
            var gain = 0.0
            for i in 1..<values.count where values[i] > values[i - 1] {
                gain += values[i] - values[i - 1]
            }
            let low = values.min() ?? 0
            let high = values.max() ?? 0
            return ChartHead(
                value: "+\(Int(gain.rounded()))",
                unit: "m de dénivelé",
                range: "\(Int(low)) – \(Int(high)) m"
            )
        }
    }
}

private struct ActivityChartTabsRow: View {
    let tabs: [ActivityChartTab]
    @Binding var selection: ActivityChartTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tabs) { tab in
                let isOn = tab == selection
                Button {
                    selection = tab
                } label: {
                    Text(tab.label)
                        .font(.system(size: 13, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? Color.pulseSurface : Color.pulseTextPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(isOn ? Color.pulseTextPrimary : Color.pulseSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(isOn ? Color.pulseTextPrimary : Color.pulseBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Zones de FC

/// Barres de zones — équivalent `.zlist`/`.zrow` (Angular), du plus haut au
/// plus bas comme `zones` (`.reverse()`). Non citée dans la maquette,
/// laissée telle quelle (`PulseCard`/`SectionHeader`).
private struct ActivityZonesCard: View {
    let zones: [HrZone]

    private static let colors: [Color] = [.pulseAccent, .pulseSteps, .pulseCalories, .pulseHR, .pulseDanger]

    var body: some View {
        let total = zones.reduce(0.0) { $0 + $1.seconds }
        let maxSeconds = max(zones.map(\.seconds).max() ?? 1, 1)

        PulseCard {
            SectionHeader("Zones d'effort") {
                Text(ActivityFormat.clock(total))
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            VStack(spacing: PulseSpacing.sm) {
                ForEach(zones.reversed()) { zone in
                    HStack(spacing: PulseSpacing.sm) {
                        Text("Z\(zone.zone)")
                            .font(PulseFont.metricLabel)
                            .foregroundStyle(Color.pulseTextSecondary)
                            .frame(width: 24, alignment: .leading)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Self.colors[min(max(zone.zone - 1, 0), Self.colors.count - 1)])
                                .frame(width: geo.size.width * CGFloat(zone.seconds / maxSeconds))
                        }
                        .frame(height: 12)
                        Text(ActivityFormat.clock(zone.seconds))
                            .font(PulseFont.metricLabel)
                            .foregroundStyle(Color.pulseTextPrimary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }

            if let first = zones.first, let last = zones.last {
                Text(note(first: first, last: last))
                    .font(PulseFont.metricUnit)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }

    private func note(first: HrZone, last: HrZone) -> String {
        let from = first.fromBpm != nil ? "\(Int(first.fromBpm!.rounded()))" : "—"
        let to = last.toBpm != nil ? "\(Int(last.toBpm!.rounded()))" : "—"
        return "bornes de la montre · Z1 dès \(from) bpm, Z\(last.zone) au-delà de \(to) bpm"
    }
}

// MARK: - Voies (escalade)

/// Segments `climbActive` — équivalent `climbs`/`climbSummary` (Angular).
/// Non citée dans la maquette, laissée telle quelle.
private struct ActivityClimbsCard: View {
    let splits: [ActivitySplit]

    private var climbs: [ActivitySplit] { splits.filter { $0.type == "climbActive" } }
    private var restSeconds: Double {
        splits.filter { $0.type == "climbRest" }.reduce(0) { $0 + ($1.durationS ?? 0) }
    }

    var body: some View {
        if !climbs.isEmpty {
            PulseCard {
                SectionHeader("Voies") {
                    Text(summary)
                        .font(PulseFont.metricLabel)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                ForEach(Array(climbs.enumerated()), id: \.offset) { index, climb in
                    HStack {
                        Text("Voie \(index + 1)")
                            .font(.subheadline)
                            .foregroundStyle(Color.pulseTextPrimary)
                        Spacer()
                        Text(detail(for: climb))
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }
            }
        }
    }

    private var summary: String {
        let ascent = climbs.reduce(0.0) { $0 + ($1.ascentM ?? 0) }
        var parts = ["\(climbs.count) voie\(climbs.count > 1 ? "s" : "")"]
        if ascent > 0 { parts.append("\(Int(ascent.rounded())) m") }
        if restSeconds > 0 { parts.append("\(ActivityFormat.clock(restSeconds)) de repos") }
        return parts.joined(separator: " · ")
    }

    private func detail(for climb: ActivitySplit) -> String {
        var text = ActivityFormat.clock(climb.durationS ?? 0)
        if let ascent = climb.ascentM, ascent > 0 {
            text += " · \(Int(ascent.rounded())) m"
        }
        return text
    }
}

// MARK: - Séries (muscu)

/// Séries `setMesgs` groupées par catégorie — équivalent `exercises`/
/// `setsSummary` (Angular). Non citée dans la maquette, laissée telle quelle.
private struct ActivityExercisesCard: View {
    let sets: [ActivitySet]

    private struct Group {
        let label: String
        let known: Bool
        let count: Int
        let detail: String
    }

    private var groups: [Group] {
        var order: [String] = []
        var buckets: [String: (label: String, known: Bool, count: Int, reps: [Double])] = [:]
        for set in sets {
            let key = set.category ?? "unknown"
            if buckets[key] == nil {
                buckets[key] = (ActivitySport.exerciseName(set.category), set.category != nil, 0, [])
                order.append(key)
            }
            buckets[key]?.count += 1
            if let reps = set.repetitions {
                buckets[key]?.reps.append(reps)
            }
        }
        return order
            .compactMap { buckets[$0] }
            .sorted { $0.count > $1.count }
            .map { entry in
                let unique = Set(entry.reps)
                let detail: String
                if unique.isEmpty {
                    detail = "\(entry.count) séries"
                } else if unique.count == 1, let value = unique.first {
                    detail = "\(entry.count) × \(Int(value.rounded()))"
                } else {
                    let low = Int((entry.reps.min() ?? 0).rounded())
                    let high = Int((entry.reps.max() ?? 0).rounded())
                    detail = "\(entry.count) × \(low)–\(high)"
                }
                return Group(label: entry.label, known: entry.known, count: entry.count, detail: detail)
            }
    }

    private var summary: String {
        let reps = sets.reduce(0.0) { $0 + ($1.repetitions ?? 0) }
        let named = sets.filter { $0.category != nil }.count
        var parts = ["\(sets.count) série\(sets.count > 1 ? "s" : "")"]
        if reps > 0 { parts.append("\(Int(reps.rounded())) reps") }
        if named < sets.count { parts.append("\(named)/\(sets.count) identifiées") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if !sets.isEmpty {
            PulseCard {
                SectionHeader("Séries") {
                    Text(summary)
                        .font(PulseFont.metricLabel)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    HStack {
                        Text(group.label)
                            .font(.subheadline)
                            .foregroundStyle(group.known ? Color.pulseTextPrimary : Color.pulseTextSecondary)
                        Spacer()
                        Text(group.detail)
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }
            }
        }
    }
}

// MARK: - Tours

/// Table de tours — équivalent `.lap`/`.lap-head` (maquette, lignes
/// 1180-1184), affichée seulement s'il y a plus d'un tour (comme
/// `a.laps.length > 1`). Colonnes # / Temps / Allure / bpm (largeurs fixes
/// 26/flex/flex/52pt) — la colonne Distance est retirée : masquée en mobile
/// côté Angular (`.lap .dist{display:none}`) et absente de la maquette.
/// Colonne « Temps » en `ActivityFormat.clock` (« 13:49 »), pas
/// `ActivityFormat.duration` (« 13min49 ») — le format que montre la
/// maquette pour cette colonne précise.
private struct ActivityLapsCard: View {
    let laps: [ActivityLap]

    var body: some View {
        if laps.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                Text("Tours".uppercased())
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .tracking(1.32)
                    .foregroundStyle(Color.pulseTextSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                HStack(spacing: 10) {
                    Text("#")
                        .frame(width: 26, alignment: .leading)
                    Text("Temps")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Allure")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("bpm")
                        .frame(width: 52, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(Color.pulseTextSecondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                ForEach(laps) { lap in
                    HStack(spacing: 10) {
                        Text("\(lap.index)")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Color.pulseTextSecondary)
                            .frame(width: 26, alignment: .leading)
                        Text(ActivityFormat.clock(lap.durationS ?? 0))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(ActivityFormat.pace(durationS: lap.durationS, distanceM: lap.distanceM))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(lap.avgHr != nil ? "\(Int(lap.avgHr!.rounded()))" : "—")
                            .frame(width: 52, alignment: .trailing)
                    }
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.pulseTextPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.pulseSurfaceAlt).frame(height: 1)
                    }
                }
            }
            .background(Color.pulseSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.pulseBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
