import XCTest
@testable import Pigeon

/// A URLProtocol whose answer can be a reply or a dropped network.
final class NetworkStub: URLProtocol {
    enum Answer { case reply(Int, Data), offline }
    static var answer: (URLRequest) -> Answer = { _ in .offline }
    static var calls: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
        switch Self.answer(request) {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .reply(let status, let data):
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class OfflineAndFeedbackTests: XCTestCase {
    private var deviceID = ""

    override func setUp() async throws {
        deviceID = "pgn-test-\(UUID().uuidString.prefix(8))"
        NetworkStub.calls = []
    }

    override func tearDown() async throws {
        ResponseCache.remove(deviceID)
        Connectivity.shared.note(deviceID, reachable: true)
    }

    private func client(_ id: String? = nil) -> PigeonClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [NetworkStub.self]
        return PigeonClient(host: "10.0.0.5", port: 8780, token: "pgt_x", session: URLSession(configuration: cfg),
                            deviceID: id ?? deviceID)
    }

    private let settingsJSON = Data(#"""
    {"version":"0.12.160","zip":null,"timezone":null,"timezone_choices":[],"options":{},"option_values":{},
     "ui_color":"pink","ui_color_choices":["blue","pink"]}
    """#.utf8)

    func testAwayFromHomeThePageShowsWhatThePigeonLastSaid() async throws {
        NetworkStub.answer = { _ in .reply(200, self.settingsJSON) }
        let c = client()
        _ = try await c.pigeonSettings()
        XCTAssertTrue(Connectivity.shared.isReachable(deviceID))

        NetworkStub.answer = { _ in .offline }
        let kept = try await c.pigeonSettings()
        XCTAssertEqual(kept.uiColor, "pink", "the kept answer, not an error")
        XCTAssertFalse(Connectivity.shared.isReachable(deviceID))

        // Known to be out of reach: the kept answer comes straight back, no waiting on the network.
        NetworkStub.calls = []
        _ = try await c.pigeonSettings()
        XCTAssertEqual(NetworkStub.calls, [])
    }

    func testLiveStateIsNeverShownFromMemory() async throws {
        NetworkStub.answer = { _ in
            .reply(200, Data(#"{"state":"playing","now_playing":{"title":"Heat"},"manual_search":{"active":false}}"#.utf8))
        }
        let c = client()
        _ = try await c.status()
        NetworkStub.answer = { _ in .offline }
        do {
            _ = try await c.status()
            XCTFail("what is playing must not come from the cache")
        } catch let e as PigeonError {
            XCTAssertTrue(e.localizedDescription.contains("same Wi-Fi"))
        }
    }

    func testBackInReachIsNoticed() async throws {
        Connectivity.shared.note(deviceID, reachable: false)
        NetworkStub.answer = { _ in
            .reply(200, Data(#"{"id":"\#(self.deviceID)","name":"C","product":"clock","api":1,"version":"0.12","claimed":true,"setup_mode":false}"#.utf8))
        }
        let ok = await client().ping()
        XCTAssertTrue(ok)
        XCTAssertTrue(Connectivity.shared.isReachable(deviceID))
    }

    func testCancellingARequestDoesNotMeanThePigeonIsGone() async throws {
        NetworkStub.answer = { _ in Thread.sleep(forTimeInterval: 0.5); return .reply(200, self.settingsJSON) }
        let c = client()
        let t = Task { try await c.pigeonSettings() }
        try await Task.sleep(for: .milliseconds(100))
        t.cancel()
        _ = try? await t.value
        XCTAssertTrue(Connectivity.shared.isReachable(deviceID))
    }

    func testABusyPigeonIsAskedAgainForReads() async throws {
        var n = 0
        NetworkStub.answer = { _ in
            n += 1
            return n < 3 ? .reply(503, Data()) : .reply(200, self.settingsJSON)
        }
        let s = try await client().pigeonSettings()
        XCTAssertEqual(s.uiColor, "pink")
        XCTAssertEqual(n, 3)
        // A change is never sent twice.
        n = 0
        NetworkStub.answer = { _ in n += 1; return .reply(503, Data()) }
        do {
            _ = try await client().patchPigeonSettings(.init(zip: nil, timezone: nil, options: nil, uiColor: "red"))
            XCTFail("a busy reply to a change is an error")
        } catch {}
        XCTAssertEqual(n, 1)
    }

    func testAnotherPigeonAtTheSameAddressIsNotThisOne() async throws {
        NetworkStub.answer = { _ in
            .reply(200, Data(#"{"id":"pgn-someone-else","name":"C","product":"clock","api":1,"version":"0.12","claimed":true,"setup_mode":false}"#.utf8))
        }
        let ok = await client().ping()
        XCTAssertFalse(ok)
        XCTAssertFalse(Connectivity.shared.isReachable(deviceID))
    }

    func testARemovedHistoryEntryDoesNotComeBackFromTheCache() async throws {
        NetworkStub.answer = { req in
            req.httpMethod == "DELETE"
                ? .reply(204, Data())
                : .reply(200, Data(#"{"entries":[{"id":"a1","kind":"movie","title":"Heat","plays":1}]}"#.utf8))
        }
        let c = client()
        _ = try await c.history()
        try await c.deleteHistory("a1")
        NetworkStub.answer = { _ in .offline }
        do {
            _ = try await c.history()
            XCTFail("the old list was kept after an entry was removed")
        } catch {}
    }

    func testAChangeReplyReplacesTheKeptCopy() async throws {
        NetworkStub.answer = { _ in .reply(200, self.settingsJSON) }
        let c = client()
        _ = try await c.pigeonSettings()
        let green = Data(String(data: settingsJSON, encoding: .utf8)!.replacingOccurrences(of: "\"pink\",", with: "\"green\",").utf8)
        NetworkStub.answer = { _ in .reply(200, green) }
        _ = try await c.patchPigeonSettings(.init(zip: nil, timezone: nil, options: nil, uiColor: "green"))
        NetworkStub.answer = { _ in .offline }
        let kept = try await c.pigeonSettings()
        XCTAssertEqual(kept.uiColor, "green")
    }

    func testPigeonsOutsideTheListAreNotCached() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [NetworkStub.self]
        let adding = PigeonClient(host: "10.0.0.9", session: URLSession(configuration: cfg))
        NetworkStub.answer = { _ in .reply(200, self.settingsJSON) }
        _ = try await adding.pigeonSettings()
        NetworkStub.answer = { _ in .offline }
        do { _ = try await adding.pigeonSettings(); XCTFail("cached without a device id") } catch {}
    }

    func testRemovingAPigeonDeletesWhatWasKept() async throws {
        NetworkStub.answer = { _ in .reply(200, self.settingsJSON) }
        _ = try await client().pigeonSettings()
        ResponseCache.remove(deviceID)
        NetworkStub.answer = { _ in .offline }
        do { _ = try await client().pigeonSettings(); XCTFail("kept after removal") } catch {}
    }

    // MARK: Feedback

    func testFeedbackDraftCarriesVersionsAndNothingPersonal() {
        let body = Feedback.body(product: "clock", pigeonVersion: "0.12.160", system: "27.0", model: "iPhone")
        XCTAssertTrue(body.contains("Pigeon Clock, PigeonOS 0.12.160"))
        XCTAssertTrue(body.contains("iPhone, iOS 27.0"))
        XCTAssertTrue(body.contains("Pigeon Remote "))
        XCTAssertFalse(body.contains("10.0."), "no addresses")
        let url = Feedback.mailto(body: body)!
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:hello@thepigeonlabs.com?subject=Pigeon%20Remote%20feedback"))
    }

    // MARK: Theme

    func testTheDevicesListBelongsToNoPigeon() {
        let theme = ThemeStore(defaults: UserDefaults(suiteName: "root-\(UUID().uuidString)")!)
        theme.remember("pink", for: "pgn-a")
        theme.remember("green", for: "pgn-b")
        theme.follow("pgn-a")
        XCTAssertEqual(theme.accentKey, "pink")
        theme.follow(nil)
        XCTAssertEqual(theme.accentKey, "blue", "back on the Devices list: Pigeon blue")
        XCTAssertEqual(theme.key(for: "pgn-b"), "green", "each Pigeon keeps its own dot")
    }
}
