//
//  DesignSystem.swift
//  all (bridge-connect)
//
//  Jetons de design natifs pour la coquille Pulse — palette, espacements,
//  rayons, typo, et une poignée de composants réutilisables (`PulseCard`,
//  `StatTile`, `SectionHeader`, `LoadingView`, `ErrorView`). Tous les écrans
//  de données (Accueil, Santé, Activités, Nutrition, Plus) construisent leur
//  UI à partir de ce socle plutôt que de redéfinir des styles au cas par cas.
//
//  Palette calquée sur le thème du front Angular de Pulse
//  (`custom-connect/web/src/styles.scss`, variables CSS `--bg`, `--surface`,
//  `--accent`, `--success`, `--danger`…) pour que l'app native ait le même
//  esprit visuel — traduite en `Color` SwiftUI avec variantes light/dark
//  (le SCSS bascule sur `prefers-color-scheme: dark`, on fait pareil ici via
//  `UITraitCollection`/`ColorScheme`).
//

import SwiftUI

// MARK: - Palette

private extension Color {
    /// Couleur dynamique light/dark à partir de deux valeurs hex (`0xRRGGBB`),
    /// même principe que les paires `:root` / `@include dark` du SCSS Pulse.
    init(light: UInt32, dark: UInt32) {
        self = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

extension Color {
    // Fond / surfaces — SCSS `--bg` / `--surface` / `--surface-2` / `--border`.
    static let pulseBackground = Color(light: 0xF5F6F5, dark: 0x15181B)
    static let pulseSurface = Color(light: 0xFFFFFF, dark: 0x1E2226)
    static let pulseSurfaceAlt = Color(light: 0xEDEFEE, dark: 0x262B30)
    static let pulseBorder = Color(light: 0xDBDEDD, dark: 0x343A40)

    // Texte — SCSS `--text` / `--text-dim`.
    static let pulseTextPrimary = Color(light: 0x1C2124, dark: 0xEAECEC)
    static let pulseTextSecondary = Color(light: 0x5E666A, dark: 0x939B9F)

    // Sémantique — SCSS `--accent` / `--success` / `--danger`.
    static let pulseAccent = Color(light: 0x3563B8, dark: 0x7BA2F0)
    static let pulseSuccess = Color(light: 0x20804C, dark: 0x5CC487)
    static let pulseDanger = Color(light: 0xBE4239, dark: 0xEF7D72)

    /// Texte lisible sur `pulseAccent` (boutons pleins…) — SCSS `--on-accent`.
    static let pulseOnAccent = Color(light: 0xFFFFFF, dark: 0x15181B)
}

// MARK: - Espacements / rayons

enum PulseSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum PulseRadius {
    /// SCSS `--r-card`.
    static let card: CGFloat = 16
    /// SCSS `--r-inner`.
    static let inner: CGFloat = 12
    /// SCSS `--r-pill`.
    static let pill: CGFloat = 999
}

// MARK: - Typo

/// Échelle inspirée des classes utilitaires `.metric-*` du SCSS Pulse
/// (valeur en gros chiffres monospacés + unité + libellé discret en petites
/// capitales) — la base des `StatTile`.
enum PulseFont {
    static let metricValue = Font.system(size: 36, weight: .semibold, design: .monospaced)
    static let metricUnit = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let metricLabel = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let sectionTitle = Font.system(.headline, weight: .semibold)
    static let body = Font.system(.body)
}

// MARK: - Composants

/// Conteneur carte réutilisable — équivalent SwiftUI de `.card`/`.glass`
/// dans le SCSS Pulse (fond `--surface`, bordure `--border`, rayon `--r-card`).
struct PulseCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.sm) {
            content
        }
        .padding(PulseSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pulseSurface)
        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                .strokeBorder(Color.pulseBorder, lineWidth: 1)
        )
    }
}

/// Tuile de statistique : libellé + grande valeur + unité optionnelle.
/// Base visuelle des futurs écrans de données (FC, pas, calories, sommeil…).
struct StatTile: View {
    let label: String
    let value: String
    var unit: String?
    var accent: Color = .pulseAccent

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
            Text(label.uppercased())
                .font(PulseFont.metricLabel)
                .foregroundStyle(Color.pulseTextSecondary)
                .tracking(0.6)
            HStack(alignment: .lastTextBaseline, spacing: PulseSpacing.xs) {
                Text(value)
                    .font(PulseFont.metricValue)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(PulseFont.metricUnit)
                        .foregroundStyle(Color.pulseTextSecondary)
                }
            }
        }
    }
}

/// En-tête de section — titre + action de fin optionnelle (ex. « Voir tout »).
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(PulseFont.sectionTitle)
                .foregroundStyle(Color.pulseTextPrimary)
            Spacer()
            trailing
        }
    }
}

/// État de chargement générique — écrans en attente d'une réponse Pulse.
struct LoadingView: View {
    var message: String = "Chargement…"

    var body: some View {
        VStack(spacing: PulseSpacing.md) {
            ProgressView()
            Text(message)
                .font(PulseFont.body)
                .foregroundStyle(Color.pulseTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pulseBackground)
    }
}

/// État d'erreur générique avec action de reprise — le mapping
/// `PulseAPIError` → message lisible se fait côté appelant (souvent via
/// `error.localizedDescription`, cf. `PulseAPIError: LocalizedError`).
struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: PulseSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.pulseDanger)
            Text(message)
                .font(PulseFont.body)
                .foregroundStyle(Color.pulseTextPrimary)
                .multilineTextAlignment(.center)
            Button("Réessayer", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(Color.pulseAccent)
        }
        .padding(PulseSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pulseBackground)
    }
}
