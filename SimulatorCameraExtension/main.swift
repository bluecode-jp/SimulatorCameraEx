//
//  main.swift
//  SimulatorCameraExtension
//
//  Entry point for the Camera Extension. Starts the CMIOExtensionProvider
//  AND the XPC listener so the container app can push frames + control
//  source switching. Runs forever as a system extension daemon.
//

import Foundation
import CoreMediaIO

let providerSource = SimulatorCameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

// XPC listener is owned by the device source so it can wire frame-injection
// and source-switch hooks directly. providerSource sets it up.

CFRunLoopRun()
