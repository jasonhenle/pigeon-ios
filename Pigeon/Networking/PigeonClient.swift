import CryptoKit
import Foundation

enum PigeonError: LocalizedError, Equatable {
    case unauthorized
    case api(status: Int, code: String, message: String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "This Pigeon no longer recognizes this device. Add it again."
        case .api(_, _, let message): return message
        case .transport: return "Can't reach this Pigeon. Pigeon Remote works when this device is on the same Wi-Fi as the Pigeon."
        case .decoding(let m): return "Unexpected reply from the device. \(m)"
        }
    }
}

/// Where a device serves HTTPS and which certificate (SHA-256 of its DER bytes, lowercase hex) to trust there.
struct TLSPin: Codable, Hashable {
    var port: Int
    var fingerprint: String
}

/// Accepts exactly one self-signed certificate. The pin replaces chain and hostname checks, so a device
/// reached by IP or a changing mDNS name still works, and any other certificate is refused.
final class PinnedSessionDelegate: NSObject, URLSessionDelegate {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint.lowercased() }

    static func fingerprint(of cert: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              Self.fingerprint(of: leaf) == fingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private enum PinnedSessions {
    private static let lock = NSLock()
    private static var cache: [String: URLSession] = [:]

    static func session(for fingerprint: String) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        let key = fingerprint.lowercased()
        if let s = cache[key] { return s }
        let s = URLSession(configuration: .ephemeral, delegate: PinnedSessionDelegate(fingerprint: key),
                           delegateQueue: nil)
        cache[key] = s
        return s
    }
}

/// Talks to one device. With a `pin` it uses HTTPS on the pin's port and trusts only that certificate;
/// without one (devices whose firmware predates TLS) it falls back to plain HTTP. Stateless and cheap to create.
struct PigeonClient {
    var host: String
    var port: Int = 8780
    var token: String?
    var session: URLSession = .shared
    var pin: TLSPin?
    /// Set for a paired Pigeon: its reads are kept (`ResponseCache`) and shown while it is out of
    /// reach, and every request reports to `Connectivity`.
    var deviceID: String?

