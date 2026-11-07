import Foundation

// 記録中のサポート。走りながら車の向きを推定し、急な操作を音で知らせ、直近 5 分の点数を出す。
// 判定のしきい値と点数の計算は DriveEval(走り終えたあとの評価)と同じものを使う。
// UIKit を使わない(DriveEval と同じく、CI で macOS のコマンドとしても動かせるように)

/// 記録中に知らせる出来事
enum CoachEvent: String, CaseIterable {
    case brake = "急ブレーキ"
    case accel = "急加速"
    case steer = "急ハンドル"
    case jerk = "急な操作"
    case stopJerk = "カックン"
}

/// 画面に出す値(メインスレッドに渡す)
struct CoachState {
    /// 車の向きが分かったか(分かるまでは G の点も点数も出さない)
    var ready = false
    /// 向き合わせの進み具合(0〜1)
    var progress = 0.0
    /// 前向きの G(加速で +)と左向きの G(左に曲がると +)。1 秒ならし
    var lonG = 0.0
    var latG = 0.0
    /// 直近 5 分の点数(走った時間が短いうちは nil)
    var recentScore: Double?
    var recentWorst: String?
    var counts: [CoachEvent: Int] = [:]
    var last: (event: CoachEvent, at: Date)?
}

/// Core Motion とGPS の値を受け取って判定する。呼ぶのは同じ順番待ち(Recorder の motionQueue)から
final class LiveCoach {
    typealias E = DriveEval

    /// 点数を出す範囲と、出し直す間隔
    static let windowS = 300.0
    static let scoreEveryS = 10.0
    /// 点数を出すのに必要な、範囲の中で走った秒数
    static let minMovingS = 60.0
    /// 向き合わせに使う GPS の組の数
    static let axesSamples = 30
    /// 重力の向きがこれより動いたら、端末を付け直したとみて向き合わせをやり直す
    static let remountDeg = 12.0

    private(set) var state = CoachState()
    var onEvent: ((CoachEvent) -> Void)?

    // 重力(上向き)と水平面の軸
    private var gSum = Vec3(0, 0, 0)
    private var gCount = 0
    private var gEMA: Vec3?
    private var up: Vec3?
    private var e1 = Vec3(1, 0, 0), e2 = Vec3(0, 1, 0)

    // 前向きの推定(最小二乗の和)
    private var s11 = 0.0, s12 = 0.0, s22 = 0.0, t1 = 0.0, t2 = 0.0
    private var sy = 0.0, syy = 0.0, sh1 = 0.0, sh2 = 0.0
    private var nSamples = 0
    private var fwd: Vec3?, left: Vec3?
    private var h1Sum = 0.0, h2Sum = 0.0, hCount = 0
    private var prevFix: (t: Double, sp: Double)?

    // GPS の最新
    private var kmh = 0.0
    private var lat = 0.0, lon = 0.0

    // 10 Hz の箱
    struct Bin {
        var t: Double
        var acc: Vec3
        var rot: Vec3
        var vib: Double?
        var kmh: Double
        var lat: Double
        var lon: Double
    }
    private var bins: [Bin] = []
    private var binIndex: Int?
    private var binAcc: [Vec3] = []
    private var binRot = Vec3(0, 0, 0)

    // その場の判定(1 秒ならし。中央の値を出すので 0.5 秒遅れる)
    private var lonHist: [Double] = [], latHist: [Double] = [], kmhHist: [Double] = []
    private var prevS: (lon: Double, lat: Double)?
    private var jlonHist: [Double] = []
    private var span: (lastHit: Int, announced: Bool)?
    private var tick = 0
    private var prevKmh = 0.0
    private var lastScoreT = 0.0
    private var lastSoundT = -100.0

    init() {}

    // MARK: - 入力

    /// userAcceleration と gravity は G、rotationRate は rad/s。t は UNIX 時刻
    func addMotion(t: Double, a: Vec3, g: Vec3, r: Vec3) {
        trackGravity(g)
        if up != nil {
            h1Sum += E.dot(a, e1)
            h2Sum += E.dot(a, e2)
            hCount += 1
        }
        let k = Int((t * Double(E.HZ)).rounded(.down))
        if let b = binIndex, k != b { closeBin(b) }
        binIndex = k
        binAcc.append(a)
        binRot += r
    }

