//
//  LocalIngestorChangeTests.swift
//  allTests
//
//  Couvre la décision « faut-il notifier les écrans ? » de
//  `LocalIngestor.ingestIfNeeded()` (bug : un import local pendant que l'app
//  est ouverte ne rafraîchissait rien, l'utilisateur ne voyait la nouvelle
//  donnée qu'au redémarrage). `ingestIfNeeded()` lui-même ouvre un vrai
//  `SpoolStore`/`LocalDb` dans une `Task.detached` — pas testé ici ; on teste
//  à la place la fonction PURE qu'il consulte avant de poster
//  `.allLocalDataDidChange` (`LocalIngestor.hasNewInsertion`), plus
//  l'existence/valeur de la constante de notification.
//

import Testing
import Foundation
@testable import all

struct LocalIngestorChangeTests {
    @Test func notificationNameIsStable() {
        // Valeur figée : `Pulse/Core/LocalDataRefresh.swift` s'y abonne par
        // nom, et un changement accidentel casserait silencieusement le
        // rafraîchissement des écrans sans qu'aucun test ne le voie autrement.
        #expect(Notification.Name.allLocalDataDidChange.rawValue == "allLocalDataDidChange")
    }

    @Test func noResultsMeansNoChange() {
        #expect(LocalIngestor.hasNewInsertion([]) == false)
    }

    @Test func onlyDuplicatesSkipsAndErrorsMeanNoChange() {
        let results = [
            LocalIngestResult(fileName: "a.fit", kind: .duplicate),
            LocalIngestResult(fileName: "b.fit", kind: .skipped),
            LocalIngestResult(fileName: "c.fit", kind: .error("corrompu")),
        ]
        #expect(LocalIngestor.hasNewInsertion(results) == false)
    }

    @Test func aSingleWellnessInsertionMeansChange() {
        let results = [
            LocalIngestResult(fileName: "a.fit", kind: .duplicate),
            LocalIngestResult(fileName: "b.fit", kind: .wellness),
        ]
        #expect(LocalIngestor.hasNewInsertion(results) == true)
    }

    @Test func aSingleSleepInsertionMeansChange() {
        #expect(LocalIngestor.hasNewInsertion([LocalIngestResult(fileName: "n.fit", kind: .sleep)]) == true)
    }

    @Test func aSingleActivityInsertionMeansChange() {
        #expect(LocalIngestor.hasNewInsertion([LocalIngestResult(fileName: "r.fit", kind: .activity)]) == true)
    }
}
