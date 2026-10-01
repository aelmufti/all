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
                ProgrammeWarnBox(text: warning)
            }

            metricsList
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(domain.active?.name ?? domain.label)
                    // Web `.prog-name { font-size:17px; font-weight:600 }`.
                    .font(.system(size: 17, weight: .semibold))
                Text(domain.active?.source ?? "")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Spacer()
            Text(programmeBadge(domain))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    private var hero: some View {
        // Web `.hero-n { font-size:44px; font-weight:600 }` — `.hero-of`
        // hérite famille mono + poids 600, seule la taille (22px) change.
        HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(detail.nights > 0 ? "\(detail.hits)" : "—")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(detail.nights > 0 ? Color.pulseTextPrimary : Color.pulseAbsent)
                Text("/\(detail.total)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
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
                        .fill(night.workDay ? Color.pulseSleep : Color.pulseSleep.opacity(0.42))
                        .frame(height: max(4, CGFloat(night.sleepMin) / 8))
                    Text(ProgrammeDate.weekdayLetters[max(0, min(6, night.weekday))])
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("\(night.date) · \(programmeSleepDuration(night.sleepMin))"))
            }
        }
        .frame(height: 70, alignment: .bottom)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ProgrammeLegendDot(color: .pulseSleep, label: "avant un jour travaillé")
            ProgrammeLegendDot(color: .pulseSleep.opacity(0.42), label: "avant un jour libre")
        }
        .font(.system(size: 11, design: .rounded))
    }

    // Web `.metrics { gap:14px }`.
    private var metricsList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(detail.metrics) { metric in
                ProgrammeSleepMetricRow(metric: metric)
            }
        }
        .padding(.top, PulseSpacing.xs)
    }

    /// « Ce que dit le papier » — `<app-panel title="…" [summary]="N critères">`,
    /// simplifié en carte toujours dépliée (même parti pris que la carte
    /// alimentation). Reprend aussi le bloc `.evid` (label · détail + preuve
    /// par critère), absent jusqu'ici.
    private var notesCard: some View {
        PulseCard {
            HStack(alignment: .firstTextBaseline) {
                Text("Ce que dit le papier")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(detail.metrics.count) critères")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            ForEach(domain.active?.notes ?? [], id: \.self) { note in
                Text(note).font(.system(size: 14))
            }

            // Web `.evid { gap:10px; padding-top:10px; border-top:1px solid var(--line) }`,
            // `.ev-name { font-size:13px; font-weight:600 }`,
            // `.ev-txt { font-size:12px; line-height:1.6 }`.
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                ForEach(detail.metrics) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(metric.label) · \(metric.detail)")
                            .font(.system(size: 13, weight: .semibold))
                        Text(metric.evidence)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                }
            }

            Text(programmeWorkDaysLabel(domain))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

private struct ProgrammeSleepMetricRow: View {
    let metric: ProgrammeSleepMetric

    var body: some View {
        // Web `.met.info { padding-top:12px; border-top:1px solid var(--line) }`
        // — sépare les critères descriptifs (sans cible) des critères notés.
        VStack(alignment: .leading, spacing: 0) {
            if metric.informative {
                Divider()
                Spacer().frame(height: PulseSpacing.md)
            }
            content
        }
    }

    // Web `.met { gap:6px }`, `.met-name { font-size:15px; font-weight:600 }`,
    // `.met-val { font-family:mono; font-size:19px; font-weight:600 }`.
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .lastTextBaseline) {
                Text(metric.label).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(programmeSleepValueText(metric))
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
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
                    .font(.system(size: 11, design: .rounded))
                Spacer()
                Text(programmeSleepTargetText(metric))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            // Web `.met-note { font-size:12px; line-height:1.5 }`.
            if !metric.informative, let band = metric.band {
                Text("\(band.label) · \(band.risk)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            if let note = metric.note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }
}
