import Foundation

/// 画面に出す雨の強さ
struct RainNow: Equatable {
    /// 降水強度の段階(0 = 降っていない、1〜8)
    var level: Int
    /// その値の時刻
    var time: Date
}

/// 記録中、気象庁の雨雲レーダー(高解像度降水ナウキャスト)を5分ごとに取って、走行フォルダの
/// rain_radar.jsonl に貯める。あわせて、いまいる場所の雨の強さと、この先30分の予測を画面に出す。
/// - ネットにつながっているとき(テザリングなど)だけ取れる。つながっていない間のぶんは、
///   つながったときにさかのぼって取る(気象庁の一覧に残っている数時間ぶん)。
///   それでも取れなかった時刻は、PC 側(FetchRainRadar.bat)が走行後に取る
/// - 気象庁のデータが出るのは観測の約1分後で、5分おきなので、画面の値は1〜6分前のもの(時刻を一緒に出す)
/// 状態の読み書きはメインスレッドで行う
final class RainFetcher: ObservableObject {
    static let shared = RainFetcher()

    /// いちばん新しい実況での、いまいる場所の雨
    @Published private(set) var now: RainNow?
    /// この先30分の予測のうち、いちばん強い雨(いまいる場所)
    @Published private(set) var ahead: RainNow?
    /// 取れていないときの理由(画面に小さく出す)
    @Published private(set) var problem: String?
    /// 記録中で、取る設定になっている
    @Published private(set) var active = false

    /// 通った位置(30秒おきに間引いて、直近30分ぶん)
    private struct Point {
        var t: Date
        var lat: Double
        var lon: Double
    }

    private var points: [Point] = []
    private var timer: Timer?
    private var file: URL?
    private var startTime = Date()
    /// 取り終えた時刻(validtime)
    private var done: Set<String> = []
    /// 取れなかった回数(同じ時刻を何度もやり直さない)
    private var attempts: [String: Int] = [:]
    private var busy = false
    private var nextPoll = Date.distantPast
    /// 記録を始めるたびに増やす(前の記録の通信が遅れて戻ってきても混ぜない)
    private var generation = 0

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private init() {}

    // MARK: - 開始・停止

    func start(folder: URL, at time: Date) {
        stop()
        guard AppSettings.shared.rainRadar else { return }
        generation += 1
        file = folder.appendingPathComponent(RainRadar.fileName)
        startTime = time
        points = []
        done = []
        attempts = [:]
        nextPoll = .distantPast
        now = nil
        ahead = nil
        problem = nil
        active = true
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // 最初の位置が入ったころに1回目を試す
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        file = nil
        active = false
        busy = false
        now = nil
        ahead = nil
        problem = nil
    }

    /// 位置が来るたびに呼ぶ(メインスレッド)
    func note(lat: Double, lon: Double, time: Date) {
        guard active else { return }
        if let last = points.last, time.timeIntervalSince(last.t) < 30 { return }
        points.append(Point(t: time, lat: lat, lon: lon))
        let limit = time.addingTimeInterval(-30 * 60)
        if let first = points.first, first.t < limit { points.removeAll { $0.t < limit } }
    }

    // MARK: - 5分ごとの取得

    /// 1回ぶんの仕事の材料(通信はメインスレッドの外で行うので、値を写して渡す)
    private struct Job {
        var start: Date
        var points: [Point]
        var done: Set<String>
        var attempts: [String: Int]
    }

    private struct Outcome {
        /// 取り終えた時刻と、ファイルに足す行
        var slots: [(valid: String, lines: Data)] = []
        /// 取れなかった時刻
        var failed: [String] = []
        var now: RainNow?
        var ahead: RainNow?
        var offline = false
        /// いちばん新しい実況の時刻
        var latest: Date?
    }

    private func tick() {
        guard active, !busy, Date() >= nextPoll, let last = points.last else { return }
        // 位置が古いまま(GPS が切れている)なら、場所が分からないので待つ
        guard Date().timeIntervalSince(last.t) < 10 * 60 else { return }
        busy = true
        let gen = generation
        let job = Job(start: startTime, points: points, done: done, attempts: attempts)
        Task.detached(priority: .utility) {
            let out = await RainFetcher.run(job)
            DispatchQueue.main.async { RainFetcher.shared.apply(out, generation: gen) }
        }
    }

    private func apply(_ out: Outcome, generation gen: Int) {
        guard gen == generation else { return }
        busy = false
        for s in out.slots {
            append(s.lines)
            done.insert(s.valid)
        }
        for v in out.failed { attempts[v, default: 0] += 1 }
        if out.offline {
            problem = "ネットにつながっていません"
            // 表示が古くなりすぎたら消す
            if let n = now, Date().timeIntervalSince(n.time) > 20 * 60 {
                now = nil
                ahead = nil
            }
            return
        }
        problem = nil
        if let n = out.now { now = n }
        ahead = out.ahead
        // 次の実況が出るころまでは聞きに行かない(5分おき。出るのは観測の約1分後)
        if let latest = out.latest, out.failed.isEmpty {
            nextPoll = latest.addingTimeInterval(5.5 * 60)
        }
    }

