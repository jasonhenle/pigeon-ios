import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var browser: DeviceBrowser
    @State private var showAdd = false

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (build \(b))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 12) {
                        if store.devices.isEmpty {
                            VStack(spacing: 10) {
                                LCDLabel(text: "Pigeon Remote", size: 34)
                                Text("Tap + to add a Pigeon and start searching.")
                                    .font(Theme.ui(16)).foregroundStyle(Theme.secondaryText)
                            }.padding(.top, 40)
                        }
                        ForEach(store.devices) { d in
                            NavigationLink(value: d) {
                                DeviceRow(device: d, client: store.client(for: d), selected: d.id == store.selectedID)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { store.selectedID = d.id })
                        }
                        Text("App version \(Self.appVersion)")
                            .font(Theme.ui(13)).foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity).padding(.top, 8)
                    }
                    .padding(Theme.gutter)
                }
            }
            .navigationTitle("Devices")
            .navigationDestination(for: KnownDevice.self) { DeviceDetailView(device: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddDeviceView() }
        }
    }
}


/// A Pigeon in the list: its name, and what it is playing as Pigeon shows it
/// (the title's logo over its backdrop, or the song over its album art).
struct DeviceRow: View {
    let device: KnownDevice
    let client: PigeonClient
    let selected: Bool
    @StateObject private var glance = DeviceGlanceModel()

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                LCDLabel(text: device.name, size: 26)
                Text(device.product == "marquee" ? "Pigeon Marquee" : "Pigeon Clock")
                    .font(Theme.ui(14)).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            if let np = glance.nowPlaying, np.title?.isEmpty == false {
                NowPlayingArtView(nowPlaying: np, client: client, compact: true)
                    .frame(width: 136)
            }
            Image(systemName: "chevron.right").foregroundStyle(Theme.inactive)
        }
        .tile(selected: selected)
        .onAppear { glance.start(client, deviceID: device.id) }
        .onChange(of: client.cacheKey("")) { _, _ in glance.start(client, deviceID: device.id) }
        .onDisappear { glance.stop() }
    }
}

