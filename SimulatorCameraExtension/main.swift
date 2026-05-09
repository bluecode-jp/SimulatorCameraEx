//
//  main.swift
//  SimulatorCameraExtension
//
//  Entry point for the Camera Extension. Boots the CMIOExtensionProvider
//  and runs forever as a system extension daemon. Loaded by the macOS
//  CoreMediaIO subsystem after the user clicks Allow in System Settings.
//

import Foundation
import CoreMediaIO

let providerSource = SimulatorCameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
