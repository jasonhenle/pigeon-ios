import SwiftUI

/// Wording shared by System › Privacy and the question asked during setup.
enum DataSharing {
    static let title = "Share now playing data with the developer"
    static let note = "Data is not sold to third parties and is only used to improve the Pigeon experience."
}

@MainActor
final class PrivacyModel: ObservableObject {
    @Published private(set) var data: PrivacySettings?
    @Published private(set) var busy = false
    @Published var errorText: String?
    let client: PigeonClient
    init(client: PigeonClient) { self.client = client }

    func load() async {
        do { data = try await client.privacy(); errorText = nil }
        catch { errorText = error.localizedDescription }
    }

    func setShareData(_ on: Bool) async {
        busy = true
        defer { busy = false }
        do { data = try await client.setShareData(on); errorText = nil }
        catch { errorText = error.localizedDescription }
    }
}

/// System › Privacy: whether this Pigeon shares now playing data, and its now playing history.
struct PrivacyView: View {
    let client: PigeonClient
    let caps: [String]
    @StateObject private var model: PrivacyModel

    init(client: PigeonClient, caps: [String]) {
        self.client = client
        self.caps = caps
        _model = StateObject(wrappedValue: PrivacyModel(client: client))
    }

    private var reachable: Bool {
        client.deviceID.map { Connectivity.shared.isReachable($0) } ?? true
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if caps.contains("privacy") { sharing }
                    if caps.contains("history") { historyLink }
                    if let e = model.errorText, reachable {
                        Text(e).font(Theme.ui(13)).foregroundStyle(Theme.bad)
                    }
                }
                .padding(Theme.gutter)
            }
            .refreshable { await model.load() }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .task { if caps.contains("privacy") { await model.load() } }
    }

    private var sharing: some View {
        let on = Binding(
            get: { model.data?.shareData ?? false },
            set: { v in Task { await model.setShareData(v) } })
        return Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 4) {
                Text(DataSharing.title).font(Theme.uiBold(16)).foregroundStyle(.white)
                Text(DataSharing.note).font(Theme.ui(12)).foregroundStyle(Theme.secondaryText)
                if !reachable {
                    Text("Changes work again once this device is back on this Pigeon's Wi-Fi.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .tint(Theme.accent)
        .disabled(model.data == nil || model.busy || !reachable)
        .tile()
        .accessibilityHint(DataSharing.note)
    }

    private var historyLink: some View {
        NavigationLink { HistoryView(client: client) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Now Playing History").font(Theme.uiBold(16)).foregroundStyle(.white)
                    Text("What this Pigeon has shown. Removing a title also removes it from Pigeon's systems.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.inactive)
            }
            .contentShape(Rectangle())
            .tile()
        }
        .buttonStyle(.plain)
    }
}
