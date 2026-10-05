//
//  SommeilBedtimeCards.swift
//  all (bridge-connect)
//
//  Cartes d'heure de coucher conseillée de l'écran Sommeil :
//   - « Ce soir » (`SommeilTonightCard`) : fixe, en haut, pour la NUIT À VENIR
//     (indépendante de la date affichée) — heure en grand, réveil prévu utilisé,
//     durée idéale de la nuit quand elle existe ;
//   - « Coucher conseillé pour cette nuit » (`SommeilNightBedtimeCard`) : celle
//     de la date affichée, sans ligne de réveil. Emplacement réservé de même
//     hauteur pendant le chargement (pas de saut de mise en page, jamais l'heure
//     d'une autre date). Le détail du calcul vit dans Paramètres › Aide.
//

import SwiftUI

/// Carte fixe « Ce soir ».
struct SommeilTonightCard: View {
    let card: SommeilViewModel.TonightCard

    var body: some View {
        PulseCard {
            DashboardCardHeader("Ce soir")
            switch card {
            case .placeholder:
                SommeilBedtimeSkeleton(showsWake: true)
            case .unavailable:
                Text("—")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pulseSleep)
            case .plan(let plan):
                Text(plan.bedtime)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pulseSleep)
                Text("Pour te réveiller à \(WakeScheduleStore.hhmm(plan.wakeMinutes))")
                    .font(PulseFont.body)
                    .foregroundStyle(Color.pulseTextPrimary)
                if plan.isNightSpecific {
                    Text("Durée idéale cette nuit : \(SleepBedtimePlan.durationLabel(hours: plan.idealHours))")
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
        }
    }
}

/// Carte par nuit (date affichée). Ne rend rien pour `.hidden`.
struct SommeilNightBedtimeCard: View {
    let card: SommeilViewModel.NightCard

    var body: some View {
        switch card {
        case .hidden:
            EmptyView()
        case .placeholder:
            PulseCard {
                DashboardCardHeader("Coucher conseillé pour cette nuit")
                SommeilBedtimeSkeleton(showsWake: false)
            }
        case .plan(let plan):
            PulseCard {
                DashboardCardHeader("Coucher conseillé pour cette nuit")
                Text(plan.bedtime)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pulseSleep)
                // Toujours une ligne de durée (même hauteur que l'emplacement
                // réservé) : celle de CETTE nuit, sinon l'idéal global.
                Text(plan.isNightSpecific
                     ? "Durée idéale cette nuit : \(SleepBedtimePlan.durationLabel(hours: plan.idealHours))"
                     : "Durée idéale : \(SleepBedtimePlan.durationLabel(hours: plan.idealHours))")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }
}

/// Emplacement réservé : mêmes polices que le contenu, texte factice masqué
/// (`redacted`) → même hauteur que la carte chargée.
private struct SommeilBedtimeSkeleton: View {
    let showsWake: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.md) {
            Text("00:00")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
            if showsWake {
                Text("Pour te réveiller à 00:00")
                    .font(PulseFont.body)
            }
            Text("Durée idéale cette nuit : 0 h 00")
                .font(.footnote)
        }
        .foregroundStyle(Color.pulseTextSecondary)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}
