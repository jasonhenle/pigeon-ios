import CryptoKit
import Foundation
import Observation

/// Which Pigeons this phone can reach right now.
///
/// Pigeon Remote talks to a Pigeon directly over the home network, so away from that network
/// the Pigeon is unreachable. Every request through a client that knows its device id reports
/// here; a Pigeon that has never failed counts as reachable.
@MainActor
@Observable
final class Connectivity {
    static let shared = Connectivity()

    private(set) var unreachable: Set<String> = []

    func isReachable(_ deviceID: String) -> Bool { !unreachable.contains(deviceID) }

    func note(_ deviceID: String, reachable: Bool) {
        if reachable {
            if unreachable.contains(deviceID) { unreachable.remove(deviceID) }
        } else if !unreachable.contains(deviceID) {
            unreachable.insert(deviceID)
        }
    }
}

/// The last answer each Pigeon gave to the reads that describe it (settings, rooms, history,
/// visualizers...), so the app can show the whole page while the Pigeon is out of reach.
///
/// Live state (what is playing, search, the event stream) is never cached: stale, it would mislead.
/// Kept in Caches (iOS may clear it), one folder per Pigeon, deleted when the Pigeon is removed.
enum ResponseCache {
    /// GET paths worth keeping, by their first segment.
    private static let cachedRoots: Set<String> = [
        "device", "capabilities", "pigeon-settings", "rooms", "display", "visualizer", "sports", "history", "setup",
    ]
    /// Under a cached root, but live or too short-lived to show from memory.
    private static let uncachedPaths: Set<String> = ["/sports/games"]

    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PigeonResponses", isDirectory: true)
    }

    /// "/history/ab12/artwork?x=1" → "history".
    static func rootSegment(_ path: String) -> String {
        String(path.split(separator: "/").first ?? "")
    }

    static func isCacheable(_ path: String) -> Bool {
        cachedRoots.contains(rootSegment(path)) && !uncachedPaths.contains(path)
    }

    private static func folder(_ deviceID: String) -> URL {
        let safe = String(deviceID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(64))
        return root.appendingPathComponent(safe.isEmpty ? "unknown" : safe, isDirectory: true)
    }

    private static func file(_ deviceID: String, _ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder(deviceID).appendingPathComponent(name)
    }

    static func read(_ deviceID: String, _ key: String) -> Data? {
        try? Data(contentsOf: file(deviceID, key))
    }

    static func write(_ data: Data, _ deviceID: String, _ key: String) {
        let url = file(deviceID, key)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Forget everything kept under one root (after a change there, e.g. a history entry removed).
    static func invalidate(_ deviceID: String, root segment: String) {
        let dir = folder(deviceID)
        let index = dir.appendingPathComponent("index.json")
        var keys = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: index))) ?? [:]
        for (key, seg) in keys where seg == segment {
            try? FileManager.default.removeItem(at: file(deviceID, key))
            keys[key] = nil
        }
        if let data = try? JSONEncoder().encode(keys) { try? data.write(to: index, options: .atomic) }
    }

    /// Remember which root a key belongs to, so `invalidate` can find it without parsing hashes.
    static func index(_ deviceID: String, _ key: String) {
        let dir = folder(deviceID)
        let index = dir.appendingPathComponent("index.json")
        var keys = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: index))) ?? [:]
        let seg = rootSegment(String(key.split(separator: "?").first ?? ""))
        guard keys[key] != seg else { return }
        keys[key] = seg
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(keys) { try? data.write(to: index, options: .atomic) }
    }

    static func remove(_ deviceID: String) {
        try? FileManager.default.removeItem(at: folder(deviceID))
    }
}
