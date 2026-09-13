//
//  App.swift
//  SimulatorCamera (container app)
//
//  SwiftUI entry point. Hosts ExtensionController (system extension state),
//  XPCClient (connection to running extension), SourceManager (active
//  frame source). Single window UI exposes the 5 sources matching SimCam
//  feature parity: test pattern, Mac camera, video file, image, QR code.
//

import SwiftUI

@main
struct SimulatorCameraApp: App {
    @State private var extensionController = ExtensionController()
    @State private var xpcClient: XPCClient
    @State private var sourceManager: SourceManager

    init() {
        let xpc = XPCClient()
        _xpcClient = State(initialValue: xpc)
        _sourceManager = State(initialValue: SourceManager(xpc: xpc))
    }

    var body: some Scene {
        WindowGroup("SimulatorCamera") {
            MainView()
                .environment(extensionController)
                .environment(xpcClient)
                .environment(sourceManager)
                .frame(minWidth: 540, minHeight: 520)
                .task {
                    extensionController.check()
                    xpcClient.connect()
                }
        }
        .windowResizability(.contentSize)
    }
}
