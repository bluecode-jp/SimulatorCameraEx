//
//  MainView.swift
//  SimulatorCamera
//
//  v1.0.0 Phase 1 UI. One window. One job: prove the bundled Camera
//  Extension activates, registers a virtual camera, and shows up in
//  AVFoundation. Source picker arrives in Phase 2.
//

import SwiftUI

struct MainView: View {
    @Environment(ExtensionController.self) private var controller

    var body: some View {
        VStack(spacing: 24) {
            header
            statusCard
            actionButton
            footer
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "video.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("SimulatorCamera")
                .font(.title.bold())
            Text("Your Mac's camera, in the iOS Simulator. Free and open.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusLabel)
                    .font(.headline)
            }
            if !controller.lastMessage.isEmpty {
                Text(controller.lastMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var actionButton: some View {
        Button(action: handleAction) {
            HStack {
                Image(systemName: actionIcon)
                Text(actionLabel)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(actionDisabled)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Once the extension is active:")
                .font(.subheadline.bold())
            Text("1. Open the iOS Simulator and launch a camera-using app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("2. AVCaptureDevice.default(for: .video) returns 'SimulatorCamera Virtual'.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("3. v1.0.0 ships a scrolling-stripe test pattern. Mac camera source lands in v1.1.")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.7))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived UI state

    private var statusColor: Color {
        switch controller.state {
        case .unknown, .checking, .inactive: return .gray
        case .activating, .awaitingApproval, .deactivating: return .orange
        case .active: return .green
        case .error: return .red
        }
    }

    private var statusLabel: String {
        switch controller.state {
        case .unknown: return "Not checked"
        case .checking: return "Checking..."
        case .inactive: return "Inactive"
        case .activating: return "Activating..."
        case .awaitingApproval: return "Waiting for your approval in System Settings"
        case .active: return "Active — virtual camera available"
        case .deactivating: return "Deactivating..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var actionLabel: String {
        switch controller.state {
        case .active: return "Deactivate Extension"
        case .activating, .deactivating: return "Working..."
        default: return "Activate Extension"
        }
    }

    private var actionIcon: String {
        switch controller.state {
        case .active: return "stop.circle.fill"
        default: return "play.circle.fill"
        }
    }

    private var actionDisabled: Bool {
        switch controller.state {
        case .activating, .deactivating, .checking: return true
        default: return false
        }
    }

    private func handleAction() {
        switch controller.state {
        case .active: controller.deactivate()
        default: controller.activate()
        }
    }
}

#Preview {
    MainView()
        .environment(ExtensionController())
        .frame(width: 480, height: 420)
}
