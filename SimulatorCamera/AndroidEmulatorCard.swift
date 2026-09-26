//
//  AndroidEmulatorCard.swift
//  SimulatorCamera
//
//  Launch an Android Emulator AVD with the virtual camera as its camera
//  (see Shared/AndroidEmulator.swift). Frames come from the CMIO extension,
//  so whatever source is picked above shows up in Android apps.
//

import SwiftUI

struct AndroidEmulatorCard: View {
    @AppStorage("androidAVD") private var selectedAVD = ""
    @AppStorage("androidUseFrontCamera") private var useFrontCamera = false
    @State private var avds: [String] = []
    @State private var cameraLabel: String?
    @State private var status: String?
    @State private var statusIsError = false
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Android Emulator").font(.headline)
            HStack {
                Picker("AVD", selection: $selectedAVD) {
                    if avds.isEmpty { Text("No AVDs").tag("") }
                    ForEach(avds, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                .disabled(avds.isEmpty)
                Button("Refresh") { refresh() }
                    .controlSize(.small)
                    .disabled(isBusy)
                Toggle("Front camera too", isOn: $useFrontCamera)
                    .font(.callout)
                Spacer()
                Button("Launch") { launch() }
                    .disabled(isBusy || !avds.contains(selectedAVD))
            }
            Text("Starts the emulator with '\(kSimCamDeviceName)'\(cameraLabel.map { " (\($0))" } ?? "") as its back camera; Android apps then see the source above. Choose the back camera in the app if it opens the front one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .task { refresh() }
    }

    /// The emulator binary takes a second or two to answer, so ask off the main thread.
    private func refresh() {
        isBusy = true
        Task {
            let result = await Task.detached { () -> Result<([String], String?), Error> in
                Result { (try AndroidEmulator.listAVDs(), try? AndroidEmulator.webcamLabel()) }
            }.value
            isBusy = false
            switch result {
            case .success(let (list, label)):
                avds = list
                cameraLabel = label
                if !list.contains(selectedAVD) { selectedAVD = list.first ?? "" }
                if label == nil {
                    show(AndroidEmulator.Failure.cameraNotFound.localizedDescription, error: true)
                } else if list.isEmpty {
                    show("No AVDs yet. Create one in Android Studio's Device Manager, then Refresh.", error: false)
                } else {
                    status = nil
                }
            case .failure(let error):
                avds = []
                cameraLabel = nil
                show(error.localizedDescription, error: true)
            }
        }
    }

    private func launch() {
        let avd = selectedAVD
        let front = useFrontCamera
        isBusy = true
        show("Starting \(avd)…", error: false)
        Task {
            let result = await Task.detached { Result { try AndroidEmulator.launch(avd: avd, front: front) } }.value
            isBusy = false
            switch result {
            case .success(let label):
                cameraLabel = label
                show("\(avd) started with \(label). Log: \(AndroidEmulator.logURL(avd: avd).path)", error: false)
            case .failure(let error):
                show(error.localizedDescription, error: true)
            }
        }
    }

    private func show(_ message: String, error: Bool) {
        status = message
        statusIsError = error
    }
}
