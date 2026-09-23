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
            .navigationTitle("Santé")
            .navigationBarTitleDisplayMode(.large)
            .background(Color.pulseBackground)
        }
        .task {
            await viewModel.load()
        }
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
        .background(Color.pulseBackground)
    }
}

#Preview {
    HealthView()
}
