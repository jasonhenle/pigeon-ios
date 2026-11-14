import SwiftUI
import UIKit

/// First-run setup, started by scanning a Pigeon's Welcome screen (or after pairing one that still
/// needs setup): find it on the network, pair, then location, player, audio, done.
@MainActor
final class SetupFlowModel: ObservableObject {
    enum Phase: Equatable {
        case connecting(String)
        case failed(String)
        case location
        case player
        case audio
        case finished
    }

    /// Wizard steps in order, with the step names the device records (`PUT /setup`).
    static let steps: [Phase] = [.location, .player, .audio]

    @Published private(set) var phase: Phase = .connecting("Getting ready…")
    @Published private(set) var busy = false
    @Published var errorText: String?
    @Published var zip = ""
    @Published private(set) var settings: PigeonSettings?
    /// The player / audio search for the current step, followed and driven from here.
    @Published private(set) var pairing: DevicePairingModel?
    @Published private(set) var skipped: [String] = []
    @Published private(set) var deviceName = "Pigeon"
    /// Ask whether to share now playing data: once, as setup finishes, if this Pigeon was never asked.
    @Published var askShareData = false
    private(set) var deviceID: String?

    private var store: DeviceStore?
    private var client: PigeonClient? {
        guard let store, let id = deviceID, let d = store.devices.first(where: { $0.id == id }) else { return nil }
        return store.client(for: d)
    }

    static func stepName(_ p: Phase) -> String? {
        switch p {
        case .location: return "location"
        case .player: return "player"
        case .audio: return "audio"
        default: return nil
        }
    }

    var stepNumber: Int? { Self.steps.firstIndex(of: phase).map { $0 + 1 } }

    /// There is an earlier step to go back to.
    var canGoBack: Bool { (Self.steps.firstIndex(of: phase) ?? 0) > 0 }

    /// Time zone this device uses, when the Pigeon offers it.
    var deviceTimeZone: String? {
        let tz = TimeZone.current.identifier
        return settings?.timezoneChoices.contains(tz) == true ? tz : nil
    }

    func start(_ request: SetupCoordinator.Request, store: DeviceStore, browser: DeviceBrowser) async {
        self.store = store
        switch request {
        case .device(let id):
            deviceID = id
            deviceName = store.devices.first { $0.id == id }?.name ?? "Pigeon"
            await beginWizard()
        case .link(let link):
            deviceName = link.name
            await connect(link, store: store, browser: browser)
        }
    }

    // MARK: Connect and pair