    /// The session to use: the caller's, unless it is the shared default and a pin requires a pinned one.
    private var activeSession: URLSession {
        if let pin, session === URLSession.shared { return PinnedSessions.session(for: pin.fingerprint) }
        return session
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e
    }()

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents()
        c.scheme = pin == nil ? "http" : "https"
        c.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host  // IPv6 literal
        c.port = pin?.port ?? port
        c.path = "/api/v1" + path
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Encodable? = nil,
                     timeout: TimeInterval = 8) throws -> URLRequest {
        var req = URLRequest(url: url(path, query: query), timeoutInterval: timeout)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try Self.encoder.encode(AnyEncodable(body))
        }
        return req
    }

    @discardableResult
    private func perform(_ req: URLRequest) async throws -> Data {
        var req = req
        let path = String((req.url?.path ?? "").dropFirst("/api/v1".count))
        let key = path + (req.url?.query.map { "?" + $0 } ?? "")
        let isGet = req.httpMethod == "GET"
        let cacheable = isGet && deviceID != nil && ResponseCache.isCacheable(path)
        var known = true
        if let id = deviceID {
            known = await Connectivity.shared.isReachable(id)
            // Out of reach: show what the Pigeon last said at once instead of waiting out a timeout.
            if !known, cacheable, let cached = ResponseCache.read(id, key) { return cached }
            if !known { req.timeoutInterval = min(req.timeoutInterval, 4) }
        }
        var data = Data(), resp = URLResponse()
        do {
            // A Pigeon answers 503 when its few connection slots are full (a page loading many things
            // at once). A read is safe to ask again, so wait a moment and do, rather than show an error.
            for attempt in 0..<3 {
                (data, resp) = try await activeSession.data(for: req)
                // Only the bare refusal (no body); a 503 with an error message, e.g. TMDb down, is an answer.
                guard isGet, attempt < 2, (resp as? HTTPURLResponse)?.statusCode == 503, data.isEmpty else { break }
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 700 : 1500))
            }
        }
        catch {
            // The app gave up on the request itself (a view went away, a stream reconnected):
            // that says nothing about the Pigeon.
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            if let id = deviceID {
                await Connectivity.shared.note(id, reachable: false)
                if cacheable, let cached = ResponseCache.read(id, key) { return cached }
            }
            throw PigeonError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw PigeonError.transport("No response") }
        // Any answer means it's in reach, except "who are you?": that is a reset Pigeon, or another
        // device that now has its address, and either way not one this device can use.
        if let id = deviceID {
            if http.statusCode == 401 { await Connectivity.shared.note(id, reachable: false) }
            else if !known { await Connectivity.shared.note(id, reachable: true) }
        }
        if (200..<300).contains(http.statusCode) {
            if let id = deviceID {
                if !isGet {
                    // A change: what was kept about it is out of date (a removed history entry must not
                    // come back from the cache). A reply that is the resource itself is kept in its place.
                    ResponseCache.invalidate(id, root: ResponseCache.rootSegment(path))
                }
                // PATCH /pigeon-settings, /display, /visualizer, /sports and /device reply with the GET body.
                let patchedWhole = req.httpMethod == "PATCH" && path.split(separator: "/").count == 1
                    && ResponseCache.isCacheable(path) && !data.isEmpty
                if cacheable || patchedWhole {
                    ResponseCache.write(data, id, key)
                    ResponseCache.index(id, key)
                }
            }
            return data
        }
        if http.statusCode == 401 { throw PigeonError.unauthorized }
        if let env = try? Self.decoder.decode(APIErrorEnvelope.self, from: data) {
            throw PigeonError.api(status: http.statusCode, code: env.error.code, message: env.error.message)
        }
        throw PigeonError.api(status: http.statusCode, code: "http_\(http.statusCode)", message: "The device returned an error.")
    }

    func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                            body: Encodable? = nil, timeout: TimeInterval = 8, as: T.Type = T.self) async throws -> T {
        let data = try await perform(try makeRequest(method, path, query: query, body: body, timeout: timeout))
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw PigeonError.decoding(String(describing: error)) }
    }

    func sendNoContent(_ method: String, _ path: String) async throws {
        try await perform(try makeRequest(method, path))
    }

    /// The raw bytes at an API path (an image).
    func data(_ path: String) async throws -> Data {
        try await perform(try makeRequest("GET", path))
    }

    /// Identifies this device's copy of a path, for caches (the same path means different art on another Pigeon).
    func cacheKey(_ path: String) -> String { "\(host):\(pin?.port ?? port)\(path)" }

    // MARK: Endpoints

    func hello() async throws -> Hello { try await send("GET", "/hello") }

    /// Is the Pigeon reachable right now? A quick, open request that also updates `Connectivity`.
    @discardableResult
    func ping() async -> Bool {
        guard let hello: Hello = try? await send("GET", "/hello", timeout: 3) else { return false }
        // Something answering at the address isn't enough: the address may now belong to another Pigeon.
        if let id = deviceID, hello.id != id {
            await Connectivity.shared.note(id, reachable: false)
            return false
        }
        return true
    }

    func claim(code: String, controllerName: String, controllerID: String) async throws -> ClaimResponse {
        try await send("POST", "/claim", body: ClaimRequest(
            code: code, controller: .init(name: controllerName, id: controllerID)))
    }

    /// Ask the device to show its pairing code full screen (open endpoint, unclaimed devices only).
    func pairStart() async throws {
        let _: PairStartResponse = try await send("POST", "/pair/start")
    }

    /// Dismiss the on-screen code, e.g. when the user backs out. Best effort.
    func pairCancel() async {
        try? await sendNoContent("POST", "/pair/cancel")
    }

    /// Tell the Pigeon to forget a controller (this device, when removing it), so it can be paired again.
    func revokeController(id: String) async throws {
        try await sendNoContent("DELETE", "/controllers/\(id)")
    }

    // MARK: First-run setup

    func setup() async throws -> SetupInfo { try await send("GET", "/setup") }

    func setSetupProgress(step: String?, skipped: [String]? = nil) async throws -> SetupInfo {
        try await send("PUT", "/setup", body: SetupProgress(step: step, skipped: skipped))
    }

    /// Ends setup: the device drops its "Continue on your device" screen.
    func completeSetup() async throws -> SetupInfo { try await send("POST", "/setup/complete") }

    func device() async throws -> DeviceInfo { try await send("GET", "/device") }
    func capabilities() async throws -> Capabilities { try await send("GET", "/capabilities") }
    func status() async throws -> DeviceStatus { try await send("GET", "/status") }

    /// `logos` asks the device to look up each title's logo too (slower: one TMDb call per result).
    func suggest(_ q: String, limit: Int = 12, logos: Bool = false,
                 kind: String? = nil, year: String? = nil) async throws -> [Suggestion] {
        var items: [URLQueryItem] = [.init(name: "q", value: q), .init(name: "limit", value: String(limit))]
        if logos { items.append(.init(name: "logos", value: "1")) }
        if let kind { items.append(.init(name: "kind", value: kind)) }
        if let year { items.append(.init(name: "year", value: year)) }
        let r: SuggestResponse = try await send("GET", "/search/suggest", query: items)
        return r.results
    }

    func currentSearch() async throws -> ManualSearchState { try await send("GET", "/search/current") }

    func setCurrentSearch(_ s: Suggestion) async throws -> ManualSearchState {
        try await send("PUT", "/search/current",
                       body: SetCurrentRequest(title: s.title, kind: s.kind, tmdbId: s.tmdbId,
                                               year: s.year.map(String.init)))
    }

    func clearCurrentSearch() async throws { try await sendNoContent("DELETE", "/search/current") }

    // MARK: Now playing correction

    func nowPlayingDetail() async throws -> NowPlayingDetail {
        try await send("GET", "/now-playing/detail")
    }

    func previewOverride(fields: [String: String], year: String?) async throws -> PreviewResponse {
        try await send("POST", "/now-playing/preview", body: PreviewRequest(fields: fields, year: year))
    }

    func applyFields(_ fields: [String: String], year: String?, kind: String) async throws -> NowPlayingDetail {
        try await send("PUT", "/now-playing/override",
                       body: OverrideRequest(fields: fields, year: year, kind: kind, pick: nil))
    }

    func applyPick(_ s: Suggestion) async throws -> NowPlayingDetail {
        guard let id = s.tmdbId, let kind = s.kind else {
            throw PigeonError.decoding("That result has no TMDb id.")
        }
        return try await send("PUT", "/now-playing/override", body: OverrideRequest(
            fields: nil, year: nil, kind: nil,
            pick: .init(title: s.title, kind: kind, tmdbId: id, year: s.year.map(String.init))))
    }

    func clearOverride() async throws -> NowPlayingDetail {
        try await send("DELETE", "/now-playing/override")
    }

    func refreshTmdb() async throws -> NowPlayingDetail {
        try await send("POST", "/now-playing/refresh")
    }

    // MARK: Now playing history

    func history() async throws -> [HistoryEntry] {
        let r: HistoryResponse = try await send("GET", "/history")
        return r.entries
    }

    /// Removes one entry from the Pigeon. The Pigeon also clears the title from its usage data
    /// and has Pigeon's systems (Pigeon Report) purge it.
    func deleteHistory(_ id: String) async throws { try await sendNoContent("DELETE", "/history/\(id)") }

    func clearHistory() async throws {
        let _: HistoryResponse = try await send("DELETE", "/history")
    }

    // MARK: Maintenance

    /// The device relaunches Pigeon; the reply arrives before it goes down.
    func restart() async throws {
        let _: StateReply = try await send("POST", "/device/restart")
    }

    /// RESET on the Pigeon page: settings, rooms and paired players go back to defaults. This device stays paired.
    func factoryReset() async throws {
        let _: StateReply = try await send("POST", "/device/reset")
    }

    /// Asks the device to look on GitHub, which can take a while on a slow link.
    func checkUpdate() async throws -> UpdateInfo { try await send("GET", "/update", timeout: 25) }

    /// Installs the newest version and restarts the device.
    func applyUpdate() async throws {
        let _: StateReply = try await send("POST", "/update")
    }

    // MARK: Rooms and Pigeon-page settings

    func rooms() async throws -> RoomsResponse { try await send("GET", "/rooms") }

    func switchRoom(_ id: String) async throws -> RoomsResponse {
        try await send("PUT", "/rooms/current", body: RoomIDRequest(id: id))
    }

    func renameRoom(_ id: String, to name: String) async throws -> RoomsResponse {
        try await send("PATCH", "/rooms/\(id)", body: RoomNameRequest(name: name))
    }

    /// Unpairs the room's player and receiver and puts its name back to ROOM n.
    func resetRoom(_ id: String) async throws -> RoomsResponse {
        try await send("POST", "/rooms/\(id)/reset")
    }

    /// Starts the Pigeon's player / audio search for a room (follow it with `pairingStatus`).
    func startPairing(room id: String, kind: String) async throws {
        let _: StateReply = try await send("POST", "/rooms/\(id)/pairing", body: PairingRequest(kind: kind))
    }

    /// What the Pigeon's search for `kind` shows right now. 404 on firmware that can't be driven from the app.
    func pairingStatus(room id: String, kind: String) async throws -> PairingStatus {
        try await send("GET", "/rooms/\(id)/pairing/\(kind)", timeout: 6)
    }

    /// Picks one of the search results, as the knob would.
    func selectPairingDevice(room id: String, kind: String, index: Int) async throws -> PairingStatus {
        try await send("POST", "/rooms/\(id)/pairing/\(kind)/select", body: PairingSelectRequest(index: index))
    }

    /// The 4-digit code the TV shows for the current step.
    func sendPairingPIN(room id: String, kind: String, pin: String) async throws -> PairingStatus {
        try await send("POST", "/rooms/\(id)/pairing/\(kind)/pin", body: PairingPinRequest(pin: pin))
    }

    /// Backs out of the search (best effort).
    func cancelPairing(room id: String, kind: String) async {
        let _: PairingStatus? = try? await send("DELETE", "/rooms/\(id)/pairing/\(kind)")
    }

    func pigeonSettings() async throws -> PigeonSettings { try await send("GET", "/pigeon-settings") }

    // MARK: Privacy

    func privacy() async throws -> PrivacySettings { try await send("GET", "/privacy") }

    func setShareData(_ on: Bool) async throws -> PrivacySettings {
        try await send("PATCH", "/privacy", body: PrivacyPatch(shareData: on))
    }

    func patchPigeonSettings(_ patch: PigeonSettingsPatch) async throws -> PigeonSettings {
        try await send("PATCH", "/pigeon-settings", body: patch)
    }

    // MARK: Display

    func display() async throws -> DisplayInfo { try await send("GET", "/display") }

    func setBrightness(_ percent: Int) async throws -> DisplayInfo {
        try await send("PATCH", "/display", body: DisplayPatch(brightness: percent))
    }

    // MARK: Sports

    func visualizer() async throws -> VisualizerState { try await send("GET", "/visualizer") }

    func patchVisualizer(_ patch: VisualizerPatch) async throws -> VisualizerState {
        try await send("PATCH", "/visualizer", body: patch)
    }

    func sports() async throws -> SportsSettings { try await send("GET", "/sports") }

    func patchSports(_ patch: SportsPatch) async throws -> SportsSettings {
        try await send("PATCH", "/sports", body: patch)
    }

    func sportsTeams(league id: String) async throws -> SportsTeamsResponse {
        try await send("GET", "/sports/leagues/\(id)/teams")
    }

    func setFollow(league: String, team: String, _ on: Bool) async throws {
        try await sendNoContent(on ? "PUT" : "DELETE", "/sports/leagues/\(league)/teams/\(team)/follow")
    }

    func sportsGames() async throws -> SportsGamesResponse { try await send("GET", "/sports/games") }

    /// Puts a game from today's list on the Pigeon's scoreboard.
    func showGame(_ id: String) async throws -> SportsSettings {
        try await send("PUT", "/sports/board", body: BoardRequest(eventId: id))
    }

    func clearGame() async throws { try await sendNoContent("DELETE", "/sports/board") }

    // MARK: Events (SSE)

    func events() -> AsyncThrowingStream<DeviceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try makeRequest("GET", "/events")
                    req.timeoutInterval = 60  // the device sends a keepalive every 15 s
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, resp) = try await activeSession.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw PigeonError.transport("No response") }
                    if http.statusCode == 401 { throw PigeonError.unauthorized }
                    guard http.statusCode == 200 else {
                        throw PigeonError.api(status: http.statusCode, code: "events", message: "Event stream refused.")
                    }
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        if let ev = parser.feed(line: line) { continuation.yield(ev) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// Incremental Server-Sent Events parser: feed it lines, get an event on each blank line.
struct SSEParser {
    private var event = ""
    private var data = ""
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()

    mutating func feed(line: String) -> DeviceEvent? {
        if line.hasPrefix(":") { return nil }  // keepalive comment
        if line.isEmpty {
            defer { event = ""; data = "" }
            return event.isEmpty ? nil : Self.make(event: event, data: data)
        }
        if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        else if line.hasPrefix("data:") {
            let part = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            data = data.isEmpty ? part : data + "\n" + part
        }
        return nil
    }

    private static func make(event: String, data: String) -> DeviceEvent {
        let raw = Data(data.utf8)
        switch event {
        case "snapshot":
            if let s = try? decoder.decode(DeviceStatus.self, from: raw) { return .snapshot(s) }
        case "now_playing":
            return .nowPlaying(try? decoder.decode(NowPlaying.self, from: raw))
        case "manual_search":
            if let m = try? decoder.decode(ManualSearchState.self, from: raw) { return .manualSearch(m) }
        case "device":
            return .device
        default: break
        }
        return .other(event)
    }
}
