import AVFoundation
import SwiftUI
import UIKit

struct AddDeviceView: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var browser: DeviceBrowser
    @Environment(\.dismiss) private var dismiss

    @State private var target: Target?
    @State private var scanning = false
    @State private var manualAddress = ""
    @State private var manualError: String?

    /// Where a claim is headed once the user types the on-screen code.
    struct Target: Identifiable {
        var id: String { host + ":" + String(port) }
        var host: String
        var port: Int
        var name: String
        var product: String
        var deviceID: String
        var pin: TLSPin?
        var client: PigeonClient { PigeonClient(host: host, port: port, pin: pin) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Button { scanning = true } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "qrcode.viewfinder").font(.system(size: 30, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Scan Code").font(Theme.uiBold(18)).foregroundStyle(.white)
                                    Text("The code on a new Pigeon's Welcome screen sets it up in one step.")
                                        .font(Theme.ui(14)).foregroundStyle(Theme.secondaryText)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Theme.inactive)
                            }.tile()
                        }.buttonStyle(.plain)

                        LCDLabel(text: "Nearby", size: 18, color: Theme.accent).padding(.top, 6)
                        let fresh = browser.devices.filter { d in !store.devices.contains { $0.id == d.id } }
                        if fresh.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Looking for Pigeons on this network…").font(Theme.ui(15))
                                    .foregroundStyle(Theme.secondaryText)
                            }.tile()
                        }
                        ForEach(fresh) { d in
                            Button { Task { await pick(d) } } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        LCDLabel(text: d.name, size: 24)
                                        Text(d.needsSetup ? "Ready to set up" : d.claimed ? "Needs a new code" : "Ready to add")
                                            .font(Theme.ui(14)).foregroundStyle(Theme.secondaryText)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.inactive)
                                }.tile()
                            }.buttonStyle(.plain)
                        }

                        LCDLabel(text: "By address", size: 18, color: Theme.accent).padding(.top, 12)
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("192.168.1.42 or name.local", text: $manualAddress)
                                .font(Theme.ui(18))
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button { Task { await pickManual() } } label: {
                                Text("Connect").font(Theme.uiBold(16)).frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                            if let manualError { Text(manualError).font(Theme.ui(14)).foregroundStyle(Theme.bad) }
                        }.tile()
                    }
                    .padding(Theme.gutter)
                }
            }
            .navigationTitle("Add device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(item: $target) { t in
                ClaimView(target: t) { dismiss() }
            }
            .sheet(isPresented: $scanning) { QRScanSheet() }
        }
    }

    private func pick(_ d: DiscoveredDevice) async {
        guard let r = await DeviceBrowser.resolve(d.endpoint) else {
            manualError = "Couldn't reach \(d.name). Try adding it by address."
            return
        }
        await begin(Target(host: r.host, port: r.port, name: d.name, product: d.product, deviceID: d.id))
    }

    /// Make the device put its code on its own screen, then open the code entry sheet.
    private func begin(_ t: Target) async {
        var t = t
        do {
            // Learn the certificate pin before anything secret (the claim code, the token) is sent.
            // Older firmware has no `tls` and stays on plain HTTP.
            t.pin = try await PigeonClient(host: t.host, port: t.port).hello().tls?.pin
            try await t.client.pairStart()
            manualError = nil
            target = t
        } catch PigeonError.api(_, "already_claimed", _) {
            manualError = "\(t.name) already has a controller. Use Invite from the device it's paired with."
        } catch {
            manualError = error.localizedDescription
        }
    }

    private func pickManual() async {
        let raw = manualAddress.trimmingCharacters(in: .whitespaces)
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let host = parts[0]
        let port = parts.count > 1 ? Int(parts[1]) ?? 8780 : 8780
        do {
            let hello = try await PigeonClient(host: host, port: port).hello()
            await begin(Target(host: host, port: port, name: hello.name, product: hello.product, deviceID: hello.id))
        } catch { manualError = error.localizedDescription }
    }
}

