import Foundation

/// 記録中、いまいる場所から最寄りのアメダス観測所の実測(雨量・気温・風)を10分ごとに取って、
/// 走行フォルダの amedas.jsonl に貯め、記録画面に出す。
/// - 雨量は最寄りの観測所、気温と風は気温を測っている最寄りの観測所(雨量だけの観測所があるため)
/// - ネットにつながっているとき(テザリングなど)だけ取れる。つながっていなかった間はさかのぼらない
/// - 観測所の一覧(約190KB)は端末に保存して使い回す(30日ごとに取り直す)
/// 状態の読み書きはメインスレッドで行う
final class AmedasFetcher: ObservableObject {
    static let shared = AmedasFetcher()

    /// 最寄りの観測所の雨量
    @Published private(set) var rain: Amedas.Observation?
    /// 気温を測っている最寄りの観測所の気温・風(rain と同じ観測所なら同じ値)
    @Published private(set) var weather: Amedas.Observation?

    private var here: (lat: Double, lon: Double, t: Date)?
    private var timer: Timer?
    private var file: URL?
    private var saved: Set<String> = []
    private var busy = false
    private var nextPoll = Date.distantPast
    private var generation = 0
    private var active = false

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private init() {}

    func start(folder: URL) {
        stop()
        guard AppSettings.shared.rainRadar else { return }
        generation += 1
        file = folder.appendingPathComponent(Amedas.fileName)
        saved = []
        nextPoll = .distantPast
        active = true
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        file = nil
        active = false
        busy = false
        here = nil
        rain = nil
        weather = nil
    }

    /// 位置が来るたびに呼ぶ(メインスレッド)
    func note(lat: Double, lon: Double, time: Date) {
        guard active else { return }
        here = (lat, lon, time)
    }

    private struct Outcome {
        var rain: Amedas.Observation?
        var weather: Amedas.Observation?
        var latest: Date?
        var ok = false
    }

    private func tick() {
        guard active, !busy, Date() >= nextPoll, let here,
              Date().timeIntervalSince(here.t) < 10 * 60 else { return }
        busy = true
        let gen = generation
        Task.detached(priority: .utility) {
            let out = await AmedasFetcher.run(lat: here.lat, lon: here.lon)
            DispatchQueue.main.async { AmedasFetcher.shared.apply(out, generation: gen) }
        }
    }

    private func apply(_ out: Outcome, generation gen: Int) {
        guard gen == generation else { return }
        busy = false
        if !out.ok {
            // 表示が古くなりすぎたら消す
            if let t = rain?.time, Date().timeIntervalSince(t) > 40 * 60 {
                rain = nil
                weather = nil
            }
            return
        }
        for o in [out.rain, out.weather].compactMap({ $0 }) {
            let key = "\(o.code)_\(o.t)"
            if saved.contains(key) { continue }
            saved.insert(key)
            if let line = Amedas.line(o) { append(line) }
        }
        rain = out.rain
        weather = out.weather ?? out.rain
        // 次の観測が出るころまで聞きに行かない(10分おき。出るのは観測の数分後)
        if let latest = out.latest { nextPoll = latest.addingTimeInterval(12 * 60) }
    }

    private func append(_ data: Data) {
        guard let file else { return }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    }

    // MARK: - 通信(メインスレッドの外)

    private static func get(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// 観測所の一覧。端末に保存したものが30日以内ならそれを使う
    private static var tableCache: [Amedas.Station] = []
    private static func table() async -> [Amedas.Station] {
        if !tableCache.isEmpty { return tableCache }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("amedastable.json")
        let age = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        if age < 30 * 86400, let data = try? Data(contentsOf: url) {
            let list = Amedas.stations(data)
            if !list.isEmpty { tableCache = list; return list }
        }
        guard let data = await get(Amedas.tableURL) else {
            // 取れなければ古いものでも使う
            if let old = try? Data(contentsOf: url) { tableCache = Amedas.stations(old) }
            return tableCache
        }
        let list = Amedas.stations(data)
        if !list.isEmpty {
            try? data.write(to: url, options: .atomic)
            tableCache = list
        }
        return tableCache
    }

    private static func run(lat: Double, lon: Double) async -> Outcome {
        var out = Outcome()
        let stations = await table()
        guard !stations.isEmpty, let lt = await get(Amedas.latestURL), let latest = Amedas.latest(lt) else { return out }
        out.latest = latest
        out.ok = true
        let key = Amedas.keyFormat.string(from: latest)
        // 雨量は最寄りの観測所。値が無ければ(欠測など)次に近い所
        for c in Amedas.nearest(stations, lat: lat, lon: lon, count: 3) {
            guard let d = await get(Amedas.pointURL(code: c.station.code, time: latest)),
                  let o = Amedas.observation(d, station: c.station, km: c.km, at: key),
                  o.t == key, o.precip10m != nil else { continue }
            out.rain = o
            break
        }
        // 気温・風は、気温を測っている最寄りの観測所
        for c in Amedas.nearest(stations, lat: lat, lon: lon, count: 3, where: { $0.hasTemp }) {
            if let r = out.rain, r.code == c.station.code {
                if r.temp != nil { out.weather = r; break }
                continue
            }
            guard let d = await get(Amedas.pointURL(code: c.station.code, time: latest)),
                  let o = Amedas.observation(d, station: c.station, km: c.km, at: key),
                  o.t == key, o.temp != nil else { continue }
            out.weather = o
            break
        }
        return out
    }
}