    private func connect(_ link: SetupLink, store: DeviceStore, browser: DeviceBrowser) async {
        phase = .connecting("Looking for \(link.name)…")
        browser.start()
        var addr: (host: String, port: Int)?
        // The address on the Pigeon's screen first: no mDNS lookup to wait on. Checked by id here and by
        // the certificate pin when pairing, so a stale address can't reach the wrong device.
        if let host = link.host {
            let port = link.port ?? 8780
            let hello: Hello? = try? await PigeonClient(host: host, port: port).send("GET", "/hello", timeout: 4)
            if hello?.id == link.deviceID { addr = (host, port) }
        }
        // Otherwise wait for its mDNS advertisement and an address; a lookup can time out, so keep trying.
        let deadline = Date().addingTimeInterval(25)
        while addr == nil, Date() < deadline {
            if let found = browser.devices.first(where: { $0.id == link.deviceID }) {
                addr = await DeviceBrowser.resolve(found.endpoint)
                if addr != nil { break }
            }
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
        }
        guard let addr else {
            phase = .failed("Couldn't find \(link.name). Make sure this device is on the same Wi-Fi network as "
                            + "the Pigeon, then scan the code again.")
            return
        }
        deviceID = link.deviceID

        // Already paired with this device (setup was interrupted): pick up where it stopped.
        if store.devices.contains(where: { $0.id == link.deviceID }), store.token(for: link.deviceID) != nil {
            store.updateAddress(id: link.deviceID, host: addr.host, port: addr.port)
            if (try? await client?.setup()) != nil {
                await beginWizard()
                return
            }
        }

        phase = .connecting("Pairing with \(link.name)…")
        let hello: Hello
        do {
            hello = try await PigeonClient(host: addr.host, port: addr.port).hello()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        guard hello.id == link.deviceID else {
            phase = .failed("A different Pigeon answered. Scan the code again.")
            return
        }
        // The fingerprint came from the Pigeon's screen, so it is trusted as is; only the port comes
        // from the network (a wrong one just fails the pinned connection).
        var pin: TLSPin?
        if let fp = link.fingerprint {
            guard let tls = hello.tls else {
                phase = .failed("Couldn't connect to \(link.name) securely. Scan the code again.")
                return
            }
            pin = TLSPin(port: tls.port, fingerprint: fp)
        } else {
            pin = hello.tls?.pin
        }
        guard let code = link.code else {
            phase = .failed("\(link.name) is being set up from another device. Finish there, or factory reset "
                            + "the Pigeon to start over.")
            return
        }
        do {
            let r = try await PigeonClient(host: addr.host, port: addr.port, pin: pin)
                .claim(code: code, controllerName: UIDevice.current.name, controllerID: store.controllerID)
            deviceName = r.device.name
            store.add(KnownDevice(id: r.device.id, name: r.device.name, product: hello.product,
                                  host: addr.host, port: addr.port, pin: pin), token: r.token)
        } catch PigeonError.transport {
            phase = .failed("Couldn't connect to \(link.name) securely. Scan the code again.")
            return
        } catch PigeonError.api(_, "not_claimed", _) {
            phase = .failed("That code has expired. Scan the code on the Pigeon's screen again.")
            return
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        await beginWizard()
    }

    // MARK: Wizard

    private func beginWizard() async {
        guard let client else { phase = .failed("This Pigeon isn't paired with this device."); return }
        do {
            let s = try await client.setup()
            skipped = s.skipped
            if s.isDone { await finish(); return }
            settings = try? await client.pigeonSettings()
            zip = settings?.zip ?? ""
            let resume = Self.steps.first { Self.stepName($0) == s.step } ?? .location
            await go(to: resume)
        } catch PigeonError.api(_, "unsupported", _) {
            await finish()  // firmware without setup: nothing to walk through
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func go(to next: Phase) async {
        // Leaving a player / audio step closes its search, so the Pigeon never shows both at once.
        if let p = pairing {
            pairing = nil
            await p.leave()
        }
        errorText = nil
        if next == .finished {
            await run {
                guard let client = self.client else { return }
                // Record a skip of the last step too; complete keeps whatever was reported last.
                _ = try await client.setSetupProgress(step: "finish", skipped: self.skipped)
                self.skipped = try await client.completeSetup().skipped
            }
            if errorText == nil { await finish() }
            return
        }
        phase = next
        if (next == .player || next == .audio), let client {
            pairing = DevicePairingModel(client: client, kind: next == .audio ? "audio" : "player")
        }
        if let name = Self.stepName(next) {
            _ = try? await client?.setSetupProgress(step: name, skipped: skipped)
        }
    }

    /// Back to the previous step (its answer stays; Continue or Skip moves on again).
    func back() async {
        guard let i = Self.steps.firstIndex(of: phase), i > 0 else { return }
        await go(to: Self.steps[i - 1])
    }

    /// Leaving with "Later": close any search the wizard started.
    func close() async {
        if let p = pairing {
            pairing = nil
            await p.leave()
        }
    }

    private func finish() async {
        phase = .finished
        // Firmware without the privacy switch (422) or an error: nothing to ask.
        if let p = try? await client?.privacy(), !p.asked { askShareData = true }
    }

    func chooseShareData(_ on: Bool) async {
        await run {
            guard let client = self.client else { return }
            _ = try await client.setShareData(on)
        }
    }

    private func advance() async {
        let i = Self.steps.firstIndex(of: phase) ?? Self.steps.count
        await go(to: i + 1 < Self.steps.count ? Self.steps[i + 1] : .finished)
    }

    func skip() async {
        if let name = Self.stepName(phase), !skipped.contains(name) { skipped.append(name) }
        await advance()
    }

    func next() async {
        if let name = Self.stepName(phase) { skipped.removeAll { $0 == name } }
        await advance()
    }

    func saveZip() async {
        let z = zip.trimmingCharacters(in: .whitespaces)
        guard z.count == 5, z.allSatisfy(\.isNumber) else { errorText = "Enter a 5-digit ZIP code."; return }
        await run {
            guard let client = self.client else { return }
            self.settings = try await client.patchPigeonSettings(.init(zip: z, timezone: nil, options: nil, uiColor: nil))
        }
        if errorText == nil { await next() }
    }

    func useDeviceTimeZone() async {
        guard let tz = deviceTimeZone else { return }
        await run {
            guard let client = self.client else { return }
            self.settings = try await client.patchPigeonSettings(.init(zip: nil, timezone: tz, options: nil, uiColor: nil))
        }
        if errorText == nil { await next() }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await work(); errorText = nil } catch { errorText = error.localizedDescription }
    }
}

struct SetupFlowView: View {
    let request: SetupCoordinator.Request
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var browser: DeviceBrowser
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SetupFlowModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let n = model.stepNumber {
                            Text("STEP \(n) OF \(SetupFlowModel.steps.count)")
                                .font(Theme.uiBold(13)).foregroundStyle(Theme.accent)
                        }
                        content
                        if let e = model.errorText {
                            Text(e).font(Theme.ui(14)).foregroundStyle(Theme.bad)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.gutter)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Set up \(model.deviceName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.canGoBack {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { Task { await model.back() } } label: {
                            Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                        }
                        .disabled(model.busy)
                    }
                }
                if model.phase != .finished {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Later") { Task { await model.close(); dismiss() } }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .task { await model.start(request, store: store, browser: browser) }
        .alert("Help improve Pigeon?", isPresented: $model.askShareData) {
            Button("Share") { Task { await model.chooseShareData(true) } }
            Button("Don't Share", role: .cancel) { Task { await model.chooseShareData(false) } }
        } message: {
            Text("\(DataSharing.title)? \(DataSharing.note) You can change this anytime in System › Privacy.")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .connecting(let message):
            HStack(spacing: 12) {
                ProgressView()
                Text(message).font(Theme.ui(17)).foregroundStyle(.white)
            }
            .padding(.top, 40)
            .frame(maxWidth: .infinity)

        case .failed(let message):
            Heading(title: "Couldn't set up", text: message)
            PrimaryButton(title: "Close") { dismiss() }

        case .location:
            Heading(title: "Where is it?", text: "Enter ZIP code for timezone. Pigeon also uses it for the weather.")
            TextField("ZIP code", text: $model.zip)
                .font(Theme.lcd(44))
                .keyboardType(.numberPad)
                .textContentType(.postalCode)
                .onChange(of: model.zip) { _, v in model.zip = String(v.filter(\.isNumber).prefix(5)) }
                .tile()
            PrimaryButton(title: "Continue", busy: model.busy, disabled: model.zip.count != 5) {
                Task { await model.saveZip() }
            }
            if let tz = model.deviceTimeZone {
                SecondaryButton(title: "Use this device's time zone (\(tz.replacingOccurrences(of: "_", with: " ")))") {
                    Task { await model.useDeviceTimeZone() }
                }
            }
            SecondaryButton(title: "Skip for now") { Task { await model.skip() } }

        case .player:
            pairingStep(
                title: "Connect a player",
                text: "Pigeon shows what's playing on your Apple TV, Roku or other streaming player.")

        case .audio:
            pairingStep(
                title: "Connect audio",
                text: "Pair your AV receiver so Pigeon can show its volume.")

        case .finished:
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.ok)
                Heading(title: "\(model.deviceName) is set up", text: finishedText)
            }
            .padding(.top, 24)
            PrimaryButton(title: "Done") {
                if let id = model.deviceID { store.selectedID = id }
                dismiss()
            }
        }
    }

    private var finishedText: String {
        let names = model.skipped.compactMap { ["location": "location", "player": "a player", "audio": "audio"][$0] }
        guard !names.isEmpty else { return "Everything's ready." }
        return "You can add \(names.joined(separator: " and ")) anytime from this Pigeon's settings in the app."
    }

    @ViewBuilder private func pairingStep(title: String, text: String) -> some View {
        Heading(title: title, text: text)
        if let pairing = model.pairing {
            DevicePairingPanel(model: pairing) {
                PrimaryButton(title: "Continue", busy: model.busy) { Task { await model.next() } }
            }
        }
        SecondaryButton(title: "Skip for now") { Task { await model.skip() } }
    }
}

private struct Heading: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.uiBold(28)).foregroundStyle(.white)
            Text(text).font(Theme.ui(16)).foregroundStyle(Theme.secondaryText)
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    var busy = false
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).font(Theme.uiBold(17)).opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(.black) }
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(Theme.accent.opacity(disabled ? 0.4 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .disabled(busy || disabled)
    }
}

