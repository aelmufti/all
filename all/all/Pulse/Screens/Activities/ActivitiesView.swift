//
//  ActivitiesView.swift
//  all (bridge-connect)
//
//  Écran racine « Activités » (onglet `PulseTab.activites`, cf.
//  `PulseShellView`) — portage de `ActivitiesComponent` (Angular, page
//  `/activities`) : liste `GET api/activities` regroupée par jour civil
//  local, la même coupure que `ActivitiesComponent.groups`. Le split desktop
//  (liste + détail côte à côte) n'a pas d'équivalent mobile : chaque ligne
//  pousse `ActivityDetailView` dans la pile de navigation.
//
//  Détail visuel 1-1 avec la maquette (`Pulse Refonte.dc.html`, lignes
//  1033-1109, variante sombre 1855-1910) : en-tête maison (barre système
//  masquée, comme `NutritionView`) — titre + compteur de séances — puis
//  cartes plates par jour (filet coloré par sport, PAS l'icône ronde du
//  DOM Angular) avec une seule valeur à droite (distance si connue, sinon
//  durée). Écarts assumés vs le DOM Angular (`activities.component.ts`),
//  tranchés en faveur de la maquette puisque explicitement citée :
//  - Ligne : la maquette n'affiche qu'UNE valeur à droite (distance ou
//    durée), pas le résumé multi-métriques `summaryOf()` (durée · distance ·
//    allure · FC/kcal) — le détail de l'activité reste la source pour ces
//    métriques.
//  - En-têtes de jour : pas de compteur de séances par jour (`.u11` Angular)
//    dans la maquette mobile — supprimé ici aussi.
//  - Import `.fit` et filtre par sport (sidebar desktop Angular) restent hors
//    périmètre (pas de méthode d'upload sur `ActivitiesViewModel`) : le
//    bouton d'import de la maquette (icône seule, 36×36) n'est pas repris
//    pour ne pas poser un bouton mort.
//

import SwiftUI

struct ActivitiesView: View {
    @State private var vm = ActivitiesViewModel()

    var body: some View {
        NavigationStack {
            content
                .background(Color.pulseBackground)
                .navigationTitle("Activités")
                .toolbar(.hidden, for: .navigationBar)
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
            loaded(activities)
        }
    }

    private func loaded(_ activities: [Activity]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                ActivitiesHeader(count: activities.count)

                if activities.isEmpty {
                    emptyState
                } else {
                    ForEach(groups(of: activities), id: \.key) { group in
                        ActivitiesDayGroup(label: group.label, activities: group.activities)
                    }
                }
            }
            .padding(.horizontal, PulseSpacing.lg)
            .padding(.top, PulseSpacing.sm)
            .padding(.bottom, PulseSpacing.lg)
        }
        .refreshable { await vm.load() }
    }

    private var emptyState: some View {
        VStack(spacing: PulseSpacing.md) {
            Image(systemName: "figure.run.circle")
                .font(.system(size: 40))
                .foregroundStyle(Color.pulseTextSecondary)
            Text("Aucune activité.")
                .font(.system(size: 15))
                .foregroundStyle(Color.pulseTextSecondary)
            Text("Importe des fichiers .FIT depuis Pulse, ou dépose-les dans data/inbox.")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, PulseSpacing.xxl)
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

// MARK: - En-tête

/// Titre + compteur — équivalent maison de `.head`/`.head-id` (maquette,
/// lignes 1039-1041) : titre 24pt semibold tracking -0.24 à gauche, note
/// mono 11pt discrète à droite. La maquette affiche un total hebdomadaire
/// (« cette semaine 4 h 12 »), absent du DOM Angular réel (`ActivitiesComponent`
/// n'agrège pas de durée) — remplacé par le compteur `head-count`/`countNote()`
/// réellement présent côté Angular (« N séances »), rendu avec le même style
/// visuel que la maquette.
private struct ActivitiesHeader: View {
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Activités")
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.24)
                .foregroundStyle(Color.pulseTextPrimary)
            Spacer()
            Text(countLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    private var countLabel: String {
        "\(count) séance\(count > 1 ? "s" : "")"
    }
}

// MARK: - Groupe de jour

/// Étiquette de jour (mono 10pt, tracking .1em, majuscules) + cartes —
/// équivalent `.list-head`/`.lab` + `.row.act` (maquette, lignes 1045-1071).
private struct ActivitiesDayGroup: View {
    let label: String
    let activities: [Activity]

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.sm) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(Color.pulseTextSecondary)

            ForEach(activities) { activity in
                NavigationLink(value: activity.id) {
                    ActivityRow(activity: activity)
                }
                .buttonStyle(ActivityRowButtonStyle())
            }
        }
    }
}

/// Ligne de liste — filet coloré par sport (PAS l'icône ronde du DOM
/// Angular), libellé + heure, valeur unique à droite (distance si connue,
/// sinon durée) — 1-1 avec la maquette, lignes 1047-1054.
private struct ActivityRow: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: PulseSpacing.md) {
            Text(ActivitySport.emoji(sport: activity.sport))
                .font(.system(size: 22))
                .frame(width: 30, height: 30)
                .background(sportTint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(ActivitySport.label(sport: activity.sport, subSport: activity.subSport))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.pulseTextPrimary)
                Text(ActivityDateFormatting.clock(ActivityDateFormatting.date(from: activity.startTime)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(trailingValue)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color.pulseTextPrimary)
        }
        .padding(EdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 14))
        .background(Color.pulseSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.pulseBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Couleur par sport — équivalent `<app-sport-icon>` (Angular) : jamais
    /// l'accent bleu générique, cf. `ActivitySport.color`.
    private var sportTint: Color {
        ActivitySport.color(sport: activity.sport)
    }

    /// Distance si connue, sinon durée — même priorité que les 5 exemples de
    /// la maquette (Marche → distance ; Musculation/Escalade, sans distance →
    /// durée), plus simple que le résumé multi-métriques `summaryOf()`.
    private var trailingValue: String {
        if let distanceM = activity.distanceM, distanceM > 0, let km = ActivityFormat.distanceKm(distanceM) {
            return km
        }
        return ActivityFormat.shortDuration(activity.durationS)
    }
}

/// Pression discrète — pas de highlight système (chevron/fond) puisque la
/// ligne est déjà une carte à elle seule.
private struct ActivityRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

#Preview {
    ActivitiesView()
}