/// One Pigeon: clock settings, what it is playing, display and theme, visualizer, sports, system.
struct DeviceDetailView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: KnownDevice

    var body: some View {
        DevicePage(client: store.client(for: device), device: device)
            .id(store.client(for: device).cacheKey(""))  // a new address: start over with a client that reaches it
            .navigationTitle(device.name)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DevicePage: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var setup: SetupCoordinator
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settings: PigeonSettingsModel
    let client: PigeonClient
    let device: KnownDevice

    @State private var info: DeviceInfo?
    @State private var capabilities: Capabilities?
    @State private var status: DeviceStatus?
    @State private var name = ""
    @State private var errorText: String?
    @State private var confirmRemove = false
    /// Setup on the device is not finished (the user left the wizard with "Later").
    @State private var setupPending = false
    /// Bumped after a reset so everything re-reads the device.
    @State private var reload = 0

    init(client: PigeonClient, device: KnownDevice) {
        _settings = StateObject(wrappedValue: PigeonSettingsModel(client: client))
        self.client = client
        self.device = device
    }

    private var caps: [String] { capabilities?.capabilities ?? [] }
    private var hasSettings: Bool { caps.contains("pigeon_settings") }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if setupPending { finishSetup }
                    if hasSettings {
                        NavigationLink { ClockSettingsView(model: settings) } label: {
                            PigeonClockSettingsButton(settings: settings.data)
                        }
                        .buttonStyle(.plain)
                    }
                    PlayingNowSection(device: device)
                    if hasSettings || caps.contains("display_brightness") {
                        CollapsibleTile(title: "Display and Theme") { displayAndTheme }
                    }
                    if caps.contains("viz") {
                        linkTile("Visualizer", "Pick the visualizer, and Viz Lock") { VisualizerView(client: client) }
                    }
                    if caps.contains("sports") {
                        linkTile("Sports", "Scores, followed teams and today's games") { SportsView(client: client) }
                    }
                    CollapsibleTile(title: "System") { system }
                    if let e = errorText ?? settings.errorText {
                        Text(e).font(Theme.ui(13)).foregroundStyle(Theme.bad)
                    }
                }
                .padding(Theme.gutter)
            }
        }
        .toolbar { if settings.busy { ToolbarItem(placement: .topBarTrailing) { ProgressView() } } }
        .task(id: reload) { await load() }
        .onChange(of: settings.data) { _, d in
            if let d { ThemeStore.shared.remember(ThemeStore.key(for: d), for: device.id) }
        }
        .alert("Remove \(device.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                Task {
                    await store.unpair(device)
                    ThemeStore.shared.forget(device.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The Pigeon keeps working. Add it again with its on-screen code.") }
    }

    private var finishSetup: some View {
        Button { setup.request = .device(id: device.id) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finish setting up").font(Theme.uiBold(18)).foregroundStyle(.white)
                    Text("Location, player and audio").font(Theme.ui(14))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.accent)
            }
            .tile(selected: true)
        }
        .buttonStyle(.plain)
    }

    private func linkTile<Destination: View>(_ title: String, _ note: String,
                                             @ViewBuilder to destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    LCDLabel(text: title, size: 18, color: Theme.accent)
                    Text(note).font(Theme.ui(13)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.inactive)
            }
            .frame(maxWidth: .infinity, alignment: .leading).tile()
        }
        .buttonStyle(.plain)
    }

    // MARK: Display and Theme: brightness, then the theme color (which this app wears too)

    @ViewBuilder private var displayAndTheme: some View {
        if caps.contains("display_brightness") {
            BrightnessControl(client: client).id(reload)
        }
        if hasSettings {
            if let d = settings.data {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Color").font(Theme.ui(13)).foregroundStyle(Theme.secondaryText)
                    ColorSwatches(model: settings, data: d)
                }
            } else {
                placeholder
            }
        }
    }

    // MARK: System: name, rooms, history, status, update / factory reset / restart, remove

    @ViewBuilder private var system: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name").font(Theme.ui(13)).foregroundStyle(Theme.secondaryText)
            TextField("Name", text: $name)
                .font(Theme.uiBold(18))
                .submitLabel(.done)
                .onSubmit { Task { await rename() } }
                .padding(10)
                .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        if caps.contains("rooms") {
            Divider().overlay(Theme.inactive)
            RoomsCard(client: client, canReset: caps.contains("room_reset"), embedded: true).id(reload)
        }
        Divider().overlay(Theme.inactive)
        if caps.contains("history") {
            NavigationLink { HistoryView(client: client) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Now Playing History").font(Theme.uiBold(16)).foregroundStyle(.white)
                        Text("What this Pigeon has shown. Remove anything you don't want kept.")
                            .font(Theme.ui(12)).foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.inactive)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().overlay(Theme.inactive)
        }
        VStack(alignment: .leading, spacing: 8) {
            row("Now playing", status?.nowPlaying?.title ?? "Nothing")
            row("Version", settings.data?.version ?? info?.version ?? "—")
            row("Address", "\(device.host):\(device.port)")
        }
        if caps.contains("restart") || caps.contains("update") || caps.contains("factory_reset") {
            MaintenanceControls(client: client, caps: caps) { reload += 1 }
        }
        Button(role: .destructive) { confirmRemove = true } label: {
            Text("Remove from this device").font(Theme.uiBold(16))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(Theme.bad)
                .background(Theme.tileRaised, in: Capsule())
        }
    }

    @ViewBuilder private var placeholder: some View {
        if settings.errorText == nil {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(Theme.ui(15)).foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(v).font(Theme.uiBold(15)).foregroundStyle(.white).multilineTextAlignment(.trailing)
        }
    }

    private func load() async {
        do {
            async let i = client.device()
            async let k = client.capabilities()
            async let s = client.status()
            (info, capabilities, status) = try await (i, k, s)
            name = info?.name ?? device.name
            errorText = nil
        } catch { errorText = error.localizedDescription }
        if hasSettings { await settings.load() }
        if caps.contains("setup"), let s = try? await client.setup() {
            setupPending = !s.isDone
        }
    }

    private func rename() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != device.name else { return }
        do {
            let updated: DeviceInfo = try await client.send("PATCH", "/device", body: ["name": trimmed])
            store.rename(id: device.id, to: updated.name)
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }
}

