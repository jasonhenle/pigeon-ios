import SwiftUI

@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry]?
    @Published private(set) var busy = false
    @Published var errorText: String?
    let client: PigeonClient
    init(client: PigeonClient) { self.client = client }

    func load() async {
        do { entries = try await client.history(); errorText = nil }
        catch { errorText = error.localizedDescription }
    }

    func remove(_ entry: HistoryEntry) async {
        await run {
            try await self.client.deleteHistory(entry.id)
            self.entries?.removeAll { $0.id == entry.id }
        }
    }

    func clear() async {
        await run {
            try await self.client.clearHistory()
            self.entries = []
        }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await work(); errorText = nil } catch { errorText = error.localizedDescription }
    }

    /// Entries under "Today", "Yesterday" or a date, newest day first.
    static func byDay(_ entries: [HistoryEntry], calendar: Calendar = .current,
                      now: Date = .now) -> [(day: String, entries: [HistoryEntry])] {
        var out: [(day: String, entries: [HistoryEntry])] = []
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE, MMMM d"
        for e in entries {
            let label: String
            if let d = e.lastPlayedDate {
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d),
                                                   to: calendar.startOfDay(for: now)).day ?? 0
                label = days <= 0 ? "Today" : days == 1 ? "Yesterday" : f.string(from: d)
            } else {
                label = "Earlier"
            }
            if out.last?.day == label { out[out.count - 1].entries.append(e) } else { out.append((label, [e])) }
        }
        return out
    }
}

/// Everything this Pigeon has shown, newest first. Removing a title also removes it from Pigeon's systems.
struct HistoryView: View {
    @StateObject private var model: HistoryModel
    @State private var removing: HistoryEntry?
    @State private var confirmClear = false

    init(client: PigeonClient) { _model = StateObject(wrappedValue: HistoryModel(client: client)) }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let e = model.errorText { Text(e).font(Theme.ui(13)).foregroundStyle(Theme.bad) }
                    if let entries = model.entries {
                        if entries.isEmpty {
                            Text("Nothing yet. Titles and songs show up here as this Pigeon plays them.")
                                .font(Theme.ui(15)).foregroundStyle(Theme.secondaryText)
                                .frame(maxWidth: .infinity).padding(.top, 40).multilineTextAlignment(.center)
                        } else {
                            Text("Removing a title also removes it from Pigeon's systems.")
                                .font(Theme.ui(13)).foregroundStyle(Theme.secondaryText)
                        }
                        ForEach(HistoryModel.byDay(entries), id: \.day) { group in
                            LCDLabel(text: group.day, size: 18, color: Theme.accent).padding(.top, 8)
                            ForEach(group.entries) { e in
                                HistoryRow(entry: e, client: model.client) { removing = e }
                            }
                        }
                    } else if model.errorText == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(Theme.gutter)
            }
            .refreshable { await model.load() }
        }
        .navigationTitle("Now Playing History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.busy {
                    ProgressView()
                } else if model.entries?.isEmpty == false {
                    Button("Clear All", role: .destructive) { confirmClear = true }
                }
            }
        }
        .task { await model.load() }
        .alert("Remove “\(removing?.title ?? "")”?",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let e = removing { Task { await model.remove(e) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is removed from this Pigeon's history and from Pigeon's systems. This can't be undone.")
        }
        .alert("Clear all history?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) { Task { await model.clear() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every title is removed from this Pigeon's history and from Pigeon's systems. This can't be undone.")
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let client: PigeonClient
    var onRemove: () -> Void

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private var detail: String {
        var bits: [String] = []
        if let d = entry.lastPlayedDate { bits.append(Self.time.string(from: d)) }
        if entry.plays > 1 { bits.append("\(entry.plays) plays") }
        return bits.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            NowPlayingArtView(title: entry.title, artwork: entry.artwork, isMusic: false,
                              client: client, compact: true)
                .overlay { if entry.isMusic { albumArt } }
                .frame(width: 112)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(Theme.uiBold(16)).foregroundStyle(.white)
                    .multilineTextAlignment(.leading).lineLimit(2)
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle).font(Theme.ui(13)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                if !detail.isEmpty {
                    Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "trash").foregroundStyle(Theme.secondaryText)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(entry.title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile()
    }

    /// A track's cover, whole, on black (the title beside it already says what it is).
    private var albumArt: some View {
        ZStack {
            Color.black
            if let path = entry.artwork.artworkPath {
                DeviceImage(client: client, path: path).aspectRatio(1, contentMode: .fit)
            } else {
                Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(Theme.inactive)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
