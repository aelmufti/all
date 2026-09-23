//
//  ActivityDetailView.swift
//  all (bridge-connect)
//
//  Détail d'une activité (poussée depuis `ActivitiesView`) — portage de
//  `ActivityDetailComponent` (Angular, page `/activity/:id`) : hero (icône +
//  libellé + plage horaire + stats), parcours (carte), courbe (cardio/
//  allure/altitude), zones de FC, voies d'escalade, séries de muscu, tours.
//  Chaque section est masquée quand la donnée sous-jacente est absente, comme
//  les `@if` Angular. Suppression et carte Leaflet interactive plein écran
//  sont hors périmètre de cet écran (lecture seule).
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
            .task { await vm.load() }
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
                VStack(spacing: PulseSpacing.lg) {
                    ActivityHeroCard(detail: detail)

                    if detail.track.count > 1 {
                        ActivityMapCard(coordinates: coordinates(from: detail.track))
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
                .padding(PulseSpacing.lg)
            }
        }
    }

    private func coordinates(from track: [[Double]]) -> [CLLocationCoordinate2D] {
        track.compactMap { point in
            guard point.count == 2 else { return nil }
            return CLLocationCoordinate2D(latitude: point[0], longitude: point[1])
        }
    }
}

// MARK: - Hero

/// En-tête : icône + libellé sport + plage horaire, grille de stats
/// (durée toujours, distance/allure/FC moy/FC max/kcal si présents) — même
/// esprit que `.hero`/`.stats` (Angular), sans le bouton retour (la pile de
/// navigation iOS a déjà son propre chevron).
private struct ActivityHeroCard: View {
    let detail: ActivityDetail

    var body: some View {
        PulseCard {
            HStack(spacing: PulseSpacing.md) {
                Image(systemName: ActivitySport.icon(sport: detail.sport))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.pulseOnAccent)
                    .frame(width: 44, height: 44)
                    .background(Color.pulseAccent)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                    Text(ActivitySport.label(sport: detail.sport, subSport: detail.subSport))
                        .font(PulseFont.sectionTitle)
                        .foregroundStyle(Color.pulseTextPrimary)
                    Text(ActivityDateFormatting.rangeLabel(ActivityDateFormatting.date(from: detail.startTime)))
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: PulseSpacing.lg
            ) {
                StatTile(label: "Durée", value: ActivityFormat.duration(detail.durationS))
                if let distanceM = detail.distanceM, distanceM > 0 {
                    StatTile(label: "Distance", value: ActivityFormat.distanceKm(distanceM) ?? "—")
                    StatTile(
                        label: "Allure /km",
                        value: ActivityFormat.pace(durationS: detail.durationS, distanceM: distanceM)
                    )
                }
                if let avgHr = detail.avgHr, avgHr > 0 {
                    StatTile(label: "FC moy", value: "\(Int(avgHr.rounded()))", accent: .pulseDanger)
                }
                if let maxHr = detail.maxHr, maxHr > 0 {
                    StatTile(label: "FC max", value: "\(Int(maxHr.rounded()))", accent: .pulseDanger)
                }
                if let calories = detail.calories, calories > 0 {
                    StatTile(label: "kcal", value: "\(Int(calories.rounded()))")
                }
            }
            .padding(.top, PulseSpacing.xs)
        }
    }
}

// MARK: - Carte

/// Parcours GPS — équivalent `.map-card` (Leaflet). Cadrage automatique sur
/// la trace, marqueurs départ/arrivée.
private struct ActivityMapCard: View {
    let coordinates: [CLLocationCoordinate2D]