/// The clock: 12 / 24 hour, face, °F / °C, zip code and time zone.
struct ClockSettingsView: View {
    @ObservedObject var model: PigeonSettingsModel

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let d = model.data {
                        VStack(alignment: .leading, spacing: 14) {
                            OptionRow(model: model, data: d, key: "time_format", title: "Hours",
                                      labels: ["12": "12 hr", "24": "24 hr"])
                            OptionRow(model: model, data: d, key: "clock_format", title: "Clock face",
                                      labels: ["digital": "Digital", "analog": "Analog"])
                            OptionRow(model: model, data: d, key: "temp_format", title: "Temperature",
                                      labels: ["f": "°F", "c": "°C"])
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).tile()
                        LocationFields(model: model, data: d)
                            .frame(maxWidth: .infinity, alignment: .leading).tile()
                    } else if model.errorText == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    if let e = model.errorText { Text(e).font(Theme.ui(13)).foregroundStyle(Theme.bad) }
                }
                .padding(Theme.gutter)
            }
        }
        .navigationTitle("Clock Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if model.busy { ToolbarItem(placement: .topBarTrailing) { ProgressView() } } }
        .task { if model.data == nil { await model.load() } }
    }
}

/// A settings tile that folds down to its title; starts collapsed.
private struct CollapsibleTile<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack {
                    LCDLabel(text: title, size: 18, color: Theme.accent)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(Theme.inactive)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile()
        // Keeps the contents inside the tile while it grows or shrinks.
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

/// The device page's way into the clock's settings, drawn as Pigeon's digital clock:
/// date, HH:MM:SS and the 60 second boxes that fill as the minute goes by.
struct PigeonClockSettingsButton: View {
    /// Supplies the device's 12 / 24 hour choice and time zone; the phone's are used until it loads.
    let settings: PigeonSettings?

    private var timeZone: TimeZone {
        settings?.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    private var uses24h: Bool { settings?.options["time_format"] == "24" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LCDLabel(text: "Clock Settings", size: 18, color: Theme.accent)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.inactive)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: 8) {
                    Text(Self.format(ctx.date, "EEEE, MMMM d", timeZone))
                        .font(Theme.uiBold(15)).foregroundStyle(Theme.secondaryText)
                    LCDLabel(text: Self.format(ctx.date, uses24h ? "HH:mm:ss" : "h:mm:ss", timeZone),
                             size: 72, color: Theme.accent)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    SecondsBoxes(filled: Self.second(ctx.date, timeZone) + 1)
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Clock Settings")
    }

    private static func format(_ date: Date, _ pattern: String, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = pattern
        return f.string(from: date)
    }

    private static func second(_ date: Date, _ tz: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.component(.second, from: date)
    }
}

/// Pigeon's seconds track: 60 boxes, the elapsed ones lit (":00" lights one, ":59" all 60).
private struct SecondsBoxes: View {
    let filled: Int

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<60, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(i < filled ? Theme.accent : Theme.inactive.opacity(0.6))
            }
        }
        .frame(height: 16)
    }
}

// MARK: Room

@MainActor
final class RoomsModel: ObservableObject {
    @Published private(set) var data: RoomsResponse?
    @Published private(set) var busy = false
    @Published var errorText: String?
    @Published private(set) var notice: String?
    private let client: PigeonClient
    init(client: PigeonClient) { self.client = client }

    func load() async {
        do { data = try await client.rooms(); errorText = nil } catch { errorText = error.localizedDescription }
    }

    func choose(_ room: Room) async {
        guard !room.current else { return }
        await run { self.data = try await self.client.switchRoom(room.id) }
    }

    func rename(_ room: Room, to name: String) async {
        let n = name.trimmingCharacters(in: .whitespaces).uppercased()  // Pigeon only shows capitals
        guard !n.isEmpty, n != room.name else { return }
        await run { self.data = try await self.client.renameRoom(room.id, to: n) }
    }

    /// Starts the device-side search for a player (`player`) or audio receiver (`audio`) in this room.
    func reset(_ room: Room) async {
        await run { self.data = try await self.client.resetRoom(room.id) }
    }

    func startPairing(_ room: Room, kind: String) async {
        await run {
            try await self.client.startPairing(room: room.id, kind: kind)
            self.data = try await self.client.rooms()
            self.notice = "Pigeon is searching for \(kind == "player" ? "players" : "audio devices"). Pick one on its screen."
        }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        notice = nil
        defer { busy = false }
        do { try await work(); errorText = nil } catch { errorText = error.localizedDescription }
    }
}

struct RoomsCard: View {
    @StateObject private var model: RoomsModel
    @State private var renaming: Room?
    @State private var resetting: Room?
    @State private var switching: Room?
    @State private var newName = ""
    /// The device can empty a single room (trash icon).
    let canReset: Bool
    /// Inside another tile (the System section): no tile of its own.
    let embedded: Bool

