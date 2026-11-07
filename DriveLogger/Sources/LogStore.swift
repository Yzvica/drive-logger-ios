import Foundation

struct Marker: Codable, Hashable {
    /// "mark"(目印)か "sync"(動画と合わせる合図)
    var kind: String
    var time: Date
    var lat: Double?
    var lon: Double?
}

/// 1回の走行の情報(meta.json)
struct SessionMeta: Codable, Identifiable, Hashable {
    var id: String
    var start: Date
    var end: Date?
    var device: String
    var systemVersion: String
    var appVersion: String
    var motionHz: Int
    /// 端末の起動からの秒(センサーの時刻)と UNIX 時刻の差。センサー時刻 + これ = UNIX 時刻
    var uptimeToUnix: Double
    var points: Int = 0
    var distanceM: Double = 0
    var maxSpeedMS: Double = 0
    var markers: [Marker] = []
    /// 地図サーバーへ GPX を送ったか
    var gpxSent: Bool = false
    /// 送り終えた生データのファイル名
    var rawSent: [String] = []

    var finished: Bool { end != nil }
    var durationS: Double { (end ?? Date()).timeIntervalSince(start) }
}

/// 端末に保存した走行ログ(Documents/logs/<走行ID>/)の一覧
final class LogStore: ObservableObject {
    static let shared = LogStore()
    static let rawFiles = ["location.csv", "motion.csv", "pressure.csv", "meta.json"]

    @Published private(set) var sessions: [SessionMeta] = []

    let root: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() { reload() }

    func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func save(_ meta: SessionMeta) {
        let url = dir(meta.id).appendingPathComponent("meta.json")
        if let data = try? LogStore.encoder.encode(meta) { try? data.write(to: url, options: .atomic) }
        DispatchQueue.main.async { self.reload() }
    }

    func load(_ id: String) -> SessionMeta? {
        let url = dir(id).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? LogStore.decoder.decode(SessionMeta.self, from: data)
    }

    func reload() {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        sessions = ids.compactMap { load($0) }.sorted { $0.start > $1.start }
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir(id))
        reload()
    }

    /// 送るべきもの(GPX と生データ)が残っている走行
    var unsent: [SessionMeta] {
        sessions.filter { $0.finished && (!$0.gpxSent || !LogStore.rawFiles.allSatisfy($0.rawSent.contains)) }
    }
}
