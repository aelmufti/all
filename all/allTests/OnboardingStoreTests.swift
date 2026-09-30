//
//  OnboardingStoreTests.swift
//  allTests
//
//  Persistance du drapeau « onboarding terminé » (`OnboardingStore`) — cf. son
//  en-tête. `.serialized` par cohérence avec `StorageModeStoreTests` (même
//  famille de test), bien qu'ici tous les cas utilisent une
//  `UserDefaults(suiteName:)` dédiée, jamais `.standard`.
//

import Testing
import Foundation
@testable import all

@Suite(.serialized)
struct OnboardingStoreTests {
    @Test @MainActor func newInstanceDefaultsToNotCompletedWhenNothingPersisted() {
        let suiteName = "onboarding-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = OnboardingStore(defaults: defaults)

        #expect(store.completed == false)
    }

    @Test @MainActor func markCompletedPersistsToTheInjectedDefaults() {
        let suiteName = "onboarding-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = OnboardingStore(defaults: defaults)
        store.markCompleted()

        #expect(store.completed == true)
        #expect(defaults.bool(forKey: "onboarding-completed") == true)
    }

    /// Une instance fraîche construite sur les MÊMES `defaults` doit relire
    /// `true` — la valeur écrite par `markCompleted()` a bien traversé
    /// l'instance, pas seulement la mémoire (même vérification que
    /// `StorageModeStoreTests.persistsAcrossInstancesOfTheSameDefaults`).
    @Test @MainActor func freshInstanceOnTheSameDefaultsReadsCompletedTrue() {
        let suiteName = "onboarding-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = OnboardingStore(defaults: defaults)
        store.markCompleted()

        let reloaded = OnboardingStore(defaults: defaults)
        #expect(reloaded.completed == true)
    }
}
