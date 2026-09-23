//
//  ProgrammeLibrarySheet.swift
//  all (bridge-connect)
//
//  Sheet de bibliothèque d'un domaine — liste des programmes catalogués
//  (`domain.choices`), avec sélection des jours pour ceux qui en ont besoin
//  (entraînement, sommeil). Miroir simplifié du sheet `picking` Angular :
//  pas de sous-écran de rapprochement d'activités (`candidates`), l'essentiel
//  étant de pouvoir démarrer/arrêter un programme depuis le téléphone (cf.
//  `ProgrammeViewModel` pour la même remarque côté actions).
//

import SwiftUI

struct ProgrammeLibrarySheet: View {
    let domain: ProgrammeDomainView
    let isBusy: Bool
    let onActivate: (String, [Int]) -> Void
    let onStop: () -> Void

    @State private var picking: ProgrammeChoice?
    @State private var pickedDays: Set<Int> = []

    /// Équivalent `DAY_ORDER` (Angular) : ordre de remplissage par défaut des
    /// jours d'entraînement (lundi, mercredi, vendredi, puis les autres).
    private static let dayOrder = [1, 3, 5, 2, 4, 6, 0]
    private static let workDays = [1, 2, 3, 4, 5]
    private static let pickerOrder = [1, 2, 3, 4, 5, 6, 0]

    var body: some View {
        NavigationStack {
            List {
                if let choice = picking {
                    pickingSection(choice)
                } else {
                    Section {
                        Text(domain.hint)
                            .font(.footnote)
                            .foregroundStyle(Color.pulseTextSecondary)
                    }
                    Section {
                        ForEach(domain.choices) { choice in
                            ProgrammeChoiceRow(
                                choice: choice,
                                meta: choiceMeta(choice),
                                isActive: domain.active?.programmeId == choice.id,
                                isBusy: isBusy,
                                onBegin: { begin(choice) },
                                onStop: onStop
                            )
                        }
                    }
                }
            }
            .navigationTitle(domain.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if picking != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Retour") { picking = nil }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pickingSection(_ choice: ProgrammeChoice) -> some View {
        Section {
            Text(pickIntro(choice))
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
            Text(domain.kind == .sleep
                 ? "Coche les jours où tu dois te lever à heure imposée. Les autres servent de référence pour le décalage social et le rattrapage."
                 : "Choisis les jours où tu peux t’entraîner.")
                .font(.caption)
                .foregroundStyle(Color.pulseTextSecondary)
            ProgrammeDayPicker(order: Self.pickerOrder, picked: $pickedDays)
                .listRowInsets(EdgeInsets())
                .padding(.vertical, PulseSpacing.xs)
            Text(pickNote(choice))
                .font(.caption)
                .foregroundStyle(pickShort(choice) ? Color.pulseDanger : Color.pulseTextSecondary)
            Button("Commencer aujourd’hui") {
                onActivate(choice.id, pickedDays.sorted())
                picking = nil
            }
            .disabled(isBusy || (domain.kind == .training && pickedDays.count < choice.perWeek))
        }
    }

    private func begin(_ choice: ProgrammeChoice) {
        switch domain.kind {
        case .nutrition:
            onActivate(choice.id, [])
        case .sleep:
            let existing = domain.active?.days ?? []
            pickedDays = Set(existing.isEmpty ? Self.workDays : existing)
            picking = choice
        case .training:
            pickedDays = Set(Self.dayOrder.prefix(choice.perWeek))
            picking = choice
        }
    }

    private func choiceMeta(_ choice: ProgrammeChoice) -> String {
        switch domain.kind {
        case .nutrition: return "\(choice.rules) cibles par jour"
        case .sleep: return "\(choice.rules) critères sur 14 nuits"
        case .training: return "\(choice.weeks) semaines"
        }
    }

    private func pickIntro(_ choice: ProgrammeChoice) -> String {
        if domain.kind == .sleep {
            return "\(choice.name) · \(choice.rules) critères relus à chaque synchro, sur les quatorze dernières nuits."
        }
        return "\(choice.name) · \(choice.perWeek) séance\(choice.perWeek > 1 ? "s" : "") par semaine sur \(choice.weeks) semaines."
    }

    private func pickShort(_ choice: ProgrammeChoice) -> Bool {
        if domain.kind == .sleep { return pickedDays.isEmpty || pickedDays.count == 7 }
        return pickedDays.count < choice.perWeek
    }

    private func pickNote(_ choice: ProgrammeChoice) -> String {
        if domain.kind == .sleep {
            let work = pickedDays.count
            let free = 7 - work
            if work == 0 || free == 0 {
                return "Sans jours des deux sortes, le décalage social et le rattrapage resteront vides — les autres critères tiennent quand même."
            }
            return "\(work) jour\(work > 1 ? "s" : "") à réveil imposé, \(free) jour\(free > 1 ? "s" : "") libre\(free > 1 ? "s" : "")."
        }
        let missing = choice.perWeek - pickedDays.count
        if missing > 0 {
            return "Encore \(missing) jour\(missing > 1 ? "s" : "") à cocher."
        }
        let extra = pickedDays.count - choice.perWeek
        return extra > 0
            ? "\(pickedDays.count) jours cochés, \(choice.perWeek) utilisés — les premiers de la semaine."
            : "\(choice.perWeek) séance\(choice.perWeek > 1 ? "s" : "") par semaine, une par jour coché."
    }
}

private struct ProgrammeChoiceRow: View {
    let choice: ProgrammeChoice
    let meta: String
    let isActive: Bool
    let isBusy: Bool
    let onBegin: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.name).font(.subheadline.weight(.semibold))
                Text(choice.goal).font(.caption).foregroundStyle(Color.pulseTextSecondary)
                Text("\(meta) · \(choice.source)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
            Spacer()
            if isActive {
                Button("Arrêter", role: .destructive, action: onStop)
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
            } else {
                Button("Commencer", action: onBegin)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.pulseAccent)
                    .disabled(isBusy)
            }
        }
        .padding(.vertical, PulseSpacing.xs)
    }
}

private struct ProgrammeDayPicker: View {
    let order: [Int]
    @Binding var picked: Set<Int>

    var body: some View {
        HStack(spacing: PulseSpacing.xs) {
            ForEach(order, id: \.self) { day in
                let isOn = picked.contains(day)
                Button {
                    if isOn { picked.remove(day) } else { picked.insert(day) }
                } label: {
                    Text(ProgrammeDate.weekdayLetters[day])
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(isOn ? Color.pulseTextPrimary : Color.pulseSurface)
                        .foregroundStyle(isOn ? Color.pulseSurface : Color.pulseTextSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous)
                                .strokeBorder(Color.pulseBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
