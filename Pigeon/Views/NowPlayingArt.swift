import SwiftUI
import UIKit

// MARK: Images from a Pigeon

/// Album art lives on the Pigeon and needs its token, so `AsyncImage` can't load it.
enum DeviceImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 120
        return c
    }()

    static func image(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    static func store(_ image: UIImage, _ key: String) { cache.setObject(image, forKey: key as NSString) }
}

/// An image at an API path on a Pigeon (`/history/{id}/artwork`). Shows nothing until it loads.
struct DeviceImage: View {
    let client: PigeonClient
    let path: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: client.cacheKey(path)) { await load() }
    }

    private func load() async {
        let key = client.cacheKey(path)
        if let hit = DeviceImageCache.image(key) { image = hit; return }
        image = nil
        guard let data = try? await client.data(path), let loaded = UIImage(data: data) else { return }
        DeviceImageCache.store(loaded, key)
        image = loaded
    }
}

// MARK: The now playing picture

/// What Pigeon's now playing screen shows, without the status bar and running time:
/// the title's logo over its backdrop, or a track's name over its album art.
struct NowPlayingArtView: View {
    let title: String
    /// Artist and album for a track; empty for a title.
    var subtitle = ""
    let artwork: Artwork
    var isMusic = false
    /// For album art, which is fetched from the Pigeon.
    var client: PigeonClient?
    /// Small (a list row) or large (the device page).
    var compact = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                background.frame(width: geo.size.width, height: geo.size.height).clipped()
                if isMusic { trackText(geo.size) } else { titleLogo(geo.size) }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : Theme.corner, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
    }

    @ViewBuilder private var background: some View {
        if isMusic, let path = artwork.artworkPath, let client {
            DeviceImage(client: client, path: path)
        } else if let url = (artwork.backdropUrl ?? (isMusic ? nil : artwork.posterUrl)).flatMap(URL.init(string:)) {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { Color.clear }
            }
        } else {
            Theme.tileRaised
        }
    }

    /// The title treatment, centered like Pigeon's; plain text when TMDb has no logo.
    @ViewBuilder private func titleLogo(_ size: CGSize) -> some View {
        ZStack {
            // Pigeon dims the backdrop so the logo reads.
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            if let url = artwork.logoUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        if artwork.logoWhite {
                            image.renderingMode(.template).resizable().scaledToFit().foregroundStyle(.white)
                        } else {
                            image.resizable().scaledToFit()
                        }
                    } else if phase.error != nil {
                        fallbackTitle
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: size.width * 0.66, maxHeight: size.height * 0.5)
                .shadow(color: .black.opacity(0.6), radius: compact ? 3 : 8)
            } else {
                fallbackTitle.padding(.horizontal, compact ? 8 : 20)
            }
        }
    }

    private var fallbackTitle: some View {
        Text(title).font(Theme.uiBold(compact ? 13 : 26)).foregroundStyle(.white)
            .multilineTextAlignment(.center).lineLimit(compact ? 2 : 3).minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.8), radius: 4)
    }

    /// Song, then artist and album, over the foot of the album art.
    private func trackText(_ size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: compact ? 1 : 4) {
                Text(title).font(Theme.uiBold(compact ? 12 : 24)).foregroundStyle(.white).lineLimit(compact ? 1 : 2)
                if !subtitle.isEmpty {
                    Text(subtitle).font(Theme.ui(compact ? 10 : 16)).foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .shadow(color: .black.opacity(0.8), radius: 3)
            .padding(compact ? 6 : 14)
        }
    }
}

extension NowPlayingArtView {
    init(nowPlaying np: NowPlaying, client: PigeonClient?, compact: Bool = false) {
        self.init(title: np.title ?? "", subtitle: np.isMusic ? np.musicSubtitle : "", artwork: np.artwork,
                  isMusic: np.isMusic, client: client, compact: compact)
    }
}

// MARK: One Pigeon at a glance (the Devices list)

/// What a Pigeon is playing and its theme color, refreshed while its row is on screen.
@MainActor
final class DeviceGlanceModel: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    private var task: Task<Void, Never>?

    func start(_ client: PigeonClient, deviceID: String) {
        task?.cancel()
        task = Task { [weak self] in
            // Quick reachability check first, so the list (and the page behind it) knows at once.
            await client.ping()
            if let s = try? await client.pigeonSettings() {
                ThemeStore.shared.remember(ThemeStore.key(for: s), for: deviceID)
            }
            // Keeps what the Pigeon is and can do, so its page is complete even if it is out of reach
            // the first time it's opened.
            _ = try? await client.device()
            if let caps = try? await client.capabilities(), caps.capabilities.contains("rooms") {
                _ = try? await client.rooms()
            }
            while !Task.isCancelled {
                let np = (try? await client.status())?.nowPlaying
                guard !Task.isCancelled, let self else { return }
                if self.nowPlaying != np { self.nowPlaying = np }
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func stop() { task?.cancel() }
}
