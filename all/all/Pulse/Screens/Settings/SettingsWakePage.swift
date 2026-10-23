//
//  SettingsWakePage.swift
//  all (bridge-connect)
//
//  Page « Réveil » des Paramètres — façon app Horloge : une ligne par jour
//  (Lun → Dim) avec un interrupteur et, quand il est actif, l'heure réglable sur
//  la ligne. L'envoi à la montre est une ligne d'action séparée.
//
//  Réglage fait DANS l'app — pas une alarme de l'app Horloge iOS (illisible et
//  non pilotable depuis une app tierce). Double rôle : programme un rappel sonore
//  (`WakeAlarmScheduler`) et pilote l'adaptation de la carte « Heure de coucher
//  conseillée » de l'écran Sommeil. Présenté dans TOUS les modes de stockage.
//
//  NOTE : la persistance reste le store global `WakeScheduleStore`
//  (`UserDefaults`, device-wide ; push backend à chaque `set`/`clear`, d'où le
//  debounce sur les changements d'heure).
//

import SwiftUI

struct SettingsWakePage: View {
    var body: some View {
        Form {
            SettingsWakeSection()
        }
        .navigationTitle("Réveil")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Modèle de la page

/// Écart entre ce que l'utilisateur vient de faire (instantané à l'écran) et ce
/// qui est écrit dans `WakeScheduleStore` (qui pousse au backend) : `drafts` porte
/// l'heure affichée en attendant que le debounce de ~0,6 s la valide.
@MainActor
@Observable
final class SettingsWakeModel {
    static let weekdays = [2, 3, 4, 5, 6, 7, 1] // Lun … Dim (Calendar weekday, 1 = dim.)
    static let names = ["Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi", "Dimanche"]

    private let store: WakeScheduleStore
    private let delay: Duration
    private(set) var drafts: [Int: Int] = [:]
    /// Incrémenté à chaque activation/désactivation d'un jour (retour haptique).
    private(set) var toggleCount = 0
    private var lastSet: Int?
    private var debouncers: [Int: SettingsDebouncer] = [:]

    init(store: WakeScheduleStore? = nil, delay: Duration = .milliseconds(600)) {
        self.store = store ?? .shared
        self.delay = delay
    }

    /// Heure affichée pour un jour : le brouillon en cours, sinon le store.
    func minutes(for weekday: Int) -> Int? {
        drafts[weekday] ?? store.minutes(for: weekday)
    }

    func setEnabled(_ enabled: Bool, weekday: Int) {
        toggleCount += 1
        debouncers[weekday]?.cancelPending()
        if enabled {
            let minutes = SettingsWakeDefaults.minutes(
                lastSet: lastSet, schedule: store.minutesByWeekday, order: Self.weekdays)
            drafts[weekday] = minutes
            Task {
                // Première activation : le système demande l'autorisation de notifier.
                _ = await WakeAlarmScheduler.shared.requestAuthorizationIfNeeded()
                store.set(minutes: minutes, weekdays: [weekday])
                if drafts[weekday] == minutes { drafts[weekday] = nil }
            }
        } else {
            drafts[weekday] = nil
            store.clear(weekdays: [weekday])
        }
    }

    func setMinutes(_ minutes: Int, weekday: Int) {
        lastSet = minutes
        drafts[weekday] = minutes
        let debouncer = debouncers[weekday] ?? SettingsDebouncer(delay: delay)
        debouncers[weekday] = debouncer
        debouncer.schedule { [self] in
            store.set(minutes: minutes, weekdays: [weekday])
            if drafts[weekday] == minutes { drafts[weekday] = nil }
        }
    }
}

// MARK: - Section

struct SettingsWakeSection: View {
    @State private var model = SettingsWakeModel()

    /// `WakeScheduleStore` étant `@Observable`, lire `minutesByWeekday` ici
    /// fait redessiner la section après chaque `set`/`clear`.
    @State private var store = WakeScheduleStore.shared

    /// Accès au lien BLE courant (état de connexion + `GarminSession` active)
    /// pour la ligne « Envoyer à la montre » — même point d'entrée que le
    /// reste de l'app (`BLEManager.shared`).
    @ObservedObject private var ble = BLEManager.shared

    var body: some View {
        Section {
            ForEach(Array(SettingsWakeModel.weekdays.enumerated()), id: \.element) { index, weekday in
                dayRow(name: SettingsWakeModel.names[index], weekday: weekday)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: model.toggleCount)

        // Envoi manuel du planning courant vers la montre (alarme native,
        // `GarminSession.writeAlarms`) — jamais automatique.
        Section {
            if let session = ble.garminSession {
                WatchAlarmUploadRow(
                    session: session,
                    schedule: store.minutesByWeekday,
                    isLinkActive: ble.connectionState == .connected
                )
            } else {
                WatchAlarmUploadRow.disconnectedPlaceholder
            }
        }
    }

    private func dayRow(name: String, weekday: Int) -> some View {
        let minutes = model.minutes(for: weekday)
        return HStack(spacing: PulseSpacing.sm) {
            Text(name)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: PulseSpacing.sm)
            if let minutes {
                DatePicker(
                    "Heure du \(name.lowercased())",
                    selection: Binding(
                        get: { Self.date(minutes: minutes) },
                        set: { model.setMinutes(Self.minutes(of: $0), weekday: weekday) }),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
            }
            Toggle(name, isOn: Binding(
                get: { minutes != nil },
                set: { model.setEnabled($0, weekday: weekday) }))
                .labelsHidden()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(minutes.map { "\(name), \(WakeScheduleStore.hhmm($0))" } ?? "\(name), désactivé")
    }

    private static func date(minutes: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = minutes / 60
        components.minute = minutes % 60
        return Calendar.current.date(from: components) ?? Date()
    }

    private static func minutes(of date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 7) * 60 + (c.minute ?? 0)
    }
}

// MARK: - Envoi du planning d'alarmes vers la montre (upload FIT Settings)
//
// Ligne manuelle (jamais automatique) qui pousse `store.minutesByWeekday` vers
// la montre via `GarminSession.writeAlarms` (canal d'upload partagé avec le
// poids, cf. `GarminSession.swift`). Observe directement la `GarminSession`
// active plutôt que `BLEManager` : contrairement au poids
// (`BLEManager.weightWriteState`, relayé par un abonnement existant côté
// `BLEManager`), rien ne relaie encore `GarminSession.$alarmWriteState`
// jusqu'à `BLEManager` — un `@Published` d'un `ObservableObject` ENFANT ne
// remonte pas automatiquement à l'`objectWillChange` du parent en
// SwiftUI/Combine (cf. le commentaire de
// `BLEManager.garminSessionChangeForwarder`). Ajouter ce relais appartient à
// `BLEManager.swift`, hors périmètre de cette tâche (lot parallélisé) : cette
// ligne s'abonne donc elle-même à la session, ce qui suffit à rester à jour
// sans y toucher.
struct WatchAlarmUploadRow: View {
    @ObservedObject var session: GarminSession
    let schedule: [Int: Int]
    let isLinkActive: Bool

    /// Rendu quand aucune `GarminSession` n'est active (pas de lien BLE) —
    /// ligne désactivée, pas de session à observer.
    static var disconnectedPlaceholder: some View {
        Button {} label: {
            HStack {
                Text("Envoyer à la montre")
                Spacer()
                Text("Montre non connectée")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
        .disabled(true)
    }

    var body: some View {
        Button {
            session.writeAlarms(schedule: schedule)
        } label: {
            HStack(spacing: PulseSpacing.sm) {
                Text("Envoyer à la montre")
                Spacer(minLength: PulseSpacing.sm)
                if !isLinkActive {
                    Text("Montre non connectée")
                        .font(.footnote)
                        .foregroundStyle(Color.pulseTextSecondary)
                } else if session.alarmWriteState == .uploading {
                    ProgressView()
                } else if session.alarmWriteState != .idle {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(session.alarmWriteState.label)
                        .font(.footnote)
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .disabled(!canSend)
        .accessibilityValue(isLinkActive ? session.alarmWriteState.label : "Montre non connectée")
    }

    private var canSend: Bool {
        isLinkActive && session.alarmWriteState != .uploading
    }

    private var statusIcon: String {
        switch session.alarmWriteState {
        case .sent: return "checkmark.circle.fill"
        case .refused, .failed: return "exclamationmark.triangle.fill"
        case .uploading: return "arrow.up.circle"
        default: return "clock"
        }
    }

    private var statusColor: Color {
        switch session.alarmWriteState {
        case .sent: return Color.pulseSteps
        case .refused, .failed: return Color.pulseDanger
        default: return Color.pulseTextSecondary
        }
    }
}
