//
//  AppDelegate.swift
//  all (bridge-connect)
//
//  Pont UIKit minimal : la restauration d'état CoreBluetooth (incrément 1) a
//  besoin d'un CBCentralManager instancié **tôt** au relance arrière-plan,
//  avant que SwiftUI ne construise sa hiérarchie de vues.
//  `@UIApplicationDelegateAdaptor` (branché dans allApp.swift) garantit cet
//  ordre ; le manager reste un singleton, réutilisé partout ailleurs.
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Toucher le singleton suffit à le construire : son init crée le
        // CBCentralManager avec l'option de restauration d'état.
        _ = BLEManager.shared
        return true
    }
}
