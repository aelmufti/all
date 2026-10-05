//
//  SommeilBedtimeCards.swift
//  all (bridge-connect)
//
//  Carte d'heure de coucher conseillée de l'écran Sommeil : « Ce soir »
//  (`SommeilTonightCard`), fixe, en haut, pour la NUIT À VENIR (indépendante de
//  la date affichée) — heure en grand, réveil prévu utilisé, durée idéale de la
//  nuit quand elle existe. La reco d'une nuit PASSÉE n'est plus une carte : c'est
//  une ligne de la carte NUIT (`SommeilNightCard`, dans `SommeilView.swift`).
//  Le détail du calcul vit dans Paramètres › Aide.
//

import SwiftUI

/// Carte fixe « Ce soir ».
struct SommeilTonightCard: View {
    let card: SommeilViewModel.BedtimeCard

    var body: some View {
        PulseCard {
            DashboardCardHeader(card.title)
            switch card.state {
            case .placeholder:
                SommeilBedtimeSkeleton()
            case .unavailable:
                Text("—")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pulseSleep)
            case .plan(let plan):
                Text(plan.bedtime)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pulseSleep)
                if card.showsWake {
                    Text("Pour te réveiller à \(WakeScheduleStore.hhmm(plan.wakeMinutes))")
                        .font(PulseFont.body)
                        .foregroundStyle(Color.pulseTextPrimary)
                }
                if plan.isNightSpecific {
                    Text("Durée idéale cette nuit : \(SleepBedtimePlan.durationLabel(hours: plan.idealHours))")
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
        }
    }
}

/// Emplacement réservé : mêmes polices que le contenu, texte factice masqué
/// (`redacted`) → même hauteur que la carte chargée.
private struct SommeilBedtimeSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.md) {
            Text("00:00")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
            Text("Pour te réveiller à 00:00")
                .font(PulseFont.body)
            Text("Durée idéale cette nuit : 0 h 00")
                .font(.footnote)
        }
        .foregroundStyle(Color.pulseTextSecondary)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}
