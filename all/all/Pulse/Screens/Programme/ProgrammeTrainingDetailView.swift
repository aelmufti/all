//
//  ProgrammeTrainingDetailView.swift
//  all (bridge-connect)
//
//  Détail « Entraînement » — héro de la semaine affichée + barre du bloc,
//  navigation de semaine, séances (dépliables), calendrier 7 jours, ligne
//  « Prochaine », envoi à la montre et relance en fin de bloc. Focus
//  semaine par semaine et notes sont dans la fiche « À propos ».
//

import SwiftUI

struct ProgrammeTrainingDetailView: View {
    var viewModel: ProgrammeViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var expandedKey: String?

    private var domain: ProgrammeDomainView? { viewModel.trainingDomain }

    var body: some View {
        ScrollView {
            if let domain, let active = domain.active, case .training(let detail) = domain.detail {
                VStack(alignment: .leading, spacing: PulseSpacing.md) {
                    weekCard(domain: domain, active: active, detail: detail)
                    sessionsCard(domain: domain, detail: detail)
                    calendarCard(domain: domain, detail: detail)
                    if !programmeFinished(domain) {
                        nextRow(detail)
                    }
                    pushRow
                    if programmeFinished(domain) {
                        Button("Relancer un cycle aujourd’hui") {
                            Task { await viewModel.restart(domain) }
                        }
                        .buttonStyle(.pulseSecondary)
                        .disabled(viewModel.isBusy)
                    }
                }
                .padding(PulseSpacing.lg)
            }
        }
        .background(Color.pulseBackground)
        .navigationTitle(domain?.active?.name ?? "Entraînement")
        .navigationBarTitleDisplayMode(.inline)
        .programmeAbout(kind: .training, viewModel: viewModel)
        .onAppear { viewModel.resetShownWeek() }
        .onChange(of: domain?.active == nil) { _, stopped in if stopped { dismiss() } }
    }

    // MARK: - Semaine : héro, barre du bloc, navigation, focus

    private func weekSessions(_ detail: ProgrammeTrainingDetail) -> [ProgrammeSessionProgress] {
        detail.sessions.filter { $0.week == viewModel.shownWeek }
    }

    private func weekCard(domain: ProgrammeDomainView, active: ProgrammeActive, detail: ProgrammeTrainingDetail) -> some View {
        let sessions = weekSessions(detail)
        return PulseCard {
            HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.sm) {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(sessions.filter(\.done).count)")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                    Text("/\(sessions.count)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
                Text(viewModel.shownWeek == active.week ? "séances cette semaine" : "séances")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            if active.weeks > 1 {
                weekSegmentsRow(weeks: active.weeks, detail: detail)
                weekNav(weeks: active.weeks)
            }

            if let focus = detail.focus.first(where: { $0.index == viewModel.shownWeek })?.focus {
                Text(focus)
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }

    private func weekSegmentsRow(weeks: Int, detail: ProgrammeTrainingDetail) -> some View {
        let segments = programmeWeekSegments(weeks: weeks, sessions: detail.sessions, shownWeek: viewModel.shownWeek)
        return HStack(spacing: 4) {
            ForEach(segments) { segment in
                RoundedRectangle(cornerRadius: 3)
                    .fill(segmentColor(segment.state))
                    .frame(height: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(segment.current ? Color.pulseTextPrimary : Color.clear, lineWidth: 1)
                    )
            }
        }
    }

    private func segmentColor(_ state: String) -> Color {
        switch state {
        case "done": return .pulseSuccess
        case "part": return .pulseSuccess.opacity(0.45)
        default: return .pulseSurfaceAlt
        }
    }

    /// `‹ Semaine N ›`
    private func weekNav(weeks: Int) -> some View {
        HStack {
            Button { viewModel.shownWeek -= 1 } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 32)
            }
            .disabled(viewModel.shownWeek <= 1)
            Spacer()
            Text("Semaine \(viewModel.shownWeek)")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button { viewModel.shownWeek += 1 } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 32)
            }
            .disabled(viewModel.shownWeek >= weeks)
        }
        .tint(Color.pulseAccent)
    }

    // MARK: - Séances

    @ViewBuilder
    private func sessionsCard(domain: ProgrammeDomainView, detail: ProgrammeTrainingDetail) -> some View {
        let sessions = weekSessions(detail)
        let extras = programmeWeekExtras(domain: domain, detail: detail, shownWeek: viewModel.shownWeek)
        if !sessions.isEmpty || !extras.isEmpty {
            PulseCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
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
                        if index < sessions.count - 1 {
                            Divider()
                        }
                    }
                    ForEach(extras) { extra in
                        if !sessions.isEmpty || extra.id != extras.first?.id {
                            Divider()
                        }
                        ProgrammeExtraRow(extra: extra)
                    }
                }
            }
        }
    }

    // MARK: - Calendrier de la semaine

    private func calendarCard(domain: ProgrammeDomainView, detail: ProgrammeTrainingDetail) -> some View {
        let cells = programmeWeekDays(domain: domain, detail: detail, shownWeek: viewModel.shownWeek)
        return PulseCard {
            HStack(spacing: 6) {
                ForEach(cells) { cell in
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(dayColor(cell.state))
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
            HStack(spacing: 14) {
                ProgrammeLegendDot(color: .pulseTextSecondary.opacity(0.34), label: "prévue")
                ProgrammeLegendDot(color: .pulseTextPrimary, label: "faite")
                ProgrammeLegendDot(color: .pulseDanger.opacity(0.55), label: "en retard", outlined: true)
            }
            .font(.system(size: 11, design: .rounded))
        }
    }

    private func dayColor(_ state: String) -> Color {
        switch state {
        case "done": return .pulseTextPrimary
        case "planned": return .pulseTextSecondary.opacity(0.34)
        case "extra": return .pulseSteps.opacity(0.55)
        // « En retard » : pas de remplissage, seul le liseré marque l'état.
        case "missed": return .clear
        default: return .pulseSurfaceAlt
        }
    }

    // MARK: - Prochaine + envoi à la montre

    private func nextRow(_ detail: ProgrammeTrainingDetail) -> some View {
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

    /// Une seule rangée : état de l'envoi + bouton.
    private var pushRow: some View {
        let running = viewModel.pushStatus?.state == "running"
        let status: String
        switch viewModel.pushStatus?.state {
        case "running": status = "Envoi en cours…"
        case "error": status = "Échec de l’envoi"
        default: status = programmePushSummary(filesSent: viewModel.pushFilesSent)
        }
        return PulseCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Montre").font(.subheadline.weight(.semibold))
                    Text(status)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(viewModel.pushStatus?.state == "error" ? Color.pulseDanger : Color.pulseTextSecondary)
                }
                Spacer()
                Button {
                    Task { await viewModel.sendToWatch() }
                } label: {
                    Text("Envoyer")
                }
                .buttonStyle(PulseButtonStyle(kind: .secondary, fullWidth: false))
                .disabled(viewModel.isBusy || running)
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

                Image(systemName: "chevron.right")
                    .font(.system(size: 17))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(isExpanded ? Color.pulseAccent : Color.pulseAbsent)
            }
            .padding(.vertical, PulseSpacing.xs)

            if isExpanded {
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