    /// speed は m/s(わからなければ nil)
    func addLocation(t: Double, lat: Double, lon: Double, speed: Double?, accuracy: Double) {
        guard accuracy <= 50 else { return }
        self.lat = lat
        self.lon = lon
        if let sp = speed { kmh = sp * 3.6 }
        guard let sp = speed else { prevFix = nil; return }
        defer { prevFix = (t, sp); h1Sum = 0; h2Sum = 0; hCount = 0 }
        guard up != nil, let p = prevFix, (0.5...2.0).contains(t - p.t), max(p.sp, sp) >= 2.0, hCount >= 5 else { return }
        let y = (sp - p.sp) / (t - p.t) / E.G0
        let h1 = h1Sum / Double(hCount), h2 = h2Sum / Double(hCount)
        s11 += h1 * h1; s12 += h1 * h2; s22 += h2 * h2
        t1 += y * h1; t2 += y * h2
        sy += y; syy += y * y; sh1 += h1; sh2 += h2
        nSamples += 1
        fitAxes()
    }

    // MARK: - 向き

    private func trackGravity(_ g: Vec3) {
        if up == nil {
            gSum += g
            gCount += 1
            if gCount >= 100 { setUp(E.norm(-gSum / Double(gCount))) }
            return
        }
        let ema = (gEMA ?? g) * 0.99 + g * 0.01
        gEMA = ema
        if let u = up, E.dot(E.norm(-ema), u) < cos(LiveCoach.remountDeg * .pi / 180) {
            resetAxes()
            NSLog("端末の向きが変わったので、向き合わせをやり直します")
        }
    }