    init(client: PigeonClient, canReset: Bool = false, embedded: Bool = false) {
        _model = StateObject(wrappedValue: RoomsModel(client: client))
        self.canReset = canReset
        self.embedded = embedded
    }

    var body: some View {
        Group {
            if embedded { rooms } else { rooms.tile() }
        }
        .task { await model.load() }
        .alert("Rename room", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("ROOM NAME", text: $newName)
                .textInputAutocapitalization(.characters)
                .onChange(of: newName) { _, v in if v != v.uppercased() { newName = v.uppercased() } }
            Button("Save") { if let r = renaming { Task { await model.rename(r, to: newName) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let p = model.data?.presets, !p.isEmpty { Text("e.g. " + p.prefix(4).joined(separator: ", ")) }
        }
        .alert("Switch to \(switching?.name.uppercased() ?? "room")?",
               isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } })) {
            Button("Switch") { if let r = switching { Task { await model.choose(r) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pigeon will use this room's player and audio receiver instead.")
        }
        .alert("Reset \(resetting?.name.uppercased() ?? "room")?",
               isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } })) {
            Button("Reset", role: .destructive) { if let r = resetting { Task { await model.reset(r) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unpairs this room's player and audio receiver and puts its name back to ROOM \(resetting?.slot ?? 1). Other rooms aren't changed.")
        }
    }

    private var rooms: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LCDLabel(text: "Room", size: 18, color: Theme.accent)
                Spacer()
                if model.busy { ProgressView() }
            }
            Text("Players and receivers belong to a room. Switching rooms changes which ones this Pigeon uses.")
                .font(Theme.ui(13)).foregroundStyle(Theme.secondaryText)
            ForEach(model.data?.rooms ?? []) { r in
                HStack {
                    // Ask first: a stray tap while scrolling would switch players.
                    Button { if !r.current { switching = r } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: r.current ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(r.current ? Theme.accent : Theme.inactive)
                            Text(r.name.uppercased()).font(Theme.uiBold(17)).foregroundStyle(.white)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    Menu {
                        Button { newName = r.name.uppercased(); renaming = r } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button { Task { await model.startPairing(r, kind: "player") } } label: {
                            Label("Add player", systemImage: "appletv")
                        }
                        Button { Task { await model.startPairing(r, kind: "audio") } } label: {
                            Label("Add audio", systemImage: "hifispeaker")
                        }
                    } label: {
                        Image(systemName: "pencil").foregroundStyle(Theme.secondaryText)
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                    if canReset {
                        Button { resetting = r } label: {
                            Image(systemName: "trash").foregroundStyle(Theme.secondaryText)
                                .frame(width: 36, height: 36).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reset \(r.name)")
                    }
                }
                .padding(.vertical, 6)
            }
            if let n = model.notice { Text(n).font(Theme.ui(13)).foregroundStyle(Theme.ok) }
            if let e = model.errorText { Text(e).font(Theme.ui(13)).foregroundStyle(Theme.bad) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Restart and update

@MainActor
final class MaintenanceModel: ObservableObject {
    enum Phase: Equatable { case idle, working(String), upToDate, available(String), done(String) }
    @Published private(set) var phase: Phase = .idle
    @Published var errorText: String?
    private let client: PigeonClient
    init(client: PigeonClient) { self.client = client }

    var busy: Bool { if case .working = phase { return true }; return false }

    func restart() async {
        phase = .working("Restarting…")
        do {
            try await client.restart()
            errorText = nil
            phase = .done("Restarting. It'll be back in about a minute.")
        } catch { errorText = error.localizedDescription; phase = .idle }
    }

    func reset() async -> Bool {
        phase = .working("Resetting…")
        do {
            try await client.factoryReset()
            errorText = nil
            phase = .done("Pigeon is back to its default settings.")
            return true
        } catch { errorText = error.localizedDescription; phase = .idle; return false }
    }

    func check() async {
        phase = .working("Checking for updates…")
        do {
            let u = try await client.checkUpdate()
            if let e = u.error { errorText = "Couldn't check: \(e)"; phase = .idle; return }
            errorText = nil
            if u.applying { phase = .done("An update is already installing."); return }
            phase = u.updateAvailable ? .available(u.remoteVersion ?? "") : .upToDate
        } catch { errorText = error.localizedDescription; phase = .idle }
    }

    func install() async {
        phase = .working("Starting update…")
        do {
            try await client.applyUpdate()
            errorText = nil
            phase = .done("Installing. Pigeon restarts itself when it's finished.")
        } catch { errorText = error.localizedDescription; phase = .idle }
    }
}

/// Check for updates, Factory Reset Pigeon and Restart Pigeon, for the System section.
struct MaintenanceControls: View {
    @StateObject private var model: MaintenanceModel
    let caps: [String]
    /// Called once a reset has gone through, so the other cards can re-read the device.
    let onReset: () -> Void
    @State private var confirmRestart = false
    @State private var confirmInstall = false
    @State private var confirmReset = false

    init(client: PigeonClient, caps: [String], onReset: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: MaintenanceModel(client: client))
        self.caps = caps
        self.onReset = onReset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .working(let t):
                HStack(spacing: 8) {
                    ProgressView()
                    Text(t).font(Theme.ui(14)).foregroundStyle(Theme.secondaryText)
                }
            case .upToDate: Text("Pigeon is up to date.").font(Theme.ui(14)).foregroundStyle(Theme.ok)
            case .available(let v): Text("Version \(v) is available.").font(Theme.uiBold(14)).foregroundStyle(Theme.ok)
            case .done(let t): Text(t).font(Theme.ui(14)).foregroundStyle(Theme.ok)
            case .idle: EmptyView()
            }
            if let e = model.errorText { Text(e).font(Theme.ui(13)).foregroundStyle(Theme.bad) }

            if caps.contains("update") {
                if case .available(let v) = model.phase {
                    button("Update to \(v)", filled: true) { confirmInstall = true }
                } else {
                    button("Check for updates", filled: false) { Task { await model.check() } }
                }
            }
            if caps.contains("factory_reset") {
                button("Factory Reset Pigeon", filled: false) { confirmReset = true }
            }
            if caps.contains("restart") {
                button("Restart Pigeon", filled: false) { confirmRestart = true }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(model.busy)
        .alert("Restart Pigeon?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive) { Task { await model.restart() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The screen goes dark for about a minute while it starts back up.") }
        .alert("Install the update?", isPresented: $confirmInstall) {
            Button("Update") { Task { await model.install() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Pigeon downloads the update, installs it and restarts. Your settings are kept.") }
        .alert("Factory Reset Pigeon?", isPresented: $confirmReset) {
            Button("Factory Reset", role: .destructive) {
                Task {
                    guard await model.reset() else { return }
                    try? await Task.sleep(for: .seconds(1.5))  // the device resets just after it replies
                    onReset()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Theme, clock, location, rooms and paired players and receivers go back to their defaults. This can't be undone. This phone stays connected.")
        }
    }

    private func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.uiBold(16)).frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(filled ? Color.black : Color.white)
                .background(filled ? Theme.accent : Theme.tileRaised, in: Capsule())
        }
    }
}

// MARK: Pigeon-page settings

@MainActor
final class PigeonSettingsModel: ObservableObject {
    @Published private(set) var data: PigeonSettings?
    @Published var zipText = ""
    @Published private(set) var busy = false
    @Published var errorText: String?
    private let client: PigeonClient
    init(client: PigeonClient) { self.client = client }

    func load() async {
        do {
            let d = try await client.pigeonSettings()
            data = d
            zipText = d.zip ?? ""
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    func setOption(_ key: String, _ value: String) async {
        await send(.init(zip: nil, timezone: nil, options: [key: value], uiColor: nil))
    }

    /// Picking a color also leaves the old dark mode, like the device's theme menu.
    func setColor(_ key: String) async {
        await send(.init(zip: nil, timezone: nil, options: ["color_format": "color"], uiColor: key))
    }

    func setTimezone(_ name: String) async {
        await send(.init(zip: nil, timezone: name, options: nil, uiColor: nil))
    }

    func saveZip() async {
        await send(.init(zip: zipText.trimmingCharacters(in: .whitespaces), timezone: nil, options: nil, uiColor: nil))
        // The device looks the timezone up in the background; refresh once it's had a moment.
        try? await Task.sleep(for: .seconds(3))
        await load()
    }

    private func send(_ patch: PigeonSettingsPatch) async {
        busy = true
        defer { busy = false }
        do { data = try await client.patchPigeonSettings(patch); errorText = nil }
        catch { errorText = error.localizedDescription }
    }
}

/// One of the device's two-way switches. Hidden when the device doesn't offer the option.
struct OptionRow: View {
    @ObservedObject var model: PigeonSettingsModel
    let data: PigeonSettings
    let key: String
    let title: String
    let labels: [String: String]
    var note: String? = nil

    var body: some View {
        if let values = data.optionValues[key] {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.ui(13)).foregroundStyle(Theme.secondaryText)
                Picker(title, selection: Binding(
                    get: { data.options[key] ?? values.first ?? "" },
                    set: { v in Task { await model.setOption(key, v) } })) {
                    ForEach(values, id: \.self) { v in Text(labels[v] ?? v).tag(v) }
                }
                .pickerStyle(.segmented)
                if let note { Text(note).font(Theme.ui(12)).foregroundStyle(Theme.secondaryText) }
            }
        }
    }
}

/// The theme colors as large tiles (three across). Picking one themes the Pigeon and this app.
private struct ColorSwatches: View {
    @ObservedObject var model: PigeonSettingsModel
    let data: PigeonSettings

    /// White took the place of the Standard / Simple switch; firmware from before that
    /// doesn't list it but does accept it.
    private var choices: [String] {
        data.uiColorChoices.contains("white") ? data.uiColorChoices : data.uiColorChoices + ["white"]
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(choices, id: \.self) { key in
                let selected = ThemeStore.key(for: data) == key
                Button { Task { await model.setColor(key) } } label: {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ThemeStore.color(for: key))
                        .frame(height: 68)
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark").font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(.black)
                            }
                        }
                        .padding(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(selected ? Color.white : .clear, lineWidth: 3)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key.capitalized)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }
}

struct LocationFields: View {
    @ObservedObject var model: PigeonSettingsModel
    let data: PigeonSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Zip code").font(Theme.ui(13)).foregroundStyle(Theme.secondaryText)
            HStack {
                TextField("5 digits", text: $model.zipText)
                    .keyboardType(.numberPad).font(Theme.uiBold(17))
                    .padding(10)
                    .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button("Save") { Task { await model.saveZip() } }
                    .font(Theme.uiBold(16))
                    .disabled(model.zipText.count != 5 || model.zipText == (data.zip ?? ""))
            }
            Text("Time zone").font(Theme.ui(13)).foregroundStyle(Theme.secondaryText)
            Menu {
                ForEach(data.timezoneChoices, id: \.self) { tz in
                    Button(tz) { Task { await model.setTimezone(tz) } }
                }
            } label: {
                HStack {
                    Text(data.timezone ?? "System default").font(Theme.uiBold(16)).foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").foregroundStyle(Theme.secondaryText)
                }
                .padding(10)
                .background(Theme.tileRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Text("Setting a zip code also sets the time zone.").font(Theme.ui(12)).foregroundStyle(Theme.secondaryText)
        }
    }
}

// MARK: Brightness

@MainActor
final class BrightnessModel: ObservableObject {
    @Published var level: Double = 100
    @Published private(set) var info: DisplayInfo?
    @Published var errorText: String?
    private let client: PigeonClient
    private var pending: Task<Void, Never>?
    init(client: PigeonClient) { self.client = client }

    func load() async {
        do {
            let d = try await client.display()
            info = d
            level = Double(d.brightness)
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    /// Called while dragging: send at most one request every 150 ms so the screen follows live.
    func levelChanged() {
        pending?.cancel()
        let target = Int(level.rounded())
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            do { self.info = try await self.client.setBrightness(target); self.errorText = nil }
            catch { self.errorText = error.localizedDescription }
        }
    }
}

struct BrightnessControl: View {
    @StateObject private var model: BrightnessModel
    init(client: PigeonClient) { _model = StateObject(wrappedValue: BrightnessModel(client: client)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Brightness").font(Theme.ui(13)).foregroundStyle(Theme.secondaryText)
                Spacer()
                LCDLabel(text: "\(Int(model.level.rounded()))%", size: 22)
            }
            HStack(spacing: 12) {
                Image(systemName: "sun.min").foregroundStyle(Theme.secondaryText)
                Slider(value: $model.level,
                       in: Double(model.info?.min ?? 10)...Double(model.info?.max ?? 100), step: 1)
                    .onChange(of: model.level) { _, _ in model.levelChanged() }
                Image(systemName: "sun.max.fill").foregroundStyle(.white)
            }
            if let info = model.info {
                Text(info.mode == "backlight" ? "Dims the panel's backlight." : "Dims the picture on this display.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.secondaryText)
            }
            if let e = model.errorText { Text(e).font(Theme.ui(13)).foregroundStyle(Theme.bad) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.load() }
    }
}
