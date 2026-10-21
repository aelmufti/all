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
        VStack(alignment: .leading, spacing: PulseSpacing.sm) {
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
                        .font(.system(size: 13, design: .rounded))
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
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.pulseAccent : Color.pulseAbsent)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(
                            !selected || picked.count >= perWeek ? Color.pulseTextSecondary : Color.pulseDanger)
                }
            }
            .foregroundStyle(Color.pulseTextPrimary)
            .padding(.vertical, PulseSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProgrammeDayPicker: View {
    let order: [Int]
    @Binding var picked: Set<Int>
    var onEdit: () -> Void = {}

    // Web `.dpick { gap:6px }`, `.dbtn { height:46px; min-height:46px }`.
    var body: some View {
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { day in
                let isOn = picked.contains(day)
                Button {
                    if isOn { picked.remove(day) } else { picked.insert(day) }
                    onEdit()
                } label: {
                    Text(ProgrammeDate.weekdayLetters[day])
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 46)
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