    private func setUp(_ u: Vec3) {
        up = u
        let ref = abs(u.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        e1 = E.norm(E.cross(u, ref))
        e2 = E.cross(u, e1)
        gEMA = -u
    }

    private func resetAxes() {
        up = nil; fwd = nil; left = nil
        gSum = Vec3(0, 0, 0); gCount = 0; gEMA = nil
        s11 = 0; s12 = 0; s22 = 0; t1 = 0; t2 = 0; sy = 0; syy = 0; sh1 = 0; sh2 = 0
        nSamples = 0
        state.ready = false
        state.progress = 0
        lonHist = []; latHist = []; kmhHist = []; jlonHist = []; prevS = nil; span = nil
        bins = [] // 前の向きで集めた値は使わない
        state.recentScore = nil
    }

    private func fitAxes() {
        state.progress = min(1, Double(nSamples) / Double(LiveCoach.axesSamples))
        guard let up, nSamples >= 10 else { return }
        let det = s11 * s22 - s12 * s12
        guard det != 0 else { return }
        let w1 = (t1 * s22 - t2 * s12) / det, w2 = (t2 * s11 - t1 * s12) / det
        let f = E.norm(w1 * e1 + w2 * e2)
        // 相関(lon と、前向きに写した水平の加速度)
        let f1 = E.dot(f, e1), f2 = E.dot(f, e2)
        let n = Double(nSamples)
        let sz = f1 * sh1 + f2 * sh2
        let szz = f1 * f1 * s11 + 2 * f1 * f2 * s12 + f2 * f2 * s22
        let syz = f1 * t1 + f2 * t2
        let cov = syz - sy * sz / n, vy = syy - sy * sy / n, vz = szz - sz * sz / n
        let q = vy > 0 && vz > 0 ? cov / (vy * vz).squareRoot() : 0
        fwd = f
        left = E.cross(up, f)
        if !state.ready && nSamples >= LiveCoach.axesSamples && q >= 0.5 {
            state.ready = true
            NSLog("車の向きが分かりました(相関 \(String(format: "%.2f", q)))")
        }
    }

    // MARK: - 10 Hz

    private func closeBin(_ k: Int) {
        guard !binAcc.isEmpty else { return }
        let n = Double(binAcc.count)
        let acc = binAcc.reduce(Vec3(0, 0, 0), +) / n
        var ss = 0.0
        for a in binAcc { let d = a - acc; ss += E.dot(d, d) }
        let bin = Bin(t: Double(k) / Double(E.HZ), acc: acc, rot: binRot / n, vib: (ss / n).squareRoot(),
                      kmh: kmh, lat: lat, lon: lon)
        binAcc.removeAll(keepingCapacity: true)
        binRot = Vec3(0, 0, 0)
        bins.append(bin)
        let keep = Int(LiveCoach.windowS) * E.HZ
        if bins.count > keep + 600 { bins.removeFirst(bins.count - keep) }
        live(bin)
        if bin.t - lastScoreT >= LiveCoach.scoreEveryS {
            lastScoreT = bin.t
            scoreRecent()
        }
    }

    /// その場で急な操作を見つける(DriveEval.evaluate の「急な操作」「止まり際」と同じしきい値)
    private func live(_ bin: Bin) {
        guard state.ready, let fwd, let left else { return }
        let w = Int(E.jerkSmoothS * Double(E.HZ) / 2)
        lonHist.append(E.dot(bin.acc, fwd) * E.G0)
        latHist.append(E.dot(bin.acc, left) * E.G0)
        kmhHist.append(bin.kmh)
        let size = 2 * w + 1
        if lonHist.count > size { lonHist.removeFirst(); latHist.removeFirst(); kmhHist.removeFirst() }
        guard lonHist.count == size else { return }
        tick += 1
        let sl = lonHist.reduce(0, +) / Double(size), sa = latHist.reduce(0, +) / Double(size)
        let hz = Double(E.HZ)
        let jl = prevS.map { (sl - $0.lon) * hz } ?? 0, ja = prevS.map { (sa - $0.lat) * hz } ?? 0
        prevS = (sl, sa)
        jlonHist.append(jl)
        if jlonHist.count > 2 * E.HZ { jlonHist.removeFirst() }
        state.lonG = sl / E.G0
        state.latG = sa / E.G0

        let k = kmhHist[w]
        let moving = k > E.movingKmh
        let gLon = sl / E.G0, gLat = sa / E.G0
        let jmag = (jl * jl + ja * ja).squareRoot()
        let hit = abs(gLon) > E.harshG || abs(gLat) > E.harshG ||
            (moving && jmag > E.harshJerk && max(abs(gLon), abs(gLat)) > E.harshJerkG)
        if hit {
            if span == nil || Double(tick - span!.lastHit) > E.harshMergeS * hz {
                span = (tick, false)
            }
            span!.lastHit = tick
            // G が大きいものはすぐに知らせる(1 つのまとまりで 1 回だけ)
            if !span!.announced {
                if abs(gLon) > E.harshG && abs(gLon) >= abs(gLat) {
                    span!.announced = true
                    fire(gLon < 0 ? .brake : .accel, at: bin.t)
                } else if abs(gLat) > E.harshG {
                    span!.announced = true
                    fire(.steer, at: bin.t)
                }
            }
        } else if let s = span, Double(tick - s.lastHit) > E.harshMergeS * hz {
            // G は大きくないが躍度が大きかったもの。まとまりが終わってから知らせる
            if !s.announced { fire(.jerk, at: bin.t) }
            span = nil
        }

        // 止まった瞬間(GPS で 4 km/h を切った)の直前 2 秒に、大きな前後の躍度があればカックン
        if prevKmh >= E.stopMaxKmh && k < E.stopMaxKmh,
           let m = jlonHist.map(abs).max(), m > E.stopEventJerk {
            fire(.stopJerk, at: bin.t)
        }
        prevKmh = k
    }

    private func fire(_ e: CoachEvent, at t: Double) {
        state.counts[e, default: 0] += 1
        state.last = (e, Date(timeIntervalSince1970: t))
        // 立て続けに鳴らさない
        if t - lastSoundT >= 2 {
            lastSoundT = t
            onEvent?(e)
        }
    }

    // MARK: - 直近 5 分の点数

    private func scoreRecent() {
        guard state.ready, let up, let fwd, let left, let last = bins.last else { return }
        let from = last.t - LiveCoach.windowS
        let win = bins.filter { $0.t > from }
        let moving = Double(win.filter { $0.kmh > E.movingKmh }.count) / Double(E.HZ)
        guard moving >= LiveCoach.minMovingS else { state.recentScore = nil; return }
        let stopped = E.detectStops(yaw: win.map { E.dot($0.rot, up) }, vib: win.map(\.vib), gpsKmh: win.map(\.kmh))
        let rows = zip(win, stopped).map { b, s in
            E.Row(rx: E.dot(b.acc, left), ry: -E.dot(b.acc, fwd), kmh: s ? 0 : b.kmh, lat: b.lat, lon: b.lon, stopped: s)
        }
        let ev = E.evaluate(rows: rows, t0Unix: win[0].t)
        state.recentScore = ev.score
        state.recentWorst = ev.items.min { $0.score < $1.score }.flatMap { $0.score < 80 ? $0.key : nil }
    }
}
