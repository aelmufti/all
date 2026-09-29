//
//  SyncStatusBanner.swift
//  all (bridge-connect)
//
//  Indicateur global « synchronisation en cours » — visible sur TOUS les
//  écrans natifs (posé en overlay dans le `ZStack` de `PulseShellView`, donc
//  commun à tous les onglets, au lieu de dupliquer un indicateur par écran).
//  Purement informatif : `allowsHitTesting(false)` sur toute sa surface, pour
//  qu'aucun tap ne soit intercepté même quand la bannière est visible.
//
//  N'observe QUE `BLEManager.shared` (pas `garminSession` séparément) : le
//  pont `garminSessionChangeForwarder` ajouté dans `BLEManager` relaie déjà
//  tout changement de la session GFDI imbriquée vers l'`objectWillChange` de
//  `BLEManager` (cf. son commentaire) — sans lui, cette vue ne se
//  re-rendrait qu'aux changements des `@Published` directs de `BLEManager`
//  (`connectionState`, l'apparition/disparition de `garminSession` lui-même…),
//  jamais à ceux de `syncState`/`deliveredFileIndexes` À L'INTÉRIEUR d'une
//  session déjà en place.
//
//  Placement : bannière flottante centrée en haut, sous la status bar/l'île
//  dynamique. Plusieurs écrans (Accueil, Activités, Santé, Nutrition,
//  Sommeil) masquent leur barre de navigation système et dessinent leur
//  propre en-tête (titre + roue crantée) EN HAUT de leur `ScrollView` — cet
//  en-tête défile donc avec le contenu plutôt que de rester fixe. Une
//  bannière fixe en haut de l'écran peut donc chevaucher cet en-tête
//  lorsqu'un écran est encore tout en haut de son défilement (non vérifié au
//  device : à confirmer visuellement). Gardée volontairement petite,
//  translucide (`.ultraThinMaterial`) et transitoire (seulement pendant une
//  synchro active) pour minimiser la gêne le cas échéant.
//

import SwiftUI

struct SyncStatusBanner: View {
    @ObservedObject private var ble = BLEManager.shared

    private var activity: SyncActivity { ble.syncActivity }

    var body: some View {
        Group {
            if activity != .idle {
                pill
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: activity)
        // Laisse tous les taps passer, y compris sur la propre surface de la
        // bannière (purement informative, jamais un obstacle à l'interaction).
        .allowsHitTesting(false)
    }

    private var pill: some View {
        HStack(spacing: PulseSpacing.sm) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.pulseAccent)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.pulseTextSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, PulseSpacing.md)
        .padding(.vertical, PulseSpacing.xs + 2)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.pulseAccent.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 3)
        .padding(.top, PulseSpacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Synchronisation en cours : \(label)")
    }

    private var label: String {
        switch activity {
        case .idle:
            return ""
        case .connecting:
            return "Connexion à la montre…"
        case .listing:
            return "Lecture de la montre…"
        case .downloading(let done):
            return done == 1
                ? "Synchronisation… (1 fichier)"
                : "Synchronisation… (\(done) fichiers)"
        }
    }
}

#Preview {
    ZStack {
        Color.pulseBackground.ignoresSafeArea()
    }
    .overlay(alignment: .top) {
        SyncStatusBanner()
    }
}
