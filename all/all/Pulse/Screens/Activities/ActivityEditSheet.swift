//
//  ActivityEditSheet.swift
//  all (bridge-connect)
//
//  Feuille « Modifier » d'une activité : nom, sport, début/fin (rognage), note,
//  aperçu de la FC pour repérer où la séance s'est vraiment arrêtée, et
//  « Rétablir l'original ». Logique dans `ActivityEditViewModel`. L'explication
//  d'usage vit dans Paramètres › Aide.
//

import SwiftUI
import Charts

struct ActivityEditSheet: View {
    @State private var vm: ActivityEditViewModel
    @State private var confirmReset = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Reçoit la réponse du serveur (détail à jour) après un succès.
    private let onSaved: (ActivityDetail) -> Void

    init(detail: ActivityDetail, client: PulseAPIClient = .shared, onSaved: @escaping (ActivityDetail) -> Void) {
        _vm = State(initialValue: ActivityEditViewModel(detail: detail, client: client))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nom") {
                    TextField(vm.currentLabel, text: $vm.name)
                        .textInputAutocapitalization(.sentences)
                }

                Section("Sport") {
                    Picker("Sport", selection: $vm.sport) {
                        ForEach(vm.sportOptions, id: \.self) { key in
                            Text(ActivitySport.name(sport: key)).tag(key)
                        }
                    }
                }

                if vm.sourceRange != nil {
                    Section("Durée") {
                        if !vm.previewPoints.isEmpty {
                            ActivityEditPreviewChart(points: vm.previewPoints, kept: vm.keptWindow)
                                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        }
                        DatePicker("Début", selection: $vm.start, in: vm.startRange, displayedComponents: [.date, .hourAndMinute])
                        DatePicker("Fin", selection: $vm.end, in: vm.endRange, displayedComponents: [.date, .hourAndMinute])
                    }
                }

                Section("Note") {
                    TextField("Note", text: $vm.note, axis: .vertical)
                        .lineLimit(3...8)
                }

                if vm.canReset {
                    Section {
                        Button("Rétablir l'original", role: .destructive) { confirmReset = true }
                            .disabled(vm.isSaving)
                    }
                }

                if let message = vm.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.pulseDanger)
                            .font(.footnote)
                            .accessibilityLabel("Erreur : \(message)")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.pulseBackground)
            .navigationTitle("Modifier")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(vm.isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                        .disabled(vm.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if vm.isSaving {
                        ProgressView()
                    } else {
                        Button("Enregistrer") { Task { await save() } }
                            .disabled(!vm.canSave)
                    }
                }
            }
            .confirmationDialog("Rétablir l'original ?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Rétablir l'original", role: .destructive) { Task { await reset() } }
                Button("Annuler", role: .cancel) {}
            }
        }
        .tint(Color.pulseAccent)
    }

    private func save() async {
        if let updated = await vm.save() {
            onSaved(updated)
            dismiss()
        }
    }

    private func reset() async {
        if let updated = await vm.resetOriginal() {
            onSaved(updated)
            dismiss()
        }
    }
}

/// Courbe de FC : zone gardée en couleur et surlignée, reste estompé.
private struct ActivityEditPreviewChart: View {
    let points: [ActivityPreviewPoint]
    let kept: ClosedRange<Double>?

    var body: some View {
        Chart {
            if let kept {
                RectangleMark(
                    xStart: .value("Début", kept.lowerBound),
                    xEnd: .value("Fin", kept.upperBound)
                )
                .foregroundStyle(Color.pulseHR.opacity(0.12))
            }
            ForEach(points.indices, id: \.self) { i in
                LineMark(x: .value("Temps", points[i].time), y: .value("FC", points[i].bpm), series: .value("Série", "tout"))
                    .foregroundStyle(Color.pulseHR.opacity(0.3))
                    .interpolationMethod(.monotone)
            }
            if let kept {
                ForEach(points.indices.filter { kept.contains(points[$0].time) }, id: \.self) { i in
                    LineMark(x: .value("Temps", points[i].time), y: .value("FC", points[i].bpm), series: .value("Série", "gardé"))
                        .foregroundStyle(Color.pulseHR)
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 90)
        .accessibilityElement()
        .accessibilityLabel("Courbe de fréquence cardiaque, zone conservée mise en évidence")
    }
}
