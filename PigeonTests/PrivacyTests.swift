import XCTest
@testable import Pigeon

/// System › Privacy: the data sharing switch on the Pigeon (`/privacy`), kept for away from home.
@MainActor
final class PrivacyTests: XCTestCase {
    private var deviceID = ""

    override func setUp() async throws {
        deviceID = "pgn-test-\(UUID().uuidString.prefix(8))"
        NetworkStub.calls = []
    }

    override func tearDown() async throws {
        ResponseCache.remove(deviceID)
        Connectivity.shared.note(deviceID, reachable: true)
    }

    private func client() -> PigeonClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [NetworkStub.self]
        return PigeonClient(host: "10.0.0.5", port: 8780, token: "pgt_x", session: URLSession(configuration: cfg),
                            deviceID: deviceID)
    }

    func testChoosingSendsTheSwitchAndKeepsTheAnswer() async throws {
        var sent: [String: Any]?
        NetworkStub.answer = { req in
            if req.httpMethod == "PATCH" {
                let body = req.httpBody ?? req.httpBodyStream.map { s -> Data in
                    s.open(); defer { s.close() }
                    var d = Data(); var buf = [UInt8](repeating: 0, count: 1024)
                    while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
                    return d
                } ?? Data()
                sent = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                return .reply(200, Data(#"{"share_data":true,"asked":true}"#.utf8))
            }
            return .reply(200, Data(#"{"share_data":false,"asked":false}"#.utf8))
        }
        let c = client()
        let before = try await c.privacy()
        XCTAssertEqual(before, PrivacySettings(shareData: false, asked: false))
        let after = try await c.setShareData(true)
        XCTAssertEqual(after, PrivacySettings(shareData: true, asked: true))
        XCTAssertEqual(sent?["share_data"] as? Bool, true)
        XCTAssertEqual(sent?.count, 1)

        NetworkStub.answer = { _ in .offline }
        let kept = try await c.privacy()
        XCTAssertEqual(kept, after, "away from home, the page shows the last choice")
    }

    func testTheModelReportsAFailedChange() async throws {
        NetworkStub.answer = { _ in .reply(200, Data(#"{"share_data":false,"asked":true}"#.utf8)) }
        let m = PrivacyModel(client: client())
        await m.load()
        XCTAssertEqual(m.data?.shareData, false)
        NetworkStub.answer = { _ in .reply(400, Data(#"{"error":{"code":"bad_request","message":"no"}}"#.utf8)) }
        await m.setShareData(true)
        XCTAssertEqual(m.data?.shareData, false, "the switch stays where the Pigeon has it")
        XCTAssertNotNil(m.errorText)
    }

    func testWordingNamesPigeonsSystemsNotPigeonReport() {
        XCTAssertEqual(DataSharing.title, "Share now playing data with the developer")
        XCTAssertFalse(DataSharing.note.contains("Pigeon Report"))
        XCTAssertTrue(DataSharing.note.contains("not sold to third parties"))
    }
}
