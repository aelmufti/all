//
//  ProgrammeSleepCard.swift
//  all (bridge-connect)
//
//  Domaine « Sommeil » — hero (critères tenus), frise des nuits, critères
//  détaillés (valeur/cible/état/bande de risque) et notes du programme.
//  Miroir de la section `@if (sleep(d); as s)` du template Angular.
//
//  Simplification assumée (cf. rendu de l'agent) : la frise reprend les
//  nuits (`strip`) sous forme de barres proportionnelles à `sleepMin`,
//  colorées jour travaillé/libre — pas le positionnement horaire précis de
//  l'`<app-actogram>` Angular (axe coucher/lever avec bande ± écart-type),
//  qui demanderait un composant de dessin dédié pour un gain d'information
//  marginal sur cet écran.
//

import SwiftUI

struct ProgrammeSleepSection: View {
    let domain: ProgrammeDomainView
    let detail: ProgrammeSleepDetail

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.md) {
            card
            notesCard
        }
    }

    private var card: some View {
        PulseCard {
            header
            hero

            if !detail.strip.isEmpty {
                strip
                legend
            }

            if let warning = programmeSleepStripWarning(detail) {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            metricsList
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(domain.active?.name ?? domain.label)
                    .font(.subheadline.weight(.semibold))
                Text(domain.active?.source ?? "")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Spacer()
            Text(programmeBadge(domain))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    private var hero: some View {
        HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(detail.nights > 0 ? "\(detail.hits)" : "—")
                    .font(PulseFont.metricValue)
                    .foregroundStyle(detail.nights > 0 ? Color.pulseTextPrimary : Color.pulseTextSecondary)
                Text("/\(detail.total)")
                    .font(.title2)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Text("critères tenus · \(programmeSleepWindowLabel(detail))")
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    private var strip: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(detail.strip) { night in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(night.workDay ? Color.pulseAccent : Color.pulseAccent.opacity(0.4))
                        .frame(height: max(4, CGFloat(night.sleepMin) / 8))
                    Text(ProgrammeDate.weekdayLetters[max(0, min(6, night.weekday))])
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("\(night.date) · \(programmeSleepDuration(night.sleepMin))"))
            }
        }
        .frame(height: 70, alignment: .bottom)
    }

    private var legend: some View {
        HStack(spacing: PulseSpacing.md) {
            ProgrammeLegendDot(color: .pulseAccent, label: "avant un jour travaillé")
            ProgrammeLegendDot(color: .pulseAccent.opacity(0.4), label: "avant un jour libre")
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private var metricsList: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.md) {
            ForEach(detail.metrics) { metric in
                ProgrammeSleepMetricRow(metric: metric)
            }
        }
        .padding(.top, PulseSpacing.xs)
    }

    private var notesCard: some View {
        PulseCard {
            SectionHeader("Ce que dit le papier") {
                Text("\(detail.metrics.count) critères")
                    .font(.caption2)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            ForEach(domain.active?.notes ?? [], id: \.self) { note in
                Text(note).font(.footnote)
            }
            Text(programmeWorkDaysLabel(domain))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

private struct ProgrammeSleepMetricRow: View {
    let metric: ProgrammeSleepMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline) {
                Text(metric.label).font(.subheadline.weight(.semibold))
                Spacer()
                Text(programmeSleepValueText(metric))
                    .font(.system(.body, design: .monospaced)).fontWeight(.semibold)
            }

            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let span = metric.scale.max - metric.scale.min
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.pulseSurfaceAlt)
                    if span > 0, let value = metric.value {
                        let ratio = min(max((value - metric.scale.min) / span, 0), 1)
                        Circle()
                            .fill(programmeSleepMarkerColor(metric))
                            .frame(width: 10, height: 10)
                            .offset(x: width * CGFloat(ratio) - 5)
                    }
                }
            }
            .frame(height: 10)

            HStack(spacing: 6) {
                if !metric.informative {
                    Circle().fill(programmeSleepMarkerColor(metric)).frame(width: 7, height: 7)
                }
                Text(programmeSleepStateText(metric))
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                Text(programmeSleepTargetText(metric))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            if !metric.informative, let band = metric.band {
                Text("\(band.label) · \(band.risk)")
                    .font(.caption2)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            if let note = metric.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }
}