struct ClaimView: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var setup: SetupCoordinator
    @Environment(\.dismiss) private var dismiss
    let target: AddDeviceView.Target
    var onDone: () -> Void

    @State private var code = ""
    @State private var busy = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack(spacing: 22) {
                LCDLabel(text: target.name, size: 34)
                Text("Enter the code now showing on \(target.name)'s screen.")
                    .font(Theme.ui(16)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                TextField("000000", text: $code)
                    .font(Theme.lcd(64))
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .onChange(of: code) { _, v in
                        code = String(v.filter(\.isNumber).prefix(6))
                        if code.count == 6 { Task { await claim() } }
                    }
                    .tile()
                if busy { ProgressView() }
                if let errorText { Text(errorText).font(Theme.ui(15)).foregroundStyle(Theme.bad).multilineTextAlignment(.center) }
                Spacer()
            }
            .padding(Theme.gutter)
            .padding(.top, 32)
        }
        .task { focused = true }
        .onDisappear {
            // Backing out (or finishing) clears the on-screen code. A successful claim already did.
            Task { await target.client.pairCancel() }
        }
        .presentationDetents([.medium])
    }

    private func claim() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await target.client
                .claim(code: code, controllerName: UIDevice.current.name, controllerID: store.controllerID)
            let known = KnownDevice(id: r.device.id, name: r.device.name, product: target.product,
                                    host: target.host, port: target.port, pin: target.pin)
            store.add(known, token: r.token)
            let needsSetup = (try? await store.client(for: known).setup()).map { !$0.isDone } ?? false
            dismiss()
            onDone()
            if needsSetup {
                // Let both sheets finish closing before the setup screen covers the app.
                let coordinator = setup
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    coordinator.present(.device(id: known.id))
                }
            }
        } catch let PigeonError.api(_, code, message) {
            errorText = code == "rate_limited" ? "Too many tries. Wait a minute." : message
            self.code = ""
        } catch {
            errorText = error.localizedDescription
            code = ""
        }
    }
}

// MARK: Scanning a Pigeon's code in the app

/// Scans the QR code on a Pigeon's Welcome screen with this device's camera and starts setup,
/// the same as scanning it with the Camera app.
struct QRScanSheet: View {
    @EnvironmentObject private var setup: SetupCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var notice: String?

    private var hasCamera: Bool { AVCaptureDevice.default(for: .video) != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if !hasCamera {
                    message("No camera", "This device can't scan. Use + › Nearby to add the Pigeon, "
                            + "or scan its code from a phone or tablet.")
                } else if access == .authorized {
                    QRScannerView { handle($0) }.ignoresSafeArea()
                    VStack {
                        Spacer()
                        Text(notice ?? "Point the camera at the code on the Pigeon's screen.")
                            .font(Theme.uiBold(16)).foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(14)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(Theme.gutter)
                    }
                } else if access == .notDetermined {
                    ProgressView()
                } else {
                    VStack(spacing: 16) {
                        message("Camera is off", "Allow Pigeon Remote to use the camera in Settings to scan a Pigeon's code.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .font(Theme.uiBold(16))
                    }
                }
            }
            .navigationTitle("Scan Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task {
            if access == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                access = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    private func handle(_ code: String) {
        guard let url = URL(string: code), setup.open(url) else {
            notice = "That isn't a Pigeon setup code. Scan the code on the Pigeon's Welcome screen."
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    private func message(_ title: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(Theme.uiBold(20)).foregroundStyle(.white)
            Text(text).font(Theme.ui(15)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
        }
        .padding(Theme.gutter)
    }
}

/// Live camera preview that reports each QR code it sees (the same code is reported once).
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let c = QRScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onCode = onCode
    }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastCode: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        if let connection = preview?.connection, let scene = view.window?.windowScene {
            let angle: CGFloat = switch scene.interfaceOrientation {
            case .landscapeLeft: 180
            case .landscapeRight: 0
            case .portraitUpsideDown: 270
            default: 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { if !session.isRunning { session.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { if session.isRunning { session.stopRunning() } }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              code != lastCode else { return }
        lastCode = code
        onCode?(code)
    }
}
