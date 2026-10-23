//
//  RecordsView.swift
//  all (bridge-connect)
//
//  Page « Records » de l'onglet Stats — poussée depuis la ligne Records de
//  `DashboardView`. Filtre sport en haut, puis Séances (dépend du filtre),
//  Journées, Sommeil, Séries. Un record absent reste une ligne avec un tiret.
//

import SwiftUI

struct RecordsView: View {
    @State private var viewModel = RecordsViewModel()

    var body: some View {
        Group {
            if let payload = viewModel.payload {
                content(payload)
            } else {
                switch viewModel.state {
                case .loading, .loaded:
                    PulseSkeletonScreen(header: 0, cards: [64, 190, 150, 150, 120])
                        .pulseTabBarClearance()
                case .failed(let message):
                    ErrorView(message: message) { viewModel.retry() }
                }
            }
        }
        .background(Color.pulseBackground)
        .navigationTitle("Records")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Int.self) { id in
            ActivityDetailView(activityId: id)
        }
        .task { await viewModel.loadIfNeeded() }
        .reloadsOnLocalDataChange { await viewModel.reload(trailing: true) }
        .reloadsOnStorageModeChange { await viewModel.reload(trailing: true) }
    }

    private func content(_ payload: RecordsPayload) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseSpacing.lg) {
                if case .failed(let message) = viewModel.state {
                    DashboardInlineError(message: message) { viewModel.retry() }
                }
                if !payload.sports.isEmpty {
                    RecordsSportTrack(
                        sports: payload.sports, selection: viewModel.sport
                    ) { viewModel.selectSport($0) }
                }
                sessionsSection
                daysSection(payload.days)
                sleepSection(payload.sleep)
                streaksSection(payload.streaks)
            }
            .padding(PulseSpacing.lg)
        }
        .pulseTabBarClearance()
        .refreshable { await viewModel.reload() }
    }

    // MARK: Sections

    private var sessionsSection: some View {
        let s = viewModel.sessions
        let showSport = viewModel.sport == nil
        return RecordsSection(title: "Séances") {
            activityRow("Plus longue sortie", s?.longestDistance, showSport: showSport) {
                ActivityFormat.distanceKm($0) ?? "—"
            }
            activityRow("Plus longue séance", s?.longestDuration, showSport: showSport) {
                ActivityFormat.duration($0)
            }
            activityRow("Meilleure allure", s?.bestPace, showSport: showSport) {
                ActivityFormat.paceSecPerKm($0)
            }
            activityRow("Plus de calories", s?.mostCalories, showSport: showSport, tint: .pulseCalories) {
                "\(Int($0.rounded())) kcal"
            }
            activityRow("Pic de FC", s?.maxHr, showSport: showSport, tint: .pulseHR) {
                "\(Int($0.rounded())) bpm"
            }
            activityRow("FC moyenne la plus haute", s?.highestAvgHr, showSport: showSport, tint: .pulseHR) {
                "\(Int($0.rounded())) bpm"
            }
        }
    }

    private func daysSection(_ days: RecordsDays) -> some View {
        RecordsSection(title: "Journées") {
            dayRow("Plus de pas", days.mostSteps, tint: .pulseSteps) {
                "\(recordsThousandsFormatter.string(from: NSNumber(value: Int($0.rounded()))) ?? "\(Int($0.rounded()))") pas"
            }
            dayRow("Pic de FC", days.peakHr, tint: .pulseHR) { "\(Int($0.rounded())) bpm" }
            dayRow("FC au repos la plus basse", days.lowestRestingHr, tint: .pulseHR) {
                "\(Int($0.rounded())) bpm"
            }
        }
    }

    private func sleepSection(_ sleep: RecordsSleep) -> some View {
        RecordsSection(title: "Sommeil") {
            dayRow("Plus longue nuit", sleep.longestNight, tint: .pulseSleep) {
                ActivityFormat.duration($0)
            }
            dayRow("Meilleur score", sleep.bestScore, tint: .pulseSleep) { "\(Int($0.rounded()))" }
        }
    }

    private func streaksSection(_ streaks: RecordsStreaks) -> some View {
        RecordsSection(title: "Séries") {
            streakRow("Série record", streaks.longest)
            streakRow("Série en cours", streaks.current)
        }
    }

    // MARK: Lignes

    private func activityRow(
        _ title: String, _ record: RecordsActivity?, showSport: Bool,
        tint: Color = .pulseTextPrimary, format: (Double) -> String
    ) -> some View {
        Group {
            if let record {
                NavigationLink(value: record.activityId) {
                    RecordsRow(
                        title: title, value: format(record.value), tint: tint,
                        detail: activityDetail(record, showSport: showSport), pushes: true)
                }
                .buttonStyle(.plain)
            } else {
                RecordsRow(title: title, value: nil, tint: tint, detail: nil, pushes: false)
            }
        }
    }

    private func activityDetail(_ record: RecordsActivity, showSport: Bool) -> String {
        let date = record.startTime.map(recordsActivityDate) ?? "—"
        guard showSport else { return date }
        return "\(ActivitySport.label(sport: record.sport, subSport: record.subSport)) · \(date)"
    }

    private func dayRow(
        _ title: String, _ record: RecordsDay?, tint: Color, format: (Double) -> String
    ) -> some View {
        RecordsRow(
            title: title, value: record.map { format($0.value) }, tint: tint,
            detail: record.map { recordsCalendarDate($0.date) }, pushes: false)
    }

    private func streakRow(_ title: String, _ streak: RecordsStreak?) -> some View {
        RecordsRow(
            title: title,
            value: streak.map { "\($0.days) j" },
            tint: .pulseTextPrimary,
            detail: streak.map { "\(recordsCalendarDate($0.start)) – \(recordsCalendarDate($0.end))" },
            pushes: false)
    }
}

