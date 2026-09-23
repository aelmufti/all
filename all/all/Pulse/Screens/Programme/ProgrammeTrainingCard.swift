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

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.md) {
            trainingCard
            nextRow
            pushCard
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
                    .font(.subheadline.weight(.semibold))
                Text(domain.active?.source ?? "")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Spacer()
            Text(programmeBadge(domain))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(programmeFinished(domain) ? Color.pulseAccent : Color.pulseTextSecondary)
        }
    }

    private var hero: some View {
        HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text("\(weekSessions.filter(\.done).count)")
                    .font(PulseFont.metricValue)
                Text("/\(weekSessions.count)")
                    .font(.title2)
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
        }
    }

    // MARK: - Calendrier de la semaine

    private var dayGrid: some View {
        let cells = programmeWeekDays(domain: domain, detail: detail, shownWeek: viewModel.shownWeek)
        return HStack(spacing: PulseSpacing.xs) {
            ForEach(cells) { cell in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 6)
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
                        .font(.system(size: 10, design: .monospaced))
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
        default: return .pulseSurfaceAlt
        }
    }

    private var dayLegend: some View {
        HStack(spacing: PulseSpacing.md) {
            ProgrammeLegendDot(color: .pulseTextSecondary.opacity(0.34), label: "prévue")
            ProgrammeLegendDot(color: .pulseTextPrimary, label: "faite")
            ProgrammeLegendDot(color: .pulseDanger.opacity(0.55), label: "en retard")
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private func weekPicker(weeks: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PulseSpacing.xs) {
                ForEach(1...weeks, id: \.self) { index in
                    let selected = index == viewModel.shownWeek
                    Button {
                        viewModel.shownWeek = index
                    } label: {
                        Text("S\(index)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, PulseSpacing.sm)
                            .padding(.vertical, 6)
                            .background(selected ? Color.pulseTextPrimary : Color.pulseSurfaceAlt)
                            .foregroundStyle(selected ? Color.pulseSurface : Color.pulseTextSecondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func restartRow(active: ProgrammeActive) -> some View {
        VStack(alignment: .leading, spacing: PulseSpacing.sm) {
            Divider()
            Text("\(detail.done) séances sur \(detail.total) pointées sur les \(active.weeks) semaines.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
            Button("Relancer un cycle aujourd’hui") {
                Task { await viewModel.restart(domain) }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy)
        }
    }

    // MARK: - Ligne « Prochaine » + carte d'envoi

    private var nextRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: PulseSpacing.sm) {
            Text("Prochaine")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
            Text(programmeNextLabel(detail: detail, shownWeek: viewModel.shownWeek))
                .font(.footnote)
                .foregroundStyle(Color.pulseTextPrimary)
        }
        .padding(.horizontal, PulseSpacing.xs)
    }

    private var pushCard: some View {
        PulseCard {
            HStack(alignment: .firstTextBaseline) {
                Text("Séances sur la montre")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.pulseTextSecondary)
                Spacer()
                Text(programmePushSummary(filesSent: viewModel.pushFilesSent))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Button {
                Task { await viewModel.sendToWatch() }
            } label: {
                Text(viewModel.pushStatus?.state == "running" ? "Envoi en cours…" : "Envoyer à la montre")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy || viewModel.pushStatus?.state == "running")
            Text(programmePushHint(status: viewModel.pushStatus))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.pulseTextSecondary)
        }
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
                .frame(width: 32, height: 32)

                Button(action: onToggleExpand) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.session.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(session.done ? Color.pulseTextSecondary : Color.pulseTextPrimary)
                        Text(programmeSessionMeta(session))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(isExpanded ? Color.pulseAccent : Color.pulseTextSecondary)
            }
            .padding(.vertical, PulseSpacing.xs)

            if isExpanded {
                VStack(alignment: .leading, spacing: PulseSpacing.sm) {
                    ForEach(session.session.items, id: \.name) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.subheadline)
                            Text(item.prescription)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.pulseTextSecondary)
                            if let note = item.note {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(Color.pulseTextSecondary)
                            }
                        }
                    }
                }
                .padding(.leading, 40)
                .padding(.bottom, PulseSpacing.sm)
            }
        }
    }
}
