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
    @State private var showBravo = false

    private var domain: ProgrammeDomainView? { viewModel.trainingDomain }

    var body: some View {
        ScrollView {
            if let domain, let active = domain.active, case .training(let detail) = domain.detail {
                VStack(alignment: .leading, spacing: 16) {
                    weekCard(domain: domain, active: active, detail: detail)
                    sessionsCard(domain: domain, detail: detail)
                    calendarCard(domain: domain, detail: detail)
                    if !programmeFinished(domain) {
                        nextRow(detail)
                    }
                    pushRow
                    if programmeFinished(domain) {
                        VStack(spacing: 0) {
                            Button("Relancer un cycle aujourd’hui") {
                                Task { await viewModel.restart(domain) }
                            }
                            .buttonStyle(.programmePrimary)
                            .disabled(viewModel.isBusy)
                            Button("Bilan") { showBravo = true }
                                .buttonStyle(.programmeText)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Color.pulseBackground)
        .navigationTitle(domain?.active?.name ?? "Entraînement")
        .navigationBarTitleDisplayMode(.inline)
        .programmeAbout(kind: .training, viewModel: viewModel)
        .programmeBravoCover(isPresented: $showBravo, viewModel: viewModel)
        .onAppear { viewModel.resetShownWeek() }
        .onChange(of: domain?.active == nil) { _, stopped in if stopped { dismiss() } }
    }

    // MARK: - Semaine : héro, barre du bloc, navigation, focus

    private func weekSessions(_ detail: ProgrammeTrainingDetail) -> [ProgrammeSessionProgress] {
        detail.sessions.filter { $0.week == viewModel.shownWeek }
    }

    private func weekCard(domain: ProgrammeDomainView, active: ProgrammeActive, detail: ProgrammeTrainingDetail) -> some View {
        let sessions = weekSessions(detail)
        return ProgrammeCard {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                ProgrammeBigNumber(value: "\(sessions.filter(\.done).count)", total: "\(sessions.count)")
                Text(viewModel.shownWeek == active.week ? "séances cette semaine" : "séances")
                    .font(.programmeMono(11))
                    .foregroundStyle(Color.pulseTextSecondary)
            }

            if active.weeks > 1 {
                weekSegmentsRow(weeks: active.weeks, detail: detail)
                weekNav(weeks: active.weeks)
            }

            if let focus = detail.focus.first(where: { $0.index == viewModel.shownWeek })?.focus {
                Text(focus)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
    }

    private func weekSegmentsRow(weeks: Int, detail: ProgrammeTrainingDetail) -> some View {
        let segments = programmeWeekSegments(weeks: weeks, sessions: detail.sessions, shownWeek: viewModel.shownWeek)
        return ProgrammeSegmentBar(segments: segments.map { segment in
            let state: ProgrammeSegmentBar.State
            switch segment.state {
            case "done": state = .done
            case "part": state = .part
            default: state = .todo
            }
            return (state: state, current: segment.current)
        })
    }

    /// `‹ SEMAINE N ›`
    private func weekNav(weeks: Int) -> some View {
        HStack {
            Button { viewModel.shownWeek -= 1 } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 32)
            }
            .disabled(viewModel.shownWeek <= 1)
            Spacer()
            ProgrammeLabel("Semaine \(viewModel.shownWeek)")
            Spacer()
            Button { viewModel.shownWeek += 1 } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 32)
            }
            .disabled(viewModel.shownWeek >= weeks)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.pulseTextSecondary)
        .buttonStyle(.plain)
        .opacity(1)
    }

    // MARK: - Séances

    @ViewBuilder
    private func sessionsCard(domain: ProgrammeDomainView, detail: ProgrammeTrainingDetail) -> some View {
        let sessions = weekSessions(detail)
        let extras = programmeWeekExtras(domain: domain, detail: detail, shownWeek: viewModel.shownWeek)
        if !sessions.isEmpty || !extras.isEmpty {
            ProgrammeCard {
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
                            ProgrammeHairline()
                        }
                    }
                    ForEach(extras) { extra in
                        if !sessions.isEmpty || extra.id != extras.first?.id {
                            ProgrammeHairline()
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
        return ProgrammeCard(spacing: 14) {
            HStack(spacing: 5) {
                ForEach(cells) { cell in
                    VStack(spacing: 6) {
                        ProgrammeBlock(fill: blockFill(cell.state))
                            .accessibilityLabel(Text(cell.title))
                        Text(cell.letter)
                            .font(.programmeMono(10, weight: cell.today ? .semibold : .regular))
                            .foregroundStyle(cell.today ? Color.pulseTextPrimary : Color.pulseTextSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 14) {
                ProgrammeLegendItem(label: "prévue", dashed: true)
                ProgrammeLegendItem(label: "faite", color: .pulseTextPrimary)
                ProgrammeLegendItem(label: "en retard", color: .pulseDanger.opacity(0.55))
            }
        }
    }

    private func blockFill(_ state: String) -> ProgrammeBlock.Fill {
        switch state {
        case "done": return .filled
        case "planned": return .planned
        case "extra": return .extra
        case "missed": return .missed
        default: return .empty
        }
    }

    // MARK: - Prochaine + envoi à la montre

    private func nextRow(_ detail: ProgrammeTrainingDetail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ProgrammeLabel("Prochaine", size: 10)
            Text(programmeNextLabel(detail: detail, shownWeek: viewModel.shownWeek))
                .font(.system(size: 13))
                .foregroundStyle(Color.pulseTextSecondary)
        }
        .padding(.horizontal, 2)
    }

    /// Une seule rangée : état de l'envoi + action texte.
    private var pushRow: some View {
        let running = viewModel.pushStatus?.state == "running"
        let status: String
        switch viewModel.pushStatus?.state {
        case "running": status = "Envoi en cours…"
        case "error": status = "Échec de l’envoi"
        default: status = programmePushSummary(filesSent: viewModel.pushFilesSent)
        }
        return ProgrammeCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    ProgrammeLabel("Montre")
                    Text(status)
                        .font(.programmeMono(11))
                        .foregroundStyle(viewModel.pushStatus?.state == "error" ? Color.pulseDanger : Color.pulseTextSecondary)
                }
                Spacer()
                Button {
                    Task { await viewModel.sendToWatch() }
                } label: {
                    Text("Envoyer")
                }
                .buttonStyle(.programmeText)
                .disabled(viewModel.isBusy || running)
            }
        }
    }
}

// MARK: - Ligne hors programme

private struct ProgrammeExtraRow: View {
    let extra: ProgrammeExtraActivity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ActivitySport.icon(sport: extra.sport))
                .font(.system(size: 14))
                .foregroundStyle(Color.pulseTextSecondary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(ActivitySport.name(sport: extra.sport))
                    .font(.system(size: 15))
                    .foregroundStyle(Color.pulseTextSecondary)
                Text(programmeExtraMeta(extra))
                    .font(.programmeMono(11))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
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
            HStack(spacing: 12) {
                if isLocked {
                    ProgrammeCheckbox(checked: true)
                } else {
                    Button(action: onToggleDone) {
                        ProgrammeCheckbox(checked: session.done)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, -11)
                    .disabled(isBusy)
                }

                Button(action: onToggleExpand) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.session.name)
                                .font(.system(size: 15, weight: session.done ? .regular : .medium))
                                .foregroundStyle(session.done ? Color.pulseTextSecondary : Color.pulseTextPrimary)
                            Text(programmeSessionMeta(session))
                                .font(.programmeMono(11))
                                .foregroundStyle(Color.pulseTextSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ProgrammeChevron()
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.session.items, id: \.name) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.system(size: 14))
                                .foregroundStyle(Color.pulseTextPrimary)
                            Text(item.prescription)
                                .font(.programmeMono(11))
                                .foregroundStyle(Color.pulseTextSecondary)
                            if let note = item.note {
                                Text(note)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.pulseTextSecondary)
                            }
                        }
                    }
                }
                .padding(.leading, 34)
                .padding(.bottom, 14)
            }
        }
    }
}