    private func append(_ data: Data) {
        guard let file, !data.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    }

    // MARK: - 通信(メインスレッドの外)

    private static func get(_ url: URL) async -> (status: Int, data: Data)? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    /// 同じ時刻を取り直す回数の上限
    private static let maxAttempts = 5
    /// 1回に取る時刻の数(たまっているときも、気象庁に続けて聞きすぎないため)
    private static let slotsPerRun = 3

    private static func run(_ job: Job) async -> Outcome {
        var out = Outcome()
        guard let here = job.points.last,
              let list = await get(URL(string: "\(RainRadar.base)/targetTimes_N1.json")!), list.status == 200 else {
            out.offline = true
            return out
        }
        // 実況(basetime と validtime が同じ)を新しい順に
        let times = RainRadar.targetTimes(list.data)
            .filter { $0.basetime == $0.validtime && RainRadar.date($0.validtime) != nil }
            .sorted { $0.validtime > $1.validtime }
        guard let newest = times.first, let newestDate = RainRadar.date(newest.validtime) else { return out }
        out.latest = newestDate

        // 取る時刻: 記録を始める5分前から。いちばん新しいものを先に、残りは古い順に
        let from = job.start.addingTimeInterval(-5 * 60)
        let waiting = times.filter {
            guard let d = RainRadar.date($0.validtime) else { return false }
            return d >= from && !job.done.contains($0.validtime) && (job.attempts[$0.validtime] ?? 0) < maxAttempts
        }
        var order: [RainRadar.TargetTime] = []
        if let first = waiting.first { order.append(first) }
        order.append(contentsOf: waiting.dropFirst().reversed().prefix(slotsPerRun - 1))

        let hereTile = RainRadar.tile(lat: here.lat, lon: here.lon)
        for slot in order {
            guard let valid = RainRadar.date(slot.validtime) else { continue }
            // その時刻の前後5分に通った位置。無ければ(まだ先の時刻など)いまの位置
            var near = job.points.filter { abs($0.t.timeIntervalSince(valid)) <= 5 * 60 }
            if near.isEmpty { near = [here] }
            // いまの位置も入れる(実況が出るのは数分後なので、その間に進んだ先)
            if slot.validtime == newest.validtime { near.append(here) }
            let plan = RainRadar.tiles(for: near.map { (lat: $0.lat, lon: $0.lon) })
            var lines = Data()
            var ok = true
            for tile in plan.all.sorted(by: { ($0.x, $0.y) < ($1.x, $1.y) }) {
                let url = RainRadar.tileURL(basetime: slot.basetime, validtime: slot.validtime, tile: tile)
                // 降水の無いタイルも 200(全面が透明な小さい PNG)で返る。404 はその時刻のデータが無いとき
                guard let res = await get(url), res.status == 200 else {
                    ok = false
                    break
                }
                let found = !RainRadar.isEmptyTile(res.data)
                let record = RainRadar.Record(
                    v: slot.validtime, z: RainRadar.zoom, x: tile.x, y: tile.y,
                    core: plan.core.contains(tile), png: found ? res.data.base64EncodedString() : nil)
                if let line = RainRadar.line(record) { lines.append(line) }
                // いまいる場所の雨(いちばん新しい実況から)
                if slot.validtime == newest.validtime, tile == hereTile {
                    if !found {
                        out.now = RainNow(level: 0, time: valid)
                    } else if let grid = RainRadar.intensities(png: res.data),
                              let level = RainRadar.level(lat: here.lat, lon: here.lon, tile: tile, intensities: grid) {
                        out.now = RainNow(level: level, time: valid)
                    }
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if ok {
                out.slots.append((slot.validtime, lines))
            } else {
                out.failed.append(slot.validtime)
            }
        }

        out.ahead = await forecast(here: here, tile: hereTile)
        return out
    }

    /// この先30分の予測のうち、いまいる場所でいちばん強い雨。保存はしない
    private static func forecast(here: Point, tile: RainRadar.Tile) async -> RainNow? {
        guard let list = await get(URL(string: "\(RainRadar.base)/targetTimes_N2.json")!), list.status == 200 else { return nil }
        let times = RainRadar.targetTimes(list.data)
        guard let base = times.map({ $0.basetime }).max() else { return nil }
        let nowTime = Date()
        var best: RainNow?
        for t in times.sorted(by: { $0.validtime < $1.validtime }) where t.basetime == base {
            guard let valid = RainRadar.date(t.validtime) else { continue }
            let ahead = valid.timeIntervalSince(nowTime)
            guard ahead > 0, ahead <= 30 * 60 else { continue }
            guard let res = await get(RainRadar.tileURL(basetime: t.basetime, validtime: t.validtime, tile: tile)) else { return best }
            guard res.status == 200 else { continue }
            var level = 0
            if !RainRadar.isEmptyTile(res.data), let grid = RainRadar.intensities(png: res.data),
               let l = RainRadar.level(lat: here.lat, lon: here.lon, tile: tile, intensities: grid) {
                level = l
            }
            if best == nil || level > (best?.level ?? 0) { best = RainNow(level: level, time: valid) }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return best
    }
}
