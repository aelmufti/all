//
//  HealthView.swift
//  all (bridge-connect)
//
//  Écran natif « Santé » — miroir de la page Angular `/health`
//  (`custom-connect/web/src/app/pages/health/health.component.ts`) : FC,
//  stress, SpO2, pas, calories, sommeil, intensité du jour. Consomme
//  `PulseAPIClient.shared` via `HealthViewModel` (jamais `URLSession`
//  directement) et les composants `DesignSystem.swift`.
//
//  Trois états stricts (cf. contrat de l'agent) : chargement (`LoadingView`),
//  erreur (`ErrorView(message:retry:)`), données — les deux premiers seulement
//  tant qu'il n'y a encore rien à afficher : ensuite un rechargement garde le
//  contenu (bandeau d'erreur discret en cas d'échec) et un changement de date
//  montre des emplacements réservés.
//
//  Le poids (saisie, courbe, historique) vit dans l'écran Nutrition — cf.
//  `Screens/Nutrition/NutritionWeightCard.swift`.
//

import SwiftUI

struct HealthView: View {
    @State private var viewModel = HealthViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if !viewModel.hasContent, viewModel.day == nil, let message = viewModel.errorMessage {
                    ErrorView(message: message) {
                        Task { await viewModel.retry() }
                    }
                } else {
                    // Mise en page tout de suite ; les cartes se remplissent à
                    // l'arrivée de leurs données.
                    loaded
                }
            }
            // Titre porté en contenu (24pt, dans `PulseDayPickerHeader`) comme
            // les autres écrans : le grand titre système réservait ~96pt vides
            // au-dessus. Barre masquée.
            .toolbar(.hidden, for: .navigationBar)
            .background(Color.pulseBackground)
        }
        .task {
            await viewModel.reload()
        }
        // Bascule de jour : à minuit local et au retour premier plan, avance au
        // nouveau jour si l'utilisateur est sur le dernier jour connu.
        .refreshesAtDayChange { await viewModel.reloadForNewDay() }
        // Synchro montre en mode Téléphone/Les deux pendant que l'écran est
        // ouvert (cf. `LocalIngestor.ingestIfNeeded`) — même garde-fou que
        // ci-dessus (ne recharge que si l'utilisateur est sur aujourd'hui).
        .reloadsOnLocalDataChange { await viewModel.reloadForNewDay(trailing: true) }
        .reloadsOnStorageModeChange { await viewModel.reload(trailing: true) }
    }

    private var loaded: some View {
        ScrollView {
            VStack(spacing: PulseSpacing.lg) {
                PulseDayPickerHeader(
                    title: "Santé",
                    selected: viewModel.date,
                    range: PulseDayPicker.normalized(
                        lower: PulseDayPicker.defaultLowerBound,
                        upper: max(viewModel.maxDate, viewModel.date)),
                    daysWithData: viewModel.daysWithData
                ) { key in Task { await viewModel.selectDate(key) } }
                if let message = viewModel.errorMessage {
                    DashboardInlineError(message: message) { Task { await viewModel.retry() } }
                }
                if let day = viewModel.day {
                    SleepCard(viewModel: viewModel, sleep: day.sleep)
                    MetricTabPicker(viewModel: viewModel)
                    HealthMetricChartCard(viewModel: viewModel, day: day)
                } else if viewModel.isDayLoading || viewModel.errorMessage == nil {
                    // Premier chargement, ou autre date en cours de chargement : mêmes emplacements que
                    // les cartes du jour, jamais les données de l'ancienne date.
                    PulseSkeletonCard(height: 250)
                    MetricTabPicker(viewModel: viewModel)
                    PulseSkeletonCard(height: 230)
                }
                if viewModel.day != nil || viewModel.isDayLoading || viewModel.errorMessage == nil {
                    IntensityCard(intensity: viewModel.intensity, failed: viewModel.intensityFailed)
                        .pulseSkeleton(viewModel.intensity == nil && !viewModel.intensityFailed)
                }
            }
            .padding(PulseSpacing.lg)
            .pulseReveal(viewModel.day?.date)
            .pulseReveal(viewModel.intensity != nil)
        }
        .pulseTabBarClearance()
        .background(Color.pulseBackground)
    }
}

#Preview {
    HealthView()
}
