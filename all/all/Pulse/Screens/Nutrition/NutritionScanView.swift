//
//  NutritionScanView.swift
//  all (bridge-connect)
//
//  Vue `.scan` de la feuille d'ajout d'aliment — caméra VisionKit
//  (`DataScannerViewController`) qui lit un code-barres puis délègue au
//  `NutritionViewModel` la résolution du produit via Pulse
//  (`GET api/nutrition/barcode/{code}`, cf. `lookupBarcode`). Miroir de
//  `<app-barcode-scanner (scanned)="onBarcode($event)">` du composant Angular
//  (`custom-connect/web/src/app/pages/nutrition/nutrition.component.ts`), qui
//  utilise la caméra du navigateur — ici l'équivalent natif.
//
//  Autorisation caméra gérée explicitement (string `NSCameraUsageDescription`
//  dans `all/Info.plist`) : on demande l'accès au premier affichage, et on
//  offre un repli « saisir à la main » si l'appareil ne sait pas scanner ou
//  si l'accès est refusé — la feuille ne doit jamais piéger l'utilisateur.
//

import SwiftUI
import VisionKit
import AVFoundation
import Vision
import UIKit

/// Réponse de `GET api/nutrition/barcode/{code}` (Pulse) — miroir du type
/// Angular `{ found, source?, food? }`. `food` a la même forme que les
/// résultats de recherche, donc `NutritionFoodLite`.
struct NutritionBarcodeResult: Decodable {
    let found: Bool
    let source: String?
    let food: NutritionFoodLite?
}

struct NutritionScanView: View {
    @Bindable var viewModel: NutritionViewModel
    /// `nil` = autorisation en cours d'évaluation, `true`/`false` ensuite.
    @State private var cameraAuthorized: Bool?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.pulseBackground)
            .onAppear(perform: resolveAuthorization)
    }

    @ViewBuilder
    private var content: some View {
        if cameraAuthorized == nil {
            LoadingView(message: "Préparation de la caméra…")
        } else if cameraAuthorized == true && DataScannerViewController.isSupported {
            scanner
        } else {
            unavailable
        }
    }

    private var scanner: some View {
        ZStack(alignment: .bottom) {
            NutritionBarcodeScannerRepresentable { code in
                Task { await viewModel.lookupBarcode(code) }
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: PulseSpacing.md) {
                Text(viewModel.lookupMsg ?? "Vise le code-barres de l'emballage")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, PulseSpacing.md)
                    .padding(.vertical, PulseSpacing.sm)
                    .background(.black.opacity(0.6), in: Capsule())

                Button {
                    viewModel.openManual()
                } label: {
                    Text("Saisir à la main")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.pulseAccent)
                .padding(.horizontal, PulseSpacing.lg)
            }
            .padding(.bottom, PulseSpacing.xl)
        }
    }

    private var unavailable: some View {
        VStack(spacing: PulseSpacing.md) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.pulseTextSecondary)
            Text(unavailableMessage)
                .font(PulseFont.body)
                .foregroundStyle(Color.pulseTextPrimary)
                .multilineTextAlignment(.center)
            Button("Saisir à la main") {
                viewModel.openManual()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.pulseAccent)
            if cameraDenied {
                Button("Ouvrir les Réglages") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(PulseSpacing.xl)
    }

    private var cameraDenied: Bool {
        cameraAuthorized == false && DataScannerViewController.isSupported
    }

    private var unavailableMessage: String {
        if !DataScannerViewController.isSupported {
            return "Cet appareil ne peut pas scanner de code-barres. Saisis l'aliment à la main."
        }
        return "L'accès à la caméra est refusé. Autorise-le dans les Réglages pour scanner un code-barres."
    }

    private func resolveAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAuthorized = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in cameraAuthorized = granted }
            }
        default:
            cameraAuthorized = false
        }
    }
}

/// Enveloppe `DataScannerViewController` (VisionKit) : lecture de code-barres
/// EAN/UPC, un seul article à la fois, remontée du premier code lu via
/// `onScan`. L'anti-rebond (rafales de lecture du même code) et l'arrêt après
/// résolution vivent dans le VM (`isLookingUp`, bascule vers `.manual`).
private struct NutritionBarcodeScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        try? uiViewController.startScanning()
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                if case let .barcode(barcode) = item, let value = barcode.payloadStringValue {
                    onScan(value)
                    break
                }
            }
        }
    }
}
