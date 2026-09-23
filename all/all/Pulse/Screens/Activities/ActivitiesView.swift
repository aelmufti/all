//
//  ActivitiesView.swift
//  all (bridge-connect)
//
//  Écran racine « Activités » (onglet `PulseTab.activites`, cf.
//  `PulseShellView`) — portage de `ActivitiesComponent` (Angular, page
//  `/activities`) : liste `GET api/activities` regroupée par jour civil
//  local, la même coupure que `ActivitiesComponent.groups`. Le split desktop
//  (liste + détail côte à côte) n'a pas d'équivalent mobile : chaque ligne
//  pousse `ActivityDetailView` dans la pile de navigation. Import `.fit` et
//  filtre par sport (sidebar Angular) sont hors périmètre de cet écran.
//

import SwiftUI

struct ActivitiesView: View {
    @State private var vm = ActivitiesViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Activités")
                .background(Color.pulseBackground)
                .task { await vm.load() }
                .navigationDestination(for: Int.self) { id in
                    ActivityDetailView(activityId: id)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .loading:
            LoadingView(message: "Chargement des activités…")
        case .failed(let message):
            ErrorView(message: message) {
                Task { await vm.load() }
            }
        case .loaded(let activities):
            if activities.isEmpty {
                emptyState
            } else {
                list(of: activities)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: PulseSpacing.md) {
            Image(systemName: "figure.run.circle")
                .font(.system(size: 40))
                .foregroundStyle(Color.pulseTextSecondary)
            Text("Aucune activité.")
                .font(PulseFont.body)
                .foregroundStyle(Color.pulseTextSecondary)
            Text("Importe des fichiers .FIT depuis Pulse, ou dépose-les dans data/inbox.")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(PulseSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pulseBackground)
    }

    private func list(of activities: [Activity]) -> some View {
        List {
            ForEach(groups(of: activities), id: \.key) { group in
                Section {
                    ForEach(group.activities) { activity in
                        NavigationLink(value: activity.id) {
                            ActivityRow(activity: activity)
                        }
                        .listRowBackground(Color.pulseSurface)
                    }
                } header: {
                    Text(group.label)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.pulseBackground)
        .refreshable { await vm.load() }
    }

    private struct DayGroup {
        let key: Date
        let label: String
        let activities: [Activity]
    }

    /// Regroupement par jour civil local, dans l'ordre de la liste (déjà
    /// triée `start_time DESC` côté serveur) — même esprit que
    /// `ActivitiesComponent.groups`, sans la fenêtre glissante de jours (pas
    /// de pagination client sur cet écran, la limite haute de `load()` sert
    /// de fenêtre).
    private func groups(of activities: [Activity]) -> [DayGroup] {
        var order: [Date] = []
        var buckets: [Date: [Activity]] = [:]
        for activity in activities {
            let parsed = ActivityDateFormatting.date(from: activity.startTime)
            let key = parsed.map { Calendar.current.startOfDay(for: $0) } ?? .distantPast
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(activity)
        }
        return order.map { key in
            let items = buckets[key] ?? []
            let label = key == .distantPast ? "Date inconnue" : ActivityDateFormatting.dayLabel(key)
            return DayGroup(key: key, label: label, activities: items)
        }
    }
}

/// Ligne de liste — icône de sport, libellé, heure, résumé (durée · distance
/// · allure/FC), même esprit que `.row.act` (Angular, `summaryOf`).
private struct ActivityRow: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: PulseSpacing.md) {
            Image(systemName: ActivitySport.icon(sport: activity.sport))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.pulseAccent)
                .frame(width: 38, height: 38)
                .background(Color.pulseSurfaceAlt)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: PulseSpacing.xs) {
                HStack {
                    Text(ActivitySport.label(sport: activity.sport, subSport: activity.subSport))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.pulseTextPrimary)
                    Spacer()
                    Text(ActivityDateFormatting.clock(ActivityDateFormatting.date(from: activity.startTime)))
                        .font(PulseFont.metricLabel)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
        .padding(.vertical, PulseSpacing.xs)
    }

    private var summary: String {
        var parts = [ActivityFormat.shortDuration(activity.durationS)]
        if let distanceM = activity.distanceM, distanceM > 0 {
            if let km = ActivityFormat.distanceKm(distanceM) { parts.append(km) }
            parts.append(ActivityFormat.pace(durationS: activity.durationS, distanceM: distanceM))
        }
        if let avgHr = activity.avgHr, avgHr > 0 {
            parts.append("\(Int(avgHr.rounded())) bpm")
        } else if (activity.distanceM ?? 0) <= 0, let calories = activity.calories, calories > 0 {
            parts.append("\(Int(calories.rounded())) kcal")
        }
        return parts.joined(separator: " · ")
    }
}

#Preview {
    ActivitiesView()
}
