//
//  BodyBatteryBackfillTests.swift
//  allTests
//
//  Valide la Body Battery RÉELLE (`docs/duree-ideale-sommeil.md` §1) :
//  extraction du champ 3 de `stress_level` (227) dans
//  `FitWellnessExtractor.extractWellness`, et l'insertion ciblée
//  `LocalDb.insertBodyBatterySamples` utilisée par le rétro-remplissage
//  (`LocalIngestor.backfillBodyBatteryIfNeeded`). Messages FIT SYNTHÉTIQUES
//  construits à la main (`FitMessage` littéral) — aucune donnée personnelle,
//  pas de fichier `.fit` réel nécessaire pour ces deux fonctions.
//

import Testing
import Foundation
@testable import all

struct BodyBatteryBackfillTests {
    // MARK: - `extractWellness` : champ 3 de `stress_level` (227)

    @Test func extractWellnessEmitsBodyBatterySampleAlongsideStress() {
        // ts (champ 1) = 1000, stress (champ 0) = 45, bb (champ 3) = 72.
        let msg = FitMessage(globalMessageNumber: FitProfile.mesgStressLevel, fields: [
            0: .number(45), 1: .number(1000), 3: .number(72),
        ])
        let data = FitWellnessExtractor.extractWellness(messages: [msg])

        let bb = data.samples.filter { $0.metric == "bb" }
        let stress = data.samples.filter { $0.metric == "stress" }
        #expect(bb.count == 1)
        #expect(stress.count == 1)
        #expect(bb[0].value == 72)
        // Même ts que le stress (converti pareil : `fitTs + FIT_EPOCH_S`).
        #expect(bb[0].ts == stress[0].ts)
    }

    @Test func extractWellnessIgnoresInvalidBodyBatteryValues() {
        // 127 = invalide (sentinelle uint8 FIT) ; 150 > 100 = hors plage.
        for invalid in [127.0, 150.0] {
            let msg = FitMessage(globalMessageNumber: FitProfile.mesgStressLevel, fields: [
                0: .number(10), 1: .number(2000), 3: .number(invalid),
            ])
            let data = FitWellnessExtractor.extractWellness(messages: [msg])
            #expect(data.samples.filter { $0.metric == "bb" }.isEmpty)
            // Le stress, lui, reste émis — un bb invalide n'invalide pas le reste du message.
            #expect(data.samples.filter { $0.metric == "stress" }.count == 1)
        }
    }

    @Test func extractWellnessAcceptsBoundaryBodyBatteryValues() {
        for boundary in [0.0, 100.0] {
            let msg = FitMessage(globalMessageNumber: FitProfile.mesgStressLevel, fields: [
                0: .number(10), 1: .number(3000), 3: .number(boundary),
            ])
            let data = FitWellnessExtractor.extractWellness(messages: [msg])
            #expect(data.samples.filter { $0.metric == "bb" }.map(\.value) == [boundary])
        }
    }

    @Test func extractWellnessOmitsBodyBatteryWhenFieldAbsent() {
        let msg = FitMessage(globalMessageNumber: FitProfile.mesgStressLevel, fields: [
            0: .number(10), 1: .number(4000),
        ])
        let data = FitWellnessExtractor.extractWellness(messages: [msg])
        #expect(data.samples.filter { $0.metric == "bb" }.isEmpty)
        #expect(data.samples.filter { $0.metric == "stress" }.count == 1)
    }

    // MARK: - `LocalDb.insertBodyBatterySamples` (rétro-remplissage)

    private func makeDb() throws -> LocalDb {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-backfill-tests-\(UUID().uuidString).sqlite").path
        return try LocalDb(path: path)
    }

    @Test func insertBodyBatterySamplesIsIdempotentAndIgnoresNonBBMetrics() throws {
        let db = try makeDb()
        let samples = [
            FitWellnessSample(metric: "bb", ts: 10, value: 55),
            FitWellnessSample(metric: "bb", ts: 20, value: 60),
            FitWellnessSample(metric: "stress", ts: 30, value: 40), // ignoré par cette méthode.
        ]
        try db.insertBodyBatterySamples(samples)
        #expect(try db.sampleCount(metric: "bb") == 2)
        #expect(try db.sampleCount(metric: "stress") == 0)

        // Rejouer ne duplique rien (`INSERT OR IGNORE`, clé primaire (metric, ts)).
        try db.insertBodyBatterySamples(samples)
        #expect(try db.sampleCount(metric: "bb") == 2)
    }

    @Test func importedFilesFiltersBySpecifiedKind() throws {
        let db = try makeDb()
        let wellness = FitWellnessData(days: [], counters: [], counterSamples: [], samples: [])
        try db.storeWellness(wellness, hash: "hash-w1", fileName: "w1.fit")
        try db.storeWellness(wellness, hash: "hash-w2", fileName: "w2.fit")

        let sleep = FitSleepSummary(
            date: "2026-01-01", startTs: 0, endTs: 100, durationS: 100, score: nil,
            deepS: 50, lightS: 30, remS: 20, awakeS: 0, awakenings: nil, phases: [])
        try db.storeSleep(sleep, hash: "hash-s1", fileName: "s1.fit")

        let wellnessFiles = try db.importedFiles(kind: "wellness")
        #expect(wellnessFiles.count == 2)
        #expect(Set(wellnessFiles.map(\.hash)) == ["hash-w1", "hash-w2"])

        let sleepFiles = try db.importedFiles(kind: "sleep")
        #expect(sleepFiles.count == 1)
        #expect(sleepFiles[0].hash == "hash-s1")
    }

    // MARK: - `LocalIngestor.backfillBodyBatteryIfNeeded` : version gate pur (sans fichier spool)

    /// Sans aucun fichier wellness connu (`imported_files` vide), le
    /// rétro-remplissage pose quand même la clé de version (pas de relecture à
    /// refaire plus tard sur ce même état) et ne renvoie jamais `true` (rien
    /// inséré). Le spool vide ici est un `SpoolStore` réel sur un répertoire
    /// temporaire — pas de fichier `.fit` nécessaire pour cette branche.
    @Test func backfillWithNoKnownWellnessFilesSetsVersionAndReportsNoInsertion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)")
        let spool = try SpoolStore(root: dir)
        let db = try makeDb()

        let inserted = LocalIngestor.backfillBodyBatteryIfNeeded(spool: spool, db: db)
        #expect(inserted == false)
        #expect(try db.settingValue(key: "bb_backfill_version") == "1")

        // Rejouer est un no-op immédiat (version déjà posée) — toujours `false`.
        let insertedAgain = LocalIngestor.backfillBodyBatteryIfNeeded(spool: spool, db: db)
        #expect(insertedAgain == false)
    }
}
