//
//  DashboardSummaryCard.swift
//  all (bridge-connect)
//
//  Carte de résumé d'un domaine sur l'aperçu Statistiques — glyphe+label en
//  en-tête (badge d'alerte optionnel + chevron), valeur héros + mini-courbe au
//  corps, chip de variation + note secondaire en pied. La navigation elle-même
//  (`NavigationLink(value:)`) est posée par l'appelant (`DashboardView`) : ce
//  composant ne fait qu'afficher un `DashboardDomainSummary`.
//

import SwiftUI

struct DashboardSummaryCard: View {
    let summary: DashboardDomainSummary

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.md) {
            header
            heroRow
            footerRow
        }
        .padding(PulseSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pulseSurface)
        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                .strokeBorder(Color.pulseBorder, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: PulseSpacing.sm) {
            Image(systemName: summary.sfSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(summary.tint)
                .frame(width: 26, height: 26)
                .background(summary.tint.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(summary.title.uppercased())
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(Color.pulseTextSecondary)

            Spacer()

            if let flag = summary.flag {
                DashboardFlagBadge(flag: flag)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    private var heroRow: some View {
        HStack(alignment: .center, spacing: PulseSpacing.md) {
            HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.xs) {
                Text(summary.heroValue)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pulseTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !summary.heroUnit.isEmpty {
                    Text(summary.heroUnit)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }

            Spacer(minLength: PulseSpacing.md)

            DashboardSparkline(values: summary.spark, tint: summary.tint)
                .frame(width: 108, height: 40)
        }
    }

    private var footerRow: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.sm) {
            Rectangle().fill(Color.pulseBorder).frame(height: 1)

            HStack(spacing: PulseSpacing.sm) {
                if let delta = summary.delta {
                    Text(delta.text)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(delta.tone.color)
                }
                Text(summary.footNote)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }
}

/// Pastille d'alerte de l'en-tête de carte — point coloré + texte court, pas
/// de fond plein (contrairement aux badges `.debtLevel`/`.streak` des sections
/// détaillées) : ici c'est un indice discret sur une carte déjà dense.
private struct DashboardFlagBadge: View {
    let flag: DashboardDomainSummary.Flag

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(flag.level.color).frame(width: 6, height: 6)
            Text(flag.text)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(Color.pulseTextSecondary)
                .lineLimit(1)
        }
    }
}
