//
//  ProgrammeStyle.swift
//  all (bridge-connect)
//
//  Langage visuel local des écrans Programme (refonte « épurée ») : monochrome
//  (plein = `pulseTextPrimary`, vide = contour `pulseEmpty`, prévu = pointillé),
//  étiquettes mono majuscules, rangées à filets + chevron, un seul bouton
//  principal (44 pt) par écran. Ne touche pas `DesignSystem.swift`.
//

import SwiftUI

// MARK: - Typo

extension Font {
    /// SF Mono système (pas d'IBM Plex côté iOS).
    static func programmeMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Étiquette mono 10–11 pt, majuscules, tracking ≈ .1em, secondaire.
struct ProgrammeLabel: View {
    let text: String
    var size: CGFloat = 11

    init(_ text: String, size: CGFloat = 11) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(.programmeMono(size))
            .tracking(size * 0.1)
            .textCase(.uppercase)
            .foregroundStyle(Color.pulseTextSecondary)
    }
}

/// Grand chiffre mono (44 pt) + dénominateur discret.
struct ProgrammeBigNumber: View {
    let value: String
    var total: String?
    var size: CGFloat = 44
    var dim = false

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text(value)
                .font(.programmeMono(size, weight: .semibold))
                .foregroundStyle(dim ? Color.pulseAbsent : Color.pulseTextPrimary)
            if let total {
                Text("/\(total)")
                    .font(.programmeMono(size * 0.4, weight: .medium))
                    .foregroundStyle(Color.pulseTextSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

// MARK: - Conteneurs

/// Carte sobre : surface, filet 1 pt, rayon 16, marge 16 — sans ombre.
struct ProgrammeCard<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pulseSurface)
            .clipShape(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                    .strokeBorder(Color.pulseBorder, lineWidth: 1)
            )
    }
}

/// Filet 1 pt `pulseSurfaceAlt`.
struct ProgrammeHairline: View {
    var body: some View {
        Rectangle().fill(Color.pulseSurfaceAlt).frame(height: 1)
    }
}

/// Chevron › discret.
struct ProgrammeChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.pulseEmpty)
    }
}

// MARK: - Éléments graphiques

/// Case à cocher 22 pt, rayon 7 : pleine (faite), contour (à faire).
struct ProgrammeCheckbox: View {
    let checked: Bool

    var body: some View {
        ZStack {
            if checked {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.pulseTextPrimary)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.pulseBackground)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.pulseEmpty, lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// Bloc de calendrier 26 pt, rayon 8 : plein / vide / pointillé (prévu).
struct ProgrammeBlock: View {
    enum Fill { case filled, empty, planned, extra, missed }
    let fill: Fill

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            switch fill {
            case .filled: shape.fill(Color.pulseTextPrimary)
            case .empty: shape.fill(Color.pulseSurfaceAlt)
            case .planned:
                shape.strokeBorder(Color.pulseEmpty, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            case .extra: shape.fill(Color.pulseTextPrimary.opacity(0.3))
            case .missed: shape.strokeBorder(Color.pulseDanger.opacity(0.55), lineWidth: 1.5)
            }
        }
        .frame(height: 26)
    }
}

/// Barre de progression de bloc : segments 4 pt de haut.
struct ProgrammeSegmentBar: View {
    enum State { case done, part, todo }
    let segments: [(state: State, current: Bool)]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                Capsule()
                    .fill(color(seg.state))
                    .frame(height: 4)
            }
        }
    }

    private func color(_ state: State) -> Color {
        switch state {
        case .done: return .pulseTextPrimary
        case .part: return .pulseEmpty
        case .todo: return .pulseSurfaceAlt
        }
    }
}

/// Légende à pastille mono 10 pt.
struct ProgrammeLegendItem: View {
    let label: String
    var color: Color?
    var dashed = false

    var body: some View {
        HStack(spacing: 6) {
            if dashed {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.pulseEmpty, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                    .frame(width: 9, height: 9)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(color ?? Color.pulseTextPrimary).frame(width: 9, height: 9)
            }
            Text(label).font(.programmeMono(10)).foregroundStyle(Color.pulseTextSecondary)
        }
    }
}

// MARK: - Boutons

/// Bouton principal unique de l'écran : 44 pt, fond `pulseTextPrimary`, texte couleur fond.
struct ProgrammePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.pulseBackground)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.pulseTextPrimary)
            .clipShape(RoundedRectangle(cornerRadius: PulseRadius.inner, style: .continuous))
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
    }
}

/// Action secondaire : texte discret, sans fond ni contour.
struct ProgrammeTextButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(destructive ? Color.pulseDanger : Color.pulseTextSecondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

extension ButtonStyle where Self == ProgrammePrimaryButtonStyle {
    static var programmePrimary: ProgrammePrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == ProgrammeTextButtonStyle {
    static var programmeText: ProgrammeTextButtonStyle { .init() }
    static var programmeDestructiveText: ProgrammeTextButtonStyle { .init(destructive: true) }
}
