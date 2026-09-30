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
//  erreur (`ErrorView(message:retry:)`), données. Le poids (fenêtre 90 jours,
//  indépendante de la date affichée) échoue silencieusement côté vue-modèle
//  plutôt que de bloquer tout l'écran — un exercice pratique de la même règle
//  que `IntensityDayCardComponent` côté Angular (au mieux, jamais bloquant).
//
//  Poids servi en mode Téléphone depuis l'incrément L5 (`docs/stockage-local.md`) :
//  `RealLocalPulseBackend` sert `api/weight` depuis `weight_log` (SQLite
//  locale), la carte n'est donc plus masquée. `push` (statut de transmission
//  vers la montre) reste toujours neutre côté backend local — l'écriture vers
//  la montre passe par `BLEManager.requestWatchWeightWrite`, indépendante du
//  mode de stockage (cf. `HealthViewModel.saveWeight`).
//

import SwiftUI

struct HealthView: View {
    @State private var viewModel = HealthViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if let day = viewModel.day {
                    loaded(day: day)
                } else if let message = viewModel.errorMessage {
                    ErrorView(message: message) {
                        Task { await viewModel.retry() }
                    }
                } else {
                    LoadingView(message: "Chargement de la santé…")
                }
            }
            // Titre porté en contenu (24pt, dans `HealthDayNavigator`) comme
            // les autres écrans : le grand titre système réservait ~96pt vides
            // au-dessus. Barre masquée.
            .toolbar(.hidden, for: .navigationBar)
            .background(Color.pulseBackground)
        }
        .task {
            await viewModel.load()
        }
        // Bascule de jour : à minuit local et au retour premier plan, avance au
        // nouveau jour si l'utilisateur est sur le dernier jour connu.
        .refreshesAtDayChange { await viewModel.reloadForNewDay() }
        // Synchro montre en mode Téléphone/Les deux pendant que l'écran est
        // ouvert (cf. `LocalIngestor.ingestIfNeeded`) — même garde-fou que
        // ci-dessus (ne recharge que si l'utilisateur est sur aujourd'hui).
        .reloadsOnLocalDataChange { await viewModel.reloadForNewDay() }
    }

    private func loaded(day: WellnessDayDetail) -> some View {
        ScrollView {
            VStack(spacing: PulseSpacing.lg) {
                HealthDayNavigator(viewModel: viewModel)
                SleepCard(viewModel: viewModel, sleep: day.sleep)
                MetricTabPicker(viewModel: viewModel)
                HealthMetricChartCard(viewModel: viewModel, day: day)
                IntensityCard(intensity: viewModel.intensity, failed: viewModel.intensityFailed)
                WeightCard(viewModel: viewModel)
            }
            .padding(PulseSpacing.lg)
        }
        .pulseTabBarClearance()
        .background(Color.pulseBackground)
    }
}

#Preview {
    HealthView()
}
