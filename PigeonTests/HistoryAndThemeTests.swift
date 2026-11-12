import XCTest
@testable import Pigeon

final class HistoryAndThemeTests: XCTestCase {
    private func client() -> PigeonClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return PigeonClient(host: "10.0.0.5", port: 8780, token: "pgt_x", session: URLSession(configuration: cfg))
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }

    // MARK: Now playing artwork

    func testNowPlayingCarriesArtworkAndOldFirmwareStillDecodes() throws {
        let old = try decoder.decode(NowPlaying.self, from: Data(#"{"title":"Heat","source":"detected"}"#.utf8))
        XCTAssertTrue(old.artwork.isEmpty)
        XCTAssertFalse(old.isMusic)

        let title = try decoder.decode(NowPlaying.self, from: Data(#"""
        {"title":"Parks and Recreation","source":"detected","kind":"tv","tmdb_id":8592,"year":"2009",
         "backdrop_url":"https://image.tmdb.org/t/p/w780/bd.jpg","logo_url":"https://image.tmdb.org/t/p/w500/tt.png",
         "logo_white":true}
        """#.utf8))
        XCTAssertEqual(title.artwork.backdropUrl, "https://image.tmdb.org/t/p/w780/bd.jpg")
        XCTAssertTrue(title.artwork.logoWhite)

        let song = try decoder.decode(NowPlaying.self, from: Data(#"""
        {"title":"Cruel Summer","source":"detected","kind":"music","artist":"Taylor Swift","album":"Lover",
         "artwork_url":"/history/ab12/artwork"}
        """#.utf8))
        XCTAssertTrue(song.isMusic)
        XCTAssertEqual(song.musicSubtitle, "Taylor Swift — Lover")
        XCTAssertEqual(song.artwork.artworkPath, "/history/ab12/artwork")
    }

    // MARK: History

    func testHistoryListsRemovesAndClears() async throws {
        var seen: [String] = []
        StubURLProtocol.handler = { req in
            seen.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer pgt_x")
            if req.httpMethod == "DELETE", req.url?.path == "/api/v1/history/aa11" { return (204, Data()) }
            if req.httpMethod == "DELETE" { return (200, Data(#"{"removed":2,"entries":[]}"#.utf8)) }
            return (200, Data(#"""
            {"entries":[
              {"id":"aa11","kind":"tv","title":"Parks and Recreation","year":"2009","tmdb_id":8592,"service":"Peacock",
               "artist":null,"album":null,"first_played":1794300000.5,"last_played":1794373908.7,"plays":3,
               "backdrop_url":"https://image.tmdb.org/t/p/w780/bd.jpg","poster_url":"https://image.tmdb.org/t/p/w342/p.jpg"},
              {"id":"bb22","kind":"music","title":"Cruel Summer","year":null,"tmdb_id":null,"service":"Music",
               "artist":"Taylor Swift","album":"Lover","first_played":1794300000,"last_played":1794300000,"plays":1,
               "artwork_url":"/history/bb22/artwork"}]}
            """#.utf8))
        }
        let c = client()
        let entries = try await c.history()
        XCTAssertEqual(entries.map(\.id), ["aa11", "bb22"])
        XCTAssertEqual(entries[0].subtitle, "TV · 2009 · Peacock")
        XCTAssertEqual(entries[0].plays, 3)
        XCTAssertEqual(entries[1].subtitle, "Taylor Swift — Lover")
        XCTAssertEqual(entries[1].artwork.artworkPath, "/history/bb22/artwork")
        try await c.deleteHistory("aa11")
        try await c.clearHistory()
        XCTAssertEqual(seen, ["GET /api/v1/history", "DELETE /api/v1/history/aa11", "DELETE /api/v1/history"])
    }

    @MainActor
    func testRemovingAnEntryDropsItFromTheList() async {
        StubURLProtocol.handler = { req in
            if req.httpMethod == "DELETE" { return (204, Data()) }
            return (200, Data(#"{"entries":[{"id":"a","kind":"movie","title":"Heat","plays":1},{"id":"b","kind":"movie","title":"Ronin","plays":1}]}"#.utf8))
        }
        let model = HistoryModel(client: client())
        await model.load()
        XCTAssertEqual(model.entries?.count, 2)
        await model.remove(model.entries![0])
        XCTAssertEqual(model.entries?.map(\.title), ["Ronin"])
        XCTAssertNil(model.errorText)
    }

    @MainActor
    func testAFailedRemoveKeepsTheEntry() async {
        StubURLProtocol.handler = { req in
            if req.httpMethod == "DELETE" {
                return (404, Data(#"{"error":{"code":"not_found","message":"Unknown history entry."}}"#.utf8))
            }
            return (200, Data(#"{"entries":[{"id":"a","kind":"movie","title":"Heat","plays":1}]}"#.utf8))
        }
        let model = HistoryModel(client: client())
        await model.load()
        await model.remove(model.entries![0])
        XCTAssertEqual(model.entries?.count, 1)
        XCTAssertEqual(model.errorText, "Unknown history entry.")
    }

    @MainActor
    func testHistoryIsGroupedByDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 20))!
        func entry(_ id: String, hoursAgo: Double?) -> HistoryEntry {
            HistoryEntry(id: id, kind: "movie", title: id,
                         lastPlayed: hoursAgo.map { now.addingTimeInterval(-$0 * 3600).timeIntervalSince1970 }, plays: 1)
        }
        let groups = HistoryModel.byDay(
            [entry("a", hoursAgo: 1), entry("b", hoursAgo: 19), entry("c", hoursAgo: 21), entry("d", hoursAgo: 80),
             entry("e", hoursAgo: nil)], calendar: cal, now: now)
        XCTAssertEqual(groups.map(\.day), ["Today", "Yesterday", "Sunday, November 8", "Earlier"])
        XCTAssertEqual(groups.map { $0.entries.map(\.id) }, [["a", "b"], ["c"], ["d"], ["e"]])
    }

    // MARK: Theme color

    func testTheAppWearsTheFollowedPigeonsColor() {
        let defaults = UserDefaults(suiteName: "theme-tests-\(UUID().uuidString)")!
        let theme = ThemeStore(defaults: defaults)
        XCTAssertEqual(theme.accentKey, "blue")
        theme.remember("pink", for: "pgn-1")
        XCTAssertEqual(theme.accentKey, "blue", "not the Pigeon being looked at")
        theme.follow("pgn-1")
        XCTAssertEqual(theme.accentKey, "pink")
        theme.remember("white", for: "pgn-1")
        XCTAssertEqual(theme.accentKey, "white", "a color picked on the Pigeon shows here at once")
        theme.remember("no-such-color", for: "pgn-1")
        XCTAssertEqual(theme.accentKey, "white")
        theme.follow("pgn-2")
        XCTAssertEqual(theme.accentKey, "white", "an unknown Pigeon keeps the current color until its settings load")
        // Kept across launches.
        let again = ThemeStore(defaults: defaults)
        XCTAssertEqual(again.accentKey, "white")
        XCTAssertEqual(again.key(for: "pgn-1"), "white")
        again.follow(nil)
        XCTAssertEqual(again.accentKey, "blue")
    }

    func testThemeKeyFromSettings() throws {
        func settings(_ color: String, _ format: String) throws -> PigeonSettings {
            try decoder.decode(PigeonSettings.self, from: Data(#"""
            {"version":"0.12.151","zip":null,"timezone":null,"timezone_choices":[],
             "options":{"color_format":"\#(format)"},"option_values":{},"ui_color":"\#(color)",
             "ui_color_choices":["blue","green","yellow","pink","red","white"],
             "ui_color_hex":{"white":"#FFFFFF"}}
            """#.utf8))
        }
        XCTAssertEqual(ThemeStore.key(for: try settings("white", "color")), "white")
        XCTAssertEqual(ThemeStore.key(for: try settings("green", "dark")), "red", "the old dark mode is red on black")
    }

    // MARK: Visualizers

    func testVisualizerNames() {
        XCTAssertEqual(["Spectrum", "Sweep VU", "Arc VU", "Stereo Bars", "Faux 3.1 Speakers"].map(VisualizerNames.display),
                       ["Spectrum", "Analog VU", "Arc VU", "Sound Bars", "Circles"])
        XCTAssertEqual(VisualizerNames.display("Analog VU"), "Analog VU")
    }

    func testEveryRotationStyleHasAPreviewSheet() {
        for style in ["dots", "arc_vu", "sweep_vu", "bars", "faux_31"] {
            XCTAssertTrue(VisualizerPreviews.hasPreview(style: style), style)
        }
        XCTAssertFalse(VisualizerPreviews.hasPreview(style: "nope"))
    }

    func testPreviewRecolorSwapsOnlyTheMarkerBlue() throws {
        // Four pixels: marker blue, its pale tint, the meters' red, neutral grey.
        let pixels: [UInt8] = [0, 0, 255, 255, 148, 148, 255, 255, 217, 65, 43, 255, 77, 77, 77, 255]
        let ctx = CGContext(data: nil, width: 4, height: 1, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.data!.copyMemory(from: pixels, byteCount: 16)
        let out = try XCTUnwrap(VisualizerPreviews.recolor(try XCTUnwrap(ctx.makeImage()), to: 0xFF5CA8))
        let read = CGContext(data: nil, width: 4, height: 1, bitsPerComponent: 8, bytesPerRow: 16,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        read.draw(out, in: CGRect(x: 0, y: 0, width: 4, height: 1))
        let got = Array(UnsafeBufferPointer(start: read.data!.assumingMemoryBound(to: UInt8.self), count: 16))
        XCTAssertEqual(Array(got[0..<3]), [255, 92, 168], "the theme color itself")
        XCTAssertEqual(Array(got[4..<7]), [255, 186, 218], "a pale tint: the theme mixed toward white")
        XCTAssertEqual(Array(got[8..<11]), [217, 65, 43], "red is not the theme")
        XCTAssertEqual(Array(got[12..<15]), [77, 77, 77], "grey is not the theme")
        XCTAssertEqual(VisualizerPreviews.split(out).count, 0, "too small to hold a sheet's frames")
    }
}
