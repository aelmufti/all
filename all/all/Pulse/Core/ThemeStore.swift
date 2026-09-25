//
//  ThemeStore.swift
//  all (bridge-connect)
//
//  Miroir natif de `custom-connect/web/src/app/core/theme.service.ts` :
//  trois thèmes (`auto`/`light`/`dark`), cycle dans cet ordre, persisté.
//  Côté web, `auto` retire `data-theme` (le SCSS suit alors
//  `prefers-color-scheme`) et `light`/`dark` le posent explicitement.
//  Côté natif, on obtient le même effet via `.preferredColorScheme` sur la
//  racine (cf. `ContentView.swift`) : `nil` pour `auto` laisse le système
//  décider, `.light`/`.dark` le force — ce qui fait resoudre les `Color`
//  dynamiques de `DesignSystem.swift` (basées sur `UITraitCollection`) selon
//  le thème choisi, exactement comme le SCSS bascule sur l'attribut.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    enum Theme: String {
        case auto
        case light
        case dark
    }

    private static let key = "pulse-theme"

    var theme: Theme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Self.key)
        }
    }

    init(defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: Self.key).flatMap(Theme.init(rawValue:))
        theme = stored ?? .auto
    }

    /// `auto → light → dark → auto` — même ordre que `ThemeService.cycle()`.
    func cycle() {
        switch theme {
        case .auto: theme = .light
        case .light: theme = .dark
        case .dark: theme = .auto
        }
    }

    /// `nil` laisse le système décider (thème `auto`) — sinon force le
    /// `ColorScheme` correspondant.
    var colorScheme: ColorScheme? {
        switch theme {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
