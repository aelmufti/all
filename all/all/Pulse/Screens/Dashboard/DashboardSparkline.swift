//
//  DashboardSparkline.swift
//  all (bridge-connect)
//
//  Mini-courbe de tendance pour `DashboardSummaryCard` — une forme, pas un
//  graphe de lecture précise : axes/grille/légende masqués. Taille fixée par
//  l'appelant (`.frame(...)` au site d'appel), ce composant ne s'impose aucune
//  dimension.
//

import Charts
import SwiftUI

struct DashboardSparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        if values.count < 2 {
            // Pas assez de points pour dessiner une forme — espace vide plutôt
            // qu'une ligne plate trompeuse ou un graphe qui plante.
            Color.clear
        } else {
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Index", index),
                        y: .value("Valeur", value)
                    )
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Index", index),
                        y: .value("Valeur", value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [tint.opacity(0.28), tint.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }

                if let lastIndex = values.indices.last {
                    PointMark(
                        x: .value("Index", lastIndex),
                        y: .value("Valeur", values[lastIndex])
                    )
                    .foregroundStyle(tint)
                    .symbol(.circle)
                    .symbolSize(14)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .background(Color.clear)
        }
    }
}
