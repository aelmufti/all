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

    // MARK: Couleurs par métrique — SCSS `--m-*`
    // Chaque métrique a sa teinte propre dans Pulse ; les tuiles/graphes NE
    // doivent PAS retomber sur `pulseAccent` bleu. Utiliser ces jetons pour la
    // valeur, l'icône et les aires de courbe de la métrique correspondante.
    static let pulseSleep = Color(light: 0x7A5CD8, dark: 0xA98CF0)   // sommeil
    static let pulseBattery = Color(light: 0x17968A, dark: 0x3FC9B8) // batterie corps
    static let pulseStress = Color(light: 0xC08519, dark: 0xE0AF49)  // stress
    static let pulseHR = Color(light: 0xCF4B5C, dark: 0xF0808C)      // fréquence cardiaque
    static let pulseSteps = Color(light: 0x3F9455, dark: 0x6CC47F)   // pas
    static let pulseCalories = Color(light: 0xCF6F34, dark: 0xEF9560) // calories
    static let pulseSpo2 = Color(light: 0x3B8FC4, dark: 0x6CB8E8)    // SpO2
    static let pulseResp = Color(light: 0xA8547F, dark: 0xD47AB0)    // respiration

    // MARK: Phases de sommeil — SCSS `--p-*`
    static let pulseSleepDeep = Color(light: 0x2F3F96, dark: 0x7D8AE6)
    static let pulseSleepLight = Color(light: 0x6F61C9, dark: 0xA794F0)
    static let pulseSleepRem = Color(light: 0x4AA3D1, dark: 0x6CC0E8)
    static let pulseSleepAwake = Color(light: 0x9AA0A6, dark: 0x7C848A)

    // MARK: Zones de stress — SCSS `--s-*`
    static let pulseStressRest = Color(light: 0x8FB6CF, dark: 0x7FA7C0)
    static let pulseStressLow = Color(light: 0xE0C078, dark: 0xE5CB8F)
    static let pulseStressMid = Color(light: 0xC08519, dark: 0xE0AF49)
    static let pulseStressHigh = Color(light: 0xC4483F, dark: 0xEF7D72)

    // MARK: Heatmap (intensité) — SCSS `--heat-*`
    static let pulseHeat1 = Color(light: 0x2A78D6, dark: 0x5AA3F0)
    static let pulseHeat2 = Color(light: 0x16815A, dark: 0x35C78D)
    static let pulseHeat3 = Color(light: 0xA87A05, dark: 0xE0A52C)
    static let pulseHeat4 = Color(light: 0xB5322C, dark: 0xF26A68)

    // MARK: Surfaces d'alerte — SCSS `--danger-bg/-border/-text`
    static let pulseDangerBg = Color(light: 0xFAECEB, dark: 0x2C1F1E)
    static let pulseDangerBorder = Color(light: 0xEDC9C6, dark: 0x4A3230)
    static let pulseDangerText = Color(light: 0xA13B33, dark: 0xF0A49C)

    // MARK: États vides / squelettes — SCSS `--empty/--absent/--sk-*`
    static let pulseEmpty = Color(light: 0xC9CCCB, dark: 0x4A5157)
    static let pulseAbsent = Color(light: 0x8A908E, dark: 0x767E83)
    static let pulseSkeletonShape = Color(light: 0xE3E5E4, dark: 0x2F353A)
    static let pulseSkeletonZone = Color(light: 0xEDEFEE, dark: 0x262B30)
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
        // SCSS `--gap-card: 12px` (`PulseSpacing.md`) — interligne entre les
        // éléments directs d'une carte non instrumentée (les cartes qui
        // gèrent déjà leur propre espacement interne, via un `VStack` imbriqué
        // avec son propre `spacing`, ne sont pas affectées).
        VStack(alignment: .leading, spacing: PulseSpacing.md) {
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

/// Badge circulaire teinté (fond `pulseAccent` à faible opacité) autour d'un
/// SF Symbol — repère visuel d'en-tête, partagé entre l'onboarding
/// (`OnboardingIconBadge` en dérive) et la porte de login (`LoginView`). Un seul
/// endroit pour la recette (taille, teinte) afin d'éviter la dérive.
struct PulseIconBadge: View {
    let icon: String
    var diameter: CGFloat = 88
    var iconSize: Font = .largeTitle

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.pulseAccent.opacity(0.12))
                .frame(width: diameter, height: diameter)
            Image(systemName: icon)
                .font(iconSize)
                .foregroundStyle(Color.pulseAccent)
        }
        .accessibilityHidden(true)
    }
}

/// Séparateur « ─── ou ─── » horizontal — marque une bifurcation entre deux
/// voies d'égale importance (ex. se connecter vs. utiliser sans serveur).
struct PulseOrDivider: View {
    var label: String = "ou"

    var body: some View {
        HStack(spacing: PulseSpacing.md) {
            line
            Text(label)
                .font(.footnote)
                .foregroundStyle(Color.pulseTextSecondary)
            line
        }
        .accessibilityHidden(true)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.pulseBorder)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
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

/// Bouton « Terminé » standard pour un écran présenté en feuille (`.sheet`)
/// depuis le menu système (roue crantée). Garantit une sortie explicite —
/// aucun écran présenté modalement ne doit pouvoir piéger l'utilisateur.
struct SheetCloseButton: ToolbarContent {
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Terminé", action: action)
                .tint(Color.pulseAccent)
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