    var body: some View {
        PulseCard {
            SectionHeader("Parcours")
            Map(initialPosition: cameraPosition) {
                MapPolyline(coordinates: coordinates)
                    .stroke(Color.pulseAccent, lineWidth: 4)
                if let first = coordinates.first {
                    Marker("Départ", coordinate: first)
                        .tint(.green)
                }
                if let last = coordinates.last {
                    Marker("Arrivée", coordinate: last)
                        .tint(Color.pulseDanger)
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous))
        }
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

/// Onglets Cardio/Allure/Altitude — équivalent `chartTabs`/`@switch` (Angular).
/// Un onglet n'apparaît que si son flux a au moins une valeur exploitable,
/// même condition que le front.
private struct ActivityMetricChartCard: View {
    let detail: ActivityDetail
    let streams: ActivityStreams
    @State private var tab: ChartTab

    enum ChartTab: String, CaseIterable, Identifiable {
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

    init(detail: ActivityDetail, streams: ActivityStreams) {
        self.detail = detail
        self.streams = streams
        let available = Self.availableTabs(detail: detail, streams: streams)
        _tab = State(initialValue: available.first ?? .cardio)
    }

    static func availableTabs(detail: ActivityDetail, streams: ActivityStreams) -> [ChartTab] {
        var tabs: [ChartTab] = []
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
            PulseCard {
                if tabs.count > 1 {
                    Picker("Courbe", selection: $tab) {
                        ForEach(tabs) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                let head = chartHead(for: tab)
                HStack(alignment: .lastTextBaseline) {
                    HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.xs) {
                        Text(head.value)
                            .font(PulseFont.metricValue)
                            .foregroundStyle(Color.pulseTextPrimary)
                        Text(head.unit)
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    Spacer()
                    if !head.range.isEmpty {
                        Text(head.range)
                            .font(PulseFont.metricUnit)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }

                chart(for: tab)
                    .frame(height: 140)
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

    @ViewBuilder
    private func chart(for tab: ChartTab) -> some View {
        switch tab {
        case .cardio:
            lineChart(points(streams.hr), color: .pulseDanger)
        case .allure:
            let series = points(streams.speed).map { entry in
                (time: entry.time, value: entry.value > 0.5 ? 1000 / entry.value : 0)
            }
            lineChart(series, color: .pulseAccent)
        case .altitude:
            lineChart(points(streams.altitude), color: .pulseSuccess)
        }
    }

    private func lineChart(_ series: [(time: Double, value: Double)], color: Color) -> some View {
        Chart(series.indices, id: \.self) { i in
            LineMark(x: .value("Temps", series[i].time), y: .value("Valeur", series[i].value))
                .foregroundStyle(color)
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    private struct ChartHead {
        let value: String
        let unit: String
        let range: String
    }

    private func chartHead(for tab: ChartTab) -> ChartHead {
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

// MARK: - Zones de FC

/// Barres de zones — équivalent `.zlist`/`.zrow` (Angular), du plus haut au
/// plus bas comme `zones` (`.reverse()`).
private struct ActivityZonesCard: View {
    let zones: [HrZone]

    private static let colors: [Color] = [.pulseAccent, .pulseSuccess, .pulseTextPrimary, .pulseTextSecondary, .pulseDanger]

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
/// `setsSummary` (Angular).
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

/// Table de tours — équivalent `.lap`/`.lap-head` (Angular), affichée
/// seulement s'il y a plus d'un tour (comme `a.laps.length > 1`).
private struct ActivityLapsCard: View {
    let laps: [ActivityLap]

    var body: some View {
        if laps.count > 1 {
            PulseCard {
                SectionHeader("Tours") {
                    Text("\(laps.count) tours")
                        .font(PulseFont.metricLabel)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                Grid(alignment: .leading, horizontalSpacing: PulseSpacing.sm, verticalSpacing: PulseSpacing.sm) {
                    GridRow {
                        Text("#")
                        Text("Temps")
                        Text("Distance")
                        Text("Allure")
                        Text("bpm")
                    }
                    .font(PulseFont.metricLabel)
                    .foregroundStyle(Color.pulseTextSecondary)

                    ForEach(laps) { lap in
                        GridRow {
                            Text("\(lap.index)")
                            Text(ActivityFormat.duration(lap.durationS))
                            Text(ActivityFormat.distanceKm(lap.distanceM) ?? "—")
                            Text(ActivityFormat.pace(durationS: lap.durationS, distanceM: lap.distanceM))
                            Text(lap.avgHr != nil ? "\(Int(lap.avgHr!.rounded()))" : "—")
                        }
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Color.pulseTextPrimary)
                    }
                }
            }
        }
    }
}
