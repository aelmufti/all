//
//  ProgrammeDaysSelector.swift
//  all (bridge-connect)
//
//  Jours d'entraînement : « Tes habitudes · L M V S » quand des habitudes
//  existent (sélectionné par défaut), « Personnaliser » qui déplie le
//  sélecteur 7 jours avec un compteur. Sans habitudes, le sélecteur seul.
//  Partagé par la feuille d'objectif et la bibliothèque.
//

import SwiftUI

struct ProgrammeDaysSelector: View {
    let perWeek: Int
    let suggestion: ProgrammeDaySuggestion
    @Binding var picked: Set<Int>

    @State private var custom = false

    private var showPicker: Bool { custom || !suggestion.fromHabits }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if suggestion.fromHabits {
                optionRow(title: "Tes habitudes", trailing: suggestion.label, selected: !custom) {
                    custom = false
                    picked = Set(suggestion.days)
                }
                optionRow(title: "Personnaliser", trailing: custom ? "\(picked.count)/\(perWeek)" : nil,
                          selected: custom) {
                    custom = true
                }
            }
            if showPicker {
                ProgrammeDayPicker(order: programmeDayPickerOrder, picked: $picked) { custom = true }
                if !suggestion.fromHabits {
                    Text("\(picked.count)/\(perWeek)")
                        .font(.programmeMono(12))
                        .foregroundStyle(picked.count < perWeek ? Color.pulseDanger : Color.pulseTextSecondary)
                }
            }
        }
        .onAppear { if suggestion.fromHabits, !custom { picked = Set(suggestion.days) } }
        // Les activités arrivent après l'ouverture : les habitudes remplacent
        // l'ordre par défaut tant que l'utilisateur n'a rien touché.
        .onChange(of: suggestion) { _, new in
            if new.fromHabits, !custom { picked = Set(new.days) }
        }
    }

    private func optionRow(title: String, trailing: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ProgrammeCheckbox(checked: selected)
                Text(title)
                    .font(.system(size: 15, weight: selected ? .medium : .regular))
                    .foregroundStyle(Color.pulseTextPrimary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.programmeMono(13))
                        .foregroundStyle(
                            !selected || picked.count >= perWeek ? Color.pulseTextSecondary : Color.pulseDanger)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProgrammeDayPicker: View {
    let order: [Int]
    @Binding var picked: Set<Int>
    var onEdit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { day in
                let isOn = picked.contains(day)
                Button {
                    if isOn { picked.remove(day) } else { picked.insert(day) }
                    onEdit()
                } label: {
                    Text(ProgrammeDate.weekdayLetters[day])
                        .font(.programmeMono(12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(isOn ? Color.pulseTextPrimary : Color.clear)
                        .foregroundStyle(isOn ? Color.pulseBackground : Color.pulseTextSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isOn ? Color.clear : Color.pulseEmpty, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