private struct SecondaryButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.uiBold(16)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Theme.tile, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
    }
}

// MARK: Pairing a player or audio device from the app

/// Follows the Pigeon's own search for a player or audio device and drives it from here: the
/// results, the pick and the Apple TV codes (1 of 2, 2 of 2), so nobody has to touch the Pigeon.
/// Firmware that can't be driven (no `/rooms/{id}/pairing/{kind}`) falls back to picking on its screen.
@MainActor
final class DevicePairingModel: ObservableObject {
    let kind: String
    @Published private(set) var status: PairingStatus?
    /// A search was started from here.
    @Published private(set) var started = false
    /// Older firmware: the pick happens on the Pigeon's screen.
    @Published private(set) var onDeviceOnly = false
    @Published private(set) var busy = false
    @Published var pin = ""
    @Published var errorText: String?

    private let client: PigeonClient
    private var room: String?
    private var poll: Task<Void, Never>?

    init(client: PigeonClient, kind: String) {
        self.client = client
        self.kind = kind
    }

    var noun: String { kind == "audio" ? "audio devices" : "players" }
    var state: String { status?.state ?? (started ? "scanning" : "idle") }
    var paired: Bool { state == "paired" }

    func search() async {
        busy = true
        defer { busy = false }
        do {
            let rooms = try await client.rooms()
            room = rooms.current
            try await client.startPairing(room: rooms.current, kind: kind)
            started = true
            status = nil
            pin = ""
            errorText = nil
            follow()
        } catch { errorText = error.localizedDescription }
    }

