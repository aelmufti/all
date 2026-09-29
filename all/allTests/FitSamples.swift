//
//  FitSamples.swift
//  allTests
//
//  Résout les chemins des `.fit` d'exemple utilisés par les tests locaux
//  (`FitDecoderTests`, `ActivitiesExtractorTests`, `DashboardStatsLocalTests`,
//  `LocalDayDetailTests`) via un manifeste JSON LOCAL, jamais commité — ces
//  fichiers sont des données personnelles de santé (cf. CLAUDE.md), le dépôt
//  est public.
//
//  Manifeste : chemin dans la variable d'env `FIT_SAMPLES_MANIFEST`, sinon
//  `all/allTests/fit-samples.local.json` (gitignored) à côté de ce fichier.
//  Format :
//  {
//    "dir": "/chemin/absolu/vers/samples",
//    "files": { "role": "nom-du-fichier.fit", ... }
//  }
//
//  Aucun littéral personnel dans CE fichier. Sans manifeste (ou manifeste
//  pointant vers un dossier vide/absent), `available == false` : les tests
//  qui en dépendent doivent `guard FitSamples.available else { return }` en
//  tête pour rester au vert (passage à vide) plutôt que d'échouer.
//

import Foundation

enum FitSamples {
    private struct Manifest: Decodable {
        let dir: String
        let files: [String: String]
    }

    private static var defaultManifestPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fit-samples.local.json")
            .path
    }

    private static let manifest: Manifest? = {
        let path = ProcessInfo.processInfo.environment["FIT_SAMPLES_MANIFEST"] ?? defaultManifestPath
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }()

    /// `true` seulement si un manifeste a été chargé ET que son dossier
    /// existe et n'est pas vide.
    static let available: Bool = {
        guard let manifest else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: manifest.dir, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: manifest.dir)) ?? []
        return !contents.isEmpty
    }()

    /// Chemin absolu du fichier associé à `role`, ou `nil` si le manifeste
    /// est absent ou ne connaît pas ce rôle.
    static func path(_ role: String) -> String? {
        guard let manifest, let name = manifest.files[role] else { return nil }
        return URL(fileURLWithPath: manifest.dir).appendingPathComponent(name).path
    }

    static func data(_ role: String) throws -> Data {
        guard let path = path(role) else { throw SampleError.missingRole(role) }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    enum SampleError: Error {
        case missingRole(String)
    }
}
