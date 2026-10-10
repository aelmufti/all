//
//  ProgrammeTrainingCard.swift
//  all (bridge-connect)
//
//  Domaine « Entraînement » — carte de la semaine affichée (hero, frise
//  multi-semaines, focus, liste des séances, calendrier de la semaine),
//  ligne « Prochaine » et carte d'envoi à la montre. Miroir de la section
//  `@if (training(d); as t)` du template Angular.
//

import SwiftUI

struct ProgrammeTrainingSection: View {
    let domain: ProgrammeDomainView
    let detail: ProgrammeTrainingDetail
    var viewModel: ProgrammeViewModel

    @State private var expandedKey: String?

    private var weekSessions: [ProgrammeSessionProgress] {
        detail.sessions.filter { $0.week == viewModel.shownWeek }
    }

    /// Activités hors programme de la semaine affichée.
    private var weekExtras: [ProgrammeExtraActivity] {
        programmeWeekExtras(domain: domain, detail: detail, shownWeek: viewModel.shownWeek)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.md) {
            trainingCard
            nextRow
            pushCard
            notesCard
        }
    }

    // MARK: - Carte principale

    private var trainingCard: some View {
        PulseCard {
            header
            hero

            let weeks = domain.active?.weeks ?? 0
            if weeks > 1 {
                weekSegmentsRow(weeks: weeks)
            }

            if let focus = detail.focus.first(where: { $0.index == viewModel.shownWeek })?.focus {
                Text(focus)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            sessionsList

            dayGrid
            dayLegend

            if weeks > 1 {
                weekPicker(weeks: weeks)
            }

            if programmeFinished(domain), let active = domain.active {
                restartRow(active: active)
            }
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
                .foregroundStyle(programmeFinished(domain) ? Color.pulseAccent : Color.pulseTextSecondary)
        }
    }

    private var hero: some View {
        HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                // Web `.hero-n { font-size:44px; font-weight:600 }` — plus
                // grand que `PulseFont.metricValue` (36), gardé ici tel quel.
                Text("\(weekSessions.filter(\.done).count)")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                // `.hero-of` hérite la famille mono + le poids 600 de `.hero-n`
                // (pas de reset dans le SCSS), seule la taille (22px) change.
                Text("/\(weekSessions.count)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Text(heroLabel)
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    private var heroLabel: String {
        let activeWeek = domain.active?.week ?? 0
        return viewModel.shownWeek == activeWeek ? "séances cette semaine" : "séances · semaine \(viewModel.shownWeek)"
    }

    private func weekSegmentsRow(weeks: Int) -> some View {
        let segments = programmeWeekSegments(weeks: weeks, sessions: detail.sessions, shownWeek: viewModel.shownWeek)
        return HStack(spacing: 4) {
            ForEach(segments) { segment in
                RoundedRectangle(cornerRadius: 3)
                    .fill(programmeSegmentColor(segment.state))
                    .frame(height: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(segment.current ? Color.pulseTextPrimary : Color.clear, lineWidth: 1)
                    )
            }
        }
    }

    private func programmeSegmentColor(_ state: String) -> Color {
        switch state {
        case "done": return .pulseSuccess
        case "part": return .pulseSuccess.opacity(0.45)
        default: return .pulseSurfaceAlt
        }
    }

    // MARK: - Séances

    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(weekSessions.enumerated()), id: \.element.id) { index, session in
                ProgrammeSessionRow(
                    session: session,
                    isExpanded: expandedKey == session.session.key,
                    isBusy: viewModel.isBusy,
                    onToggleExpand: {
                        expandedKey = expandedKey == session.session.key ? nil : session.session.key
                    },
                    onToggleDone: {
                        Task { await viewModel.toggleSession(session) }
                    }
                )
                if index < weekSessions.count - 1 {
                    Divider()
                }
            }
            ForEach(weekExtras) { extra in
                if !weekSessions.isEmpty || extra.id != weekExtras.first?.id {
                    Divider()
                }
                ProgrammeExtraRow(extra: extra)
            }
        }
    }

    // MARK: - Calendrier de la semaine

    private var dayGrid: some View {
        let cells = programmeWeekDays(domain: domain, detail: detail, shownWeek: viewModel.shownWeek)
        // Web `.days { gap:6px }`, `.dcell { gap:5px }`.
        return HStack(spacing: 6) {
            ForEach(cells) { cell in
                VStack(spacing: 5) {
                    // Web `.dbox { height:26px; border-radius:7px }`.
                    RoundedRectangle(cornerRadius: 7)
                        .fill(programmeDayColor(cell.state))
                        .frame(height: 26)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(cell.state == "missed" ? Color.pulseDanger.opacity(0.55) : Color.clear, lineWidth: 1)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(cell.today ? Color.pulseTextSecondary : Color.clear, style: StrokeStyle(lineWidth: 1, dash: [2]))
                        )
                        .accessibilityLabel(Text(cell.title))
                    Text(cell.letter)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func programmeDayColor(_ state: String) -> Color {
        switch state {
        case "done": return .pulseTextPrimary
        case "planned": return .pulseTextSecondary.opacity(0.34)
        case "extra": return .pulseSteps.opacity(0.55)
        // Web `.dbox.missed { background:none; border:1px solid … }` — pas de
        // remplissage, seul le liseré (posé par l'overlay ci-dessus) marque
        // l'état.
        case "missed": return .clear
        default: return .pulseSurfaceAlt
        }
    }

    // Web `.dlegend { gap:6px 14px }`, `.dlg { font-size:11px }` — 4 puces
    // (prévue/faite/en retard/aujourd'hui), la dernière manquait ici.
    private var dayLegend: some View {
        HStack(spacing: 14) {
            ProgrammeLegendDot(color: .pulseTextSecondary.opacity(0.34), label: "prévue")
            ProgrammeLegendDot(color: .pulseTextPrimary, label: "faite")
            ProgrammeLegendDot(color: .pulseDanger.opacity(0.55), label: "en retard", outlined: true)
            if !weekExtras.isEmpty {
                ProgrammeLegendDot(color: .pulseSteps.opacity(0.55), label: "hors programme")
            }
            ProgrammeLegendDot(color: .pulseTextSecondary, label: "aujourd’hui", dashed: true)
        }
        .font(.system(size: 11, design: .rounded))
    }

    /// `<app-seg variant="track">` — piste `--surface-2` (pas de défilement :
    /// les segments se répartissent à parts égales, `flex:1` côté web), pilule
    /// sélectionnée `--surface` + liseré + texte plein, non sélectionnée sans
    /// fond ni liseré. Web `.seg.track { gap:3px; padding:3px; border-radius:11px }`,
    /// `.seg.track .item { height:34px; border-radius:8px; font-size:12px }`.
    private func weekPicker(weeks: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(1...weeks, id: \.self) { index in
                let selected = index == viewModel.shownWeek
                Button {
                    viewModel.shownWeek = index
                } label: {
                    Text("S\(index)")
                        .font(.system(size: 12, weight: selected ? .semibold : .regular, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(selected ? Color.pulseSurface : Color.clear)
                        .foregroundStyle(selected ? Color.pulseTextPrimary : Color.pulseTextSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(selected ? Color.pulseBorder : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.pulseSurfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func restartRow(active: ProgrammeActive) -> some View {
        VStack(alignment: .leading, spacing: PulseSpacing.sm) {
            Divider()
            Text("\(detail.done) séances sur \(detail.total) pointées sur les \(active.weeks) semaines.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color.pulseTextSecondary)
            Button("Relancer un cycle aujourd’hui") {
                Task { await viewModel.restart(domain) }
            }
            .buttonStyle(.pulseSecondary)
            .disabled(viewModel.isBusy)
        }
    }

    // MARK: - Ligne « Prochaine » + carte d'envoi

    private var nextRow: some View {
        // Web `.lab { letter-spacing:.12em; text-transform:uppercase }`,
        // `.next { gap:10px; padding:0 2px }`.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Prochaine")
                .font(.system(size: 11, design: .rounded))
                .tracking(1.3)
                .textCase(.uppercase)
                .foregroundStyle(Color.pulseTextSecondary)
            Text(programmeNextLabel(detail: detail, shownWeek: viewModel.shownWeek))
                .font(.footnote)
                .foregroundStyle(Color.pulseTextPrimary)
        }
        .padding(.horizontal, 2)
    }

    private var pushCard: some View {
        PulseCard {
            HStack(alignment: .firstTextBaseline) {
                Text("Séances sur la montre")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
                Spacer()
                Text(programmePushSummary(filesSent: viewModel.pushFilesSent))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Button {
                Task { await viewModel.sendToWatch() }
            } label: {
                Text(viewModel.pushStatus?.state == "running" ? "Envoi en cours…" : "Envoyer à la montre")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pulseSecondary)
            .disabled(viewModel.isBusy || viewModel.pushStatus?.state == "running")
            Text(programmePushHint(status: viewModel.pushStatus))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color.pulseTextSecondary)
        }
    }

    /// « À retenir » — équivalent `@if (training(d)) { <app-panel title="À
    /// retenir" [summary]="d.active.goal"> … </app-panel> }`, simplifié en
    /// carte toujours dépliée (même parti pris que `app-panel` ailleurs dans
    /// cet écran, cf. `ProgrammeNutritionCard`/`notesCard` sommeil).
    private var notesCard: some View {
        PulseCard {
            HStack(alignment: .firstTextBaseline) {
                Text("À retenir")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(domain.active?.goal ?? "")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            ForEach(domain.active?.notes ?? [], id: \.self) { note in
                Text(note).font(.system(size: 14))
            }
        }
    }
}

// MARK: - Ligne hors programme

private struct ProgrammeExtraRow: View {
    let extra: ProgrammeExtraActivity

    var body: some View {
        HStack(spacing: PulseSpacing.sm) {
            Image(systemName: ActivitySport.icon(sport: extra.sport))
                .font(.title3)
                .foregroundStyle(Color.pulseTextSecondary)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(ActivitySport.name(sport: extra.sport))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.pulseTextSecondary)
                Text(programmeExtraMeta(extra))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, PulseSpacing.xs)
    }
}

// MARK: - Ligne de séance

private struct ProgrammeSessionRow: View {
    let session: ProgrammeSessionProgress
    let isExpanded: Bool
    let isBusy: Bool
    let onToggleExpand: () -> Void
    let onToggleDone: () -> Void

    /// Verrouillée quand la séance vient de l'appariement automatique
    /// (`done && !manual`) — même règle que `s.done && !s.manual` (Angular).
    private var isLocked: Bool { session.done && !session.manual }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PulseSpacing.sm) {
                Group {
                    if isLocked {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.pulseSuccess)
                    } else {
                        Button(action: onToggleDone) {
                            Image(systemName: session.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(session.done ? Color.pulseSuccess : Color.pulseTextSecondary)
                        }
                        .disabled(isBusy)
                    }
                }
                .font(.title3)
                // Web `.tick { width:38px; height:38px }` (programme.component.ts).
                .frame(width: 38, height: 38)

                Button(action: onToggleExpand) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.session.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(session.done ? Color.pulseTextSecondary : Color.pulseTextPrimary)
                        Text(programmeSessionMeta(session))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                // Web `.chev { color:var(--absent); font-size:17px }`,
                // `.chev.on { color:var(--accent) }`.
                Image(systemName: "chevron.right")
                    .font(.system(size: 17))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(isExpanded ? Color.pulseAccent : Color.pulseAbsent)
            }
            .padding(.vertical, PulseSpacing.xs)

            if isExpanded {
                // Web `.items { padding:0 0 12px 48px }`, `.it-name { font-size:14px }`,
                // `.it-note { font-size:12px }`.
                VStack(alignment: .leading, spacing: PulseSpacing.sm) {
                    ForEach(session.session.items, id: \.name) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.system(size: 14))
                            Text(item.prescription)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Color.pulseTextSecondary)
                            if let note = item.note {
                                Text(note)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.pulseTextSecondary)
                            }
                        }
                    }
                }
                .padding(.leading, 48)
                .padding(.bottom, PulseSpacing.sm)
            }
        }
    }
}
