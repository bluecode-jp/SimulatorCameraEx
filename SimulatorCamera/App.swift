//
//  App.swift
//  SimulatorCamera (container app)
//
//  SwiftUI entry point. Hosts the single-window UI that owns extension
//  activation state. v1.0.0 Phase 1 ships test-pattern-only — no source
//  picker, no Mac camera capture yet. The button activates the bundled
//  Camera Extension; macOS shows System Settings approval the first time.
//

import SwiftUI

@main
struct SimulatorCameraApp: App {
    @State private var controller = ExtensionController()

    var body: some Scene {
        WindowGroup("SimulatorCamera") {
            MainView()
                .environment(controller)
                .frame(minWidth: 480, minHeight: 360)
        }
        .windowResizability(.contentSize)
    }
}
