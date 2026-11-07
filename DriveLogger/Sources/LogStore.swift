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
    /// 記録中にアプリが落ち、次の起動時に閉じた走行なら true
    var recovered: Bool?

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
        // 同期の合図を動画と合わせるので、時刻はミリ秒まで残す(.iso8601 だと秒未満が切り捨てられる)
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(Fmt.iso.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // 秒未満のあるもの(新しい形)とないもの(前の版で書いたもの)の両方を読む
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let t = Fmt.iso.date(from: s) ?? plain.date(from: s) { return t }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "時刻を読めません: \(s)"))
        }
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
        evalCache[id] = nil
        try? FileManager.default.removeItem(at: dir(id))
        reload()
    }

    // MARK: - 記録中に落ちた走行の後始末

    /// 記録していないのに end が無い走行(記録中にアプリが落ちたもの)を閉じて、送信の対象にする。
    /// 書きかけの最後の行を切り捨て、各 CSV の最後の時刻を end にし、track.gpx に閉じタグを足す
    func recoverUnfinished(except recordingID: String?) {
        reload()
        for var meta in sessions where meta.end == nil && meta.id != recordingID {
            let folder = dir(meta.id)
            var last = meta.start.timeIntervalSince1970
            for name in ["location.csv", "motion.csv", "pressure.csv"] {
                let url = folder.appendingPathComponent(name)
                LogStore.trimPartialLine(url, keepingThrough: "\n")
                if let t = LogStore.lastUnixTime(url) { last = max(last, t) }
            }
            let gpx = folder.appendingPathComponent("track.gpx")
            if FileManager.default.fileExists(atPath: gpx.path), !LogStore.tail(gpx, bytes: 64).contains("</gpx>") {
                LogStore.trimPartialLine(gpx, keepingThrough: "</trkpt>\n", orHeader: "<trkseg>\n")
                if let h = try? FileHandle(forWritingTo: gpx) {
                    h.seekToEndOfFile()
                    h.write(Data("</trkseg></trk>\n</gpx>\n".utf8))
                    try? h.close()
                }
                if let s = try? String(contentsOf: gpx, encoding: .utf8) {
                    meta.points = s.components(separatedBy: "<trkpt ").count - 1
                }
            }
            meta.end = Date(timeIntervalSince1970: last)
            meta.recovered = true
            NSLog("記録中に止まった走行を閉じました: \(meta.id)")
            save(meta)
        }
        reload()
    }

    /// ファイルの最後の bytes バイト(文字列として)
    static func tail(_ url: URL, bytes: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    }

    /// 最後の marker より後ろ(書きかけの行)を切り捨てる。marker が末尾から 1MB 以内に無ければ
    /// orHeader の直後まで戻す(それも無ければ何もしない)
    static func trimPartialLine(_ url: URL, keepingThrough marker: String, orHeader header: String? = nil) {
        guard let h = try? FileHandle(forUpdating: url) else { return }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        let window = min(size, 1024 * 1024)
        h.seek(toFileOffset: size - window)
        let data = h.readDataToEndOfFile()
        let m = Data(marker.utf8)
        var keep: UInt64?
        if let r = data.range(of: m, options: .backwards) {
            keep = size - window + UInt64(r.upperBound - data.startIndex)
        } else if let header, let r = data.range(of: Data(header.utf8), options: .backwards) {
            keep = size - window + UInt64(r.upperBound - data.startIndex)
        }
        if let keep, keep < size { h.truncateFile(atOffset: keep) }
    }

    /// CSV の最後の行の先頭の列(unix_s)
    static func lastUnixTime(_ url: URL) -> Double? {
        let lines = tail(url, bytes: 4096).split(separator: "\n")
        for line in lines.reversed() {
            if let t = Double(line.split(separator: ",", maxSplits: 1).first ?? "") { return t }
        }
        return nil
    }

    // MARK: - 運転評価(evaluation.json)

    /// 送る順番。evaluation.json は無ければ飛ばす(前の版の走行や、短すぎて評価できなかった走行)。
    /// unsent の判定には使わない(評価を足す前に送り終えた走行を、もう一度送らないため)
    static let uploadFiles = ["location.csv", "motion.csv", "pressure.csv", "evaluation.json", "meta.json"]

    private var evalCache: [String: Evaluation] = [:]
    /// evaluation.json が無かった走行(一覧を描くたびにファイルを探さないため)
    private var evalMissing: Set<String> = []

    /// 保存してある評価。無ければ nil
    func evaluation(_ id: String) -> Evaluation? {
        if let e = evalCache[id] { return e }
        if evalMissing.contains(id) { return nil }
        let url = dir(id).appendingPathComponent("evaluation.json")
        guard let data = try? Data(contentsOf: url),
              let e = try? JSONDecoder().decode(Evaluation.self, from: data) else {
            evalMissing.insert(id)
            return nil
        }
        evalCache[id] = e
        return e
    }

    /// 評価を計算して evaluation.json に書く(時間がかかるので、メインスレッドでは呼ばない)
    @discardableResult
    static func writeEvaluation(folder: URL) -> Evaluation? {
        do {
            let e = try DriveEval.evaluate(folder: folder)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(e).write(to: folder.appendingPathComponent("evaluation.json"), options: .atomic)
            return e
        } catch {
            NSLog("運転評価を計算できませんでした(\(folder.lastPathComponent)): \(error.localizedDescription)")
            return nil
        }
    }

    /// 裏で評価を計算し、終わったらメインスレッドで done を呼ぶ
    func evaluate(_ id: String, done: @escaping (Evaluation?) -> Void) {
        let folder = dir(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let e = LogStore.writeEvaluation(folder: folder)
            DispatchQueue.main.async {
                if let e {
                    self.evalCache[id] = e
                    self.evalMissing.remove(id)
                    self.objectWillChange.send()
                }
                done(e)
            }
        }
    }

    /// 送るべきもの(GPX と生データ)が残っている走行
    var unsent: [SessionMeta] {
        sessions.filter { $0.finished && (!$0.gpxSent || !LogStore.rawFiles.allSatisfy($0.rawSent.contains)) }
    }
}