// MARK: - Formats

// Records établis sur tout l'historique : la date porte l'année, pas le jour de
// semaine (contrairement à `dashboardLongDate`).
private let recordsCalendarFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM yyyy"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "fr_FR")
    return formatter
}()

/// Même rendu, mais pour un `start_time` ISO (UTC) ramené au jour LOCAL : une
/// séance à 00 h 30 tombe le bon jour.
private let recordsLocalFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM yyyy"
    formatter.locale = Locale(identifier: "fr_FR")
    return formatter
}()

private let recordsIsoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let recordsIsoPlainFormatter = ISO8601DateFormatter()

private let recordsThousandsFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = "\u{202F}"
    formatter.locale = Locale(identifier: "fr_FR")
    return formatter
}()

/// Jour calendaire `YYYY-MM-DD` (journées, sommeil, séries).
private func recordsCalendarDate(_ day: String) -> String {
    guard let date = recordsIsoPlainFormatter.date(from: "\(day)T00:00:00Z") else { return day }
    return recordsCalendarFormatter.string(from: date)
}

private func recordsActivityDate(_ iso: String) -> String {
    guard let date = recordsIsoFormatter.date(from: iso) ?? recordsIsoPlainFormatter.date(from: iso)
    else { return iso }
    return recordsLocalFormatter.string(from: date)
}

// MARK: - Composants

/// Carte d'une section : titre discret + lignes séparées.
private struct RecordsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.sm) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.pulseTextSecondary)
                .padding(.horizontal, PulseSpacing.xs)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pulseSurface)
            .clipShape(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                    .strokeBorder(Color.pulseBorder, lineWidth: 1)
            )
        }
    }
}

/// Ligne de record : libellé + date/sport à gauche, valeur à droite (tiret si
/// absent), chevron quand elle ouvre l'activité.
private struct RecordsRow: View {
    let title: String
    let value: String?
    let tint: Color
    let detail: String?
    let pushes: Bool

    var body: some View {
        HStack(spacing: PulseSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.pulseTextPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
            Spacer(minLength: PulseSpacing.sm)
            Text(value ?? "—")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(value == nil ? Color.pulseAbsent : tint)
            if pushes {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
        .padding(.horizontal, PulseSpacing.lg)
        .padding(.vertical, PulseSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.pulseBorder).frame(height: 0.5).padding(.leading, PulseSpacing.lg)
        }
    }
}

/// Piste de filtre sport (Tous + un par sport) — même habillage que la piste
/// de période du Dashboard, défilante : le nombre de sports est libre.
private struct RecordsSportTrack: View {
    let sports: [String]
    let selection: String?
    let onSelect: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                pill("Tous", value: nil)
                ForEach(sports, id: \.self) { sport in
                    pill(ActivitySport.name(sport: sport), value: sport)
                }
            }
            .padding(3)
        }
        .background(Color.pulseSurfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func pill(_ label: String, value: String?) -> some View {
        let active = value == selection
        return Button {
            onSelect(value)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: active ? .semibold : .regular, design: .rounded))
                .foregroundStyle(active ? Color.pulseTextPrimary : Color.pulseTextSecondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Color.pulseSurface : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(active ? Color.pulseBorder : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
