//
//  MainView.swift
//  SimulatorCamera
//
//  v1.0 UI matching SimCam feature surface: extension activation status,
//  source picker (test pattern, Mac camera, video file, image, QR code),
//  Run Diagnostics, frame counter.
//

import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(ExtensionController.self) private var extensionController
    @Environment(CameraLink.self) private var link
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SimulatorAutoEnabler.self) private var simulatorAutoEnabler
    @State private var simulatorOrientation = SimulatorFeed.shared.orientation
    /// Cameras for the Mac Camera picker, as (uniqueID, name).
    @State private var cameras: [(id: String, name: String)] = []
    private static let contentSpace = "MainView.content"

    /// Window height last set by fitWindow; nil until the first fit.
    @State private var fittedWindowHeight: CGFloat?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                extensionStatusCard
                sourcePicker
                    // Initial window height: down to the Source card plus the
                    // 20 pt gap before the next card (the VStack spacing), so
                    // no sliver of the cards below shows; they are one scroll
                    // (or a taller window) away.
                    .onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .named(Self.contentSpace)).maxY
                    } action: { maxY in
                        fitWindow(toContentHeight: maxY + 20)
                    }
                simulatorCard
                diagnosticsCard
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
            .coordinateSpace(.named(Self.contentSpace))
        }
    }

    /// The window opens before SwiftUI knows how tall the cards are, and
    /// they can grow later (status and error lines). Keep the window as tall
    /// as `height` of content — capped to the screen, title bar kept in
    /// place — until the user resizes it by hand, then leave their size alone.
    private func fitWindow(toContentHeight height: CGFloat) {
        guard height > 0 else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let screen = window.screen ?? NSScreen.main else { return }
            if let fitted = fittedWindowHeight, abs(window.frame.height - fitted) > 1 { return }  // user resized
            let chrome = window.frame.height - window.contentLayoutRect.height
            let target = min(height + chrome, screen.visibleFrame.height)
            guard abs(window.frame.height - target) > 1 else { fittedWindowHeight = target; return }
            var frame = window.frame
            frame.origin.y += frame.height - target
            frame.size.height = target
            frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY)
            window.setFrame(frame, display: true, animate: false)
            fittedWindowHeight = target
        }
    }

    // MARK: - Header

    private var header: some View {
        // Icon and name side by side, compact: the cards below are the point.
        HStack(spacing: 10) {
            Image("HeaderIcon")   // asset copy of the app icon; see scripts/make-icon.swift
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("SimulatorCameraEx")
                    .font(.title3.bold())
                Text("Your Mac's camera, in the iOS Simulator. Free and open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Extension status

    private var extensionStatusCard: some View {
        @Bindable var ec = extensionController
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(extensionStatusColor).frame(width: 10, height: 10)
                Text(extensionStatusLabel).font(.headline)
                Spacer()
                Button(extensionActionLabel, action: handleExtensionAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(extensionActionDisabled)
            }
            if !ec.lastMessage.isEmpty {
                Text(ec.lastMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - iOS Simulator

    private var simulatorCard: some View {
        @Bindable var auto = simulatorAutoEnabler
        return VStack(alignment: .leading, spacing: 8) {
            Text("iOS Simulator").font(.headline)
            Toggle("Enable the camera in iOS Simulators automatically when they boot", isOn: $auto.isEnabled)
                .font(.callout)
            HStack {
                Text("Frame orientation").font(.callout)
                Picker("Frame orientation", selection: $simulatorOrientation) {
                    Text("Portrait 720×1280").tag(SimulatorFeed.Orientation.portrait)
                    Text("Landscape 1280×720").tag(SimulatorFeed.Orientation.landscape)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: simulatorOrientation) { _, value in
                    SimulatorFeed.shared.orientation = value
                }
                .onReceive(NotificationCenter.default.publisher(for: .simulatorOrientationChanged)) { _ in
                    simulatorOrientation = SimulatorFeed.shared.orientation
                }
            }
            Text("Portrait fills an upright iPhone camera view; landscape suits apps that rotate the camera. The Mac virtual camera always gets landscape.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(simulatorStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let err = simulatorAutoEnabler.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var simulatorStatusText: String {
        guard simulatorAutoEnabler.isEnabled else {
            return "Off. Use `simcamctl sim-enable` or `sim-launch` to load the camera by hand."
        }
        let devices = simulatorAutoEnabler.enabledDevices
        if devices.isEmpty { return "Waiting for a simulator to boot…" }
        return "Camera enabled in: " + devices.joined(separator: ", ")
            + ". Apps launched from now on get the camera; relaunch apps that were already open."
    }

    // MARK: - Source picker

    private var sourcePicker: some View {
        @Bindable var sm = sourceManager
        return VStack(alignment: .leading, spacing: 14) {
            Text("Source").font(.headline)

            sourceRow(.testPattern, icon: "tv", title: "Test Pattern (Color Bar)", subtitle: "Moving colour bars, built in. No setup.")
            macCameraRow

            Divider()

            qrRow
            code128Row
            ean13Row

            Divider()

            videoFileRow
            imageFileRow

            if let err = sourceManager.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }

            HStack {
                Text(frameCounterText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if sourceManager.isSwitching {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if sourceManager.activeKind != .testPattern || sourceManager.isSwitching {
                    Button("Stop") { sourceManager.stop() }
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Mac Camera row plus a picker for which camera to use; changing it
    /// while the camera is live switches immediately.
    private var macCameraRow: some View {
        @Bindable var sm = sourceManager
        return HStack(spacing: 10) {
            sourceRow(.macCamera, icon: "camera.fill", title: "Mac Camera",
                      subtitle: "Live webcam. First use prompts for camera access.",
                      showsCheckmark: false)
            Picker("Camera", selection: $sm.selectedCameraID) {
                Text("Automatic").tag(String?.none)
                ForEach(cameras, id: \.id) { camera in
                    Text(camera.name).tag(Optional(camera.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: sourceManager.selectedCameraID) { _, id in
                // simcamctl --camera sets the ID and restarts the source itself.
                if sourceManager.activeKind == .macCamera, id != sourceManager.activeCameraID {
                    switchSource(.macCamera)
                }
            }
            if sourceManager.activeKind == .macCamera {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            }
        }
        .onAppear(perform: reloadCameras)
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in reloadCameras() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in reloadCameras() }
    }

    private func reloadCameras() {
        var list = MacCameraSource.cameraList()
        // Keep a remembered camera selectable while it is unplugged.
        if let id = sourceManager.selectedCameraID, !list.contains(where: { $0.id == id }) {
            list.append((id: id, name: "Unavailable camera"))
        }
        cameras = list
    }

    private func sourceRow(
        _ kind: SimCamSourceKind,
        icon: String,
        title: String,
        subtitle: String,
        showsCheckmark: Bool = true
    ) -> some View {
        let isActive = sourceManager.activeKind == kind
        return Button {
            switchSource(kind)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(isActive ? .semibold : .regular))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isActive && showsCheckmark {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var videoFileRow: some View {
        @Bindable var sm = sourceManager
        return HStack(spacing: 10) {
            Image(systemName: "film.fill")
                .font(.title3)
                .foregroundStyle(sourceManager.activeKind == .videoFile ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Video File").font(.callout)
                Text(sourceManager.selectedFileURL?.lastPathComponent ?? "Pick an MP4 / MOV file…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Browse…") { pickVideoFile() }.controlSize(.small)
            Button("Use") { switchSource(.videoFile) }
            .controlSize(.small)
            .disabled(sourceManager.selectedFileURL == nil || sourceManager.isSwitching)
        }
    }

    private var imageFileRow: some View {
        return HStack(spacing: 10) {
            Image(systemName: "photo.fill")
                .font(.title3)
                .foregroundStyle(sourceManager.activeKind == .image ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Static Image").font(.callout)
                Text(sourceManager.selectedImageURL?.lastPathComponent ?? "Pick a PNG / JPG file…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Browse…") { pickImageFile() }.controlSize(.small)
            Button("Use") { switchSource(.image) }
            .controlSize(.small)
            .disabled(sourceManager.selectedImageURL == nil || sourceManager.isSwitching)
        }
    }

    private var qrRow: some View {
        @Bindable var sm = sourceManager
        return payloadRow(.qrCode, icon: "qrcode", title: "QR Code",
                          placeholder: "Payload (URL or string)", text: $sm.qrPayload)
    }

    private var code128Row: some View {
        @Bindable var sm = sourceManager
        return payloadRow(.code128, icon: "barcode", title: "Code 128",
                          placeholder: "Text (ASCII)", text: $sm.code128Payload)
    }

    private var ean13Row: some View {
        @Bindable var sm = sourceManager
        let code = BarcodeRenderer.ean13(from: sourceManager.ean13Payload)
        return payloadRow(.ean13, icon: "barcode", title: "EAN-13",
                          placeholder: "1–12 digits (check digit added) or 13 digits",
                          text: $sm.ean13Payload,
                          note: code.map { "Encodes \($0)" } ?? "Not a valid EAN-13 — use 1–12 digits, or 13 with a correct check digit",
                          valid: code != nil)
    }

    /// Title on its own line, then field + button in one row so the button
    /// is vertically centred on the text field (not on title and field
    /// together, which pushed it up).
    private func payloadRow(
        _ kind: SimCamSourceKind,
        icon: String,
        title: String,
        placeholder: String,
        text: Binding<String>,
        note: String? = nil,
        valid: Bool = true
    ) -> some View {
        let isEmpty = text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(sourceManager.activeKind == kind ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(sourceManager.activeKind == kind ? .semibold : .regular))
                HStack(alignment: .center, spacing: 10) {
                    TextField(placeholder, text: text)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Generate") { switchSource(kind) }
                        .controlSize(.small)
                        .disabled(isEmpty || !valid || sourceManager.isSwitching)
                }
                if let note {
                    Text(note)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(valid ? Color.secondary : Color.red)
                }
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Diagnostics").font(.headline)
                Spacer()
                Button("Run Diagnostics") {
                    runDiagnostics()
                }
                .controlSize(.small)
            }
            HStack(spacing: 16) {
                diagnosticItem("Extension", state: extensionStatusLabel, ok: extensionController.state == .active)
                diagnosticItem("Camera link", state: linkStateDescription, ok: link.isConnected)
                diagnosticItem("Capture", state: captureDescription, ok: link.extensionStatus?.isStreamRunning == true)
                diagnosticItem("Delivery", state: deliveryDescription, ok: link.framesRejected == 0)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func diagnosticItem(_ name: String, state: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption.bold())
            HStack(spacing: 4) {
                Circle().fill(ok ? Color.green : Color.gray).frame(width: 6, height: 6)
                Text(state).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("iOS Simulator apps get this source as their camera")
                .font(.caption.bold())
            Text("AVCaptureDevice.default(for: .video) returns it and barcode scanning works, with no app changes. Switch sources from the command line with `simcamctl set-source`. Mac apps can use '\(kSimCamDeviceName)' once the extension is active.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived state

    private var extensionStatusColor: Color {
        switch extensionController.state {
        case .unknown, .checking, .inactive: return .gray
        case .activating, .awaitingApproval, .deactivating: return .orange
        case .active: return .green
        case .error: return .red
        }
    }

    private var extensionStatusLabel: String {
        switch extensionController.state {
        case .unknown: return "Not checked"
        case .checking: return "Checking…"
        case .inactive: return "Inactive"
        case .activating: return "Activating…"
        case .awaitingApproval: return "Awaiting approval"
        case .active: return "Active"
        case .deactivating: return "Deactivating…"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var extensionActionLabel: String {
        switch extensionController.state {
        case .active: return "Deactivate"
        case .activating, .deactivating: return "Working…"
        default: return "Activate"
        }
    }

    private var extensionActionDisabled: Bool {
        switch extensionController.state {
        case .activating, .deactivating, .checking: return true
        default: return false
        }
    }

    private var frameCounterText: String {
        var parts = ["Frames pushed: \(sourceManager.framesPushed)"]
        if link.framesDropped > 0 { parts.append("dropped: \(link.framesDropped)") }
        if link.framesRejected > 0 { parts.append("rejected: \(link.framesRejected)") }
        if let received = link.extensionStatus?.framesReceived, received > 0 {
            parts.append("received by extension: \(received)")
        }
        // Re-evaluated whenever the counters above change (every few frames,
        // or the 1 s status poll), which is often enough for a client count.
        parts.append("iOS Simulator apps: \(SimulatorFeed.shared.clientCount)")
        return parts.joined(separator: " · ")
    }

    private var deliveryDescription: String {
        if link.framesRejected > 0 {
            return "\(link.framesRejected) rejected — sink not open?"
        }
        if link.framesDropped > 0 {
            return "\(link.framesDropped) dropped (extension busy)"
        }
        if let rejected = link.extensionStatus?.framesRejected, rejected > 0 {
            return "extension rejected \(rejected)"
        }
        return "OK"
    }

    private var captureDescription: String {
        guard let status = link.extensionStatus else { return "Unknown" }
        if status.isStreamRunning {
            return "\(status.connectedClientCount) client(s) capturing"
        }
        return "No app is capturing from the virtual camera"
    }

    private var linkStateDescription: String {
        switch link.connectionState {
        case .disconnected: return "Disconnected"
        case .searching: return "Looking for the virtual camera…"
        case .connected: return "Connected"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    // MARK: - Actions

    private func switchSource(_ kind: SimCamSourceKind) {
        Task {
            do {
                try await sourceManager.switchTo(kind)
            } catch {
                // switchTo already surfaced the message via lastError; nothing to add.
            }
        }
    }

    private func handleExtensionAction() {
        switch extensionController.state {
        case .active: extensionController.deactivate()
        default: extensionController.activate()
        }
    }

    private func pickVideoFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sourceManager.selectedFileURL = url
        }
    }

    private func pickImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sourceManager.selectedImageURL = url
        }
    }

    private func runDiagnostics() {
        extensionController.check()
        link.connect()
        link.refreshStatus()
    }
}