    private func follow() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                if self.onDeviceOnly || self.paired { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() async {
        guard let room else { return }
        do {
            apply(try await client.pairingStatus(room: room, kind: kind))
        } catch PigeonError.api(404, _, _) {
            onDeviceOnly = true
        } catch {}
    }

    private func apply(_ s: PairingStatus) {
        // A new code step (1 → 2) starts with an empty field.
        if s.state == "pin", s.pinStep != status?.pinStep || status?.state != "pin" { pin = "" }
        status = s
    }

    func choose(_ device: PairingStatus.Device) async {
        guard let room else { return }
        busy = true
        defer { busy = false }
        do {
            apply(try await client.selectPairingDevice(room: room, kind: kind, index: device.index))
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    func submitPIN() async {
        guard let room, pin.count == 4, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            apply(try await client.sendPairingPIN(room: room, kind: kind, pin: pin))
            errorText = nil
        } catch {
            errorText = error.localizedDescription
            pin = ""
        }
    }

    /// Stop following; close the search on the Pigeon unless it ended in a pairing.
    func leave() async {
        poll?.cancel()
        poll = nil
        if started, !paired, let room { await client.cancelPairing(room: room, kind: kind) }
        started = false
    }
}

struct DevicePairingPanel<Done: View>: View {
    @ObservedObject var model: DevicePairingModel
    /// Shown under the panel once a search is under way (the wizard's Continue).
    @ViewBuilder var done: () -> Done

    var body: some View {
        if !model.started {
            PrimaryButton(title: "Search for \(model.noun)", busy: model.busy) { Task { await model.search() } }
        } else if model.onDeviceOnly {
            status("Pigeon is searching for \(model.noun). Pick yours on the Pigeon's screen, then tap Continue.")
            done()
            SecondaryButton(title: "Search again") { Task { await model.search() } }
        } else {
            content
            done()
        }
        if let e = model.errorText {
            Text(e).font(Theme.ui(14)).foregroundStyle(Theme.bad)
        }
    }

    @ViewBuilder private var content: some View {
        let s = model.status
        switch model.state {
        case "results":
            let devices = s?.devices ?? []
            if devices.isEmpty {
                Text("No \(model.noun) found. Make sure yours is on and on the same Wi-Fi as the Pigeon.")
                    .font(Theme.ui(15)).foregroundStyle(Theme.secondaryText)
            } else {
                Text("Choose yours").font(Theme.uiBold(15)).foregroundStyle(Theme.secondaryText)
                ForEach(devices) { d in
                    Button { Task { await model.choose(d) } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(d.name).font(Theme.uiBold(17)).foregroundStyle(.white)
                                if let detail = [d.model, d.address].compactMap({ $0 }).first {
                                    Text(detail).font(Theme.ui(13)).foregroundStyle(Theme.secondaryText)
                                }
                            }
                            Spacer()
                            if d.name == s?.saved {
                                Image(systemName: "checkmark").foregroundStyle(Theme.ok)
                            } else {
                                Image(systemName: "chevron.right").foregroundStyle(Theme.inactive)
                            }
                        }
                        .tile()
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)
                }
            }
            SecondaryButton(title: "Search again") { Task { await model.search() } }

        case "pin":
            let step = s?.pinStep ?? 1, steps = s?.pinSteps ?? 1
            Text(steps > 1 ? "CODE \(step) OF \(steps)" : "CODE")
                .font(Theme.uiBold(13)).foregroundStyle(Theme.accent)
            Text("Enter the 4-digit code showing on your TV\(s?.deviceName.map { " (\($0))" } ?? "").")
                .font(Theme.ui(15)).foregroundStyle(.white)
            TextField("0000", text: $model.pin)
                .font(Theme.lcd(56))
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad)
                .onChange(of: model.pin) { _, v in
                    let digits = String(v.filter(\.isNumber).prefix(4))
                    if digits != v { model.pin = digits }
                    if digits.count == 4 { Task { await model.submitPIN() } }
                }
                .tile()

        case "pairing":
            let step = s?.pinStep
            status(step.map { "Checking code \($0) of \(s?.pinSteps ?? 2)…" }
                   ?? "Pairing with \(s?.deviceName ?? "it")…")

        case "paired":
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.ok)
                Text("Paired with \(s?.deviceName ?? s?.saved ?? "it").").font(Theme.uiBold(17)).foregroundStyle(.white)
            }
            .tile()

        case "failed":
            Text(s?.error ?? "Pairing didn't work.").font(Theme.ui(15)).foregroundStyle(Theme.bad)
            SecondaryButton(title: "Search again") { Task { await model.search() } }

        default:
            status("Searching for \(model.noun)…")
        }
    }

    private func status(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
            Text(text).font(Theme.ui(15)).foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .tile()
    }
}

/// "Add player" / "Add audio" for a room, outside the setup wizard.
struct DevicePairingSheet: View {
    @StateObject private var model: DevicePairingModel
    @Environment(\.dismiss) private var dismiss

    init(client: PigeonClient, kind: String) {
        _model = StateObject(wrappedValue: DevicePairingModel(client: client, kind: kind))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Heading(title: model.kind == "audio" ? "Add audio" : "Add a player",
                                text: model.kind == "audio"
                                    ? "Pair the AV receiver for this room so Pigeon can show its volume."
                                    : "Pair the Apple TV, Roku or other player for this room.")
                        DevicePairingPanel(model: model) { EmptyView() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.gutter)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.paired ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
        .task { await model.search() }
        .onDisappear { Task { await model.leave() } }
    }
}
