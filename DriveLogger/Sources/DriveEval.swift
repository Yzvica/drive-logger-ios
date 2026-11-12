import Foundation

// 運転評価(酔いにくい運転ができているか)。
// gbowl-log-formatter の src/drivelog2gbowl.py(車の向きの推定・10 Hz にそろえる・停止の判定)と
// src/drive_eval.py(5 項目と出来事)を、そのまま Swift に移したもの。数字や手順を変えたら、両方を直すこと。
// UIKit を使わない(CI で macOS のコマンドとしてもビルドし、Python と同じ結果になるかを確かめるため)

typealias Vec3 = SIMD3<Double>

/// 評価の 1 項目
struct EvalItem: Codable, Hashable {
    var key: String
    var name: String
    var value: Double
    var score: Double
    var weight: Double
    var good: Double
    var bad: Double
}

/// 点数を下げた出来事(急ブレーキ・急ハンドル・カックンなど)
struct EvalEvent: Codable, Hashable {
    var kind: String
    var type: String
    var value: Double
    var unit: String
    var tUnix: Double
    var startUnix: Double
    var endUnix: Double
    var lat: Double
    var lon: Double
    var kmh: Double

    enum CodingKeys: String, CodingKey {
        case kind, type, value, unit, lat, lon, kmh
        case tUnix = "t_unix", startUnix = "start_unix", endUnix = "end_unix"
    }
}

/// evaluation.json と同じ形
struct Evaluation: Codable, Hashable {
    var version: Int = 1
    var score: Double
    var items: [EvalItem]
    var movingS: Double
    var stops: Int
    var events: [EvalEvent]
    /// 端末の向き合わせの確かさ(GPS の速度の変化との相関。0.5 未満なら固定が甘い)
    var axesQuality: Double?
    var source: String? = "iphone"
    /// 端末の持ち方。"fixed"(固定)か "hand"(手持ち。同乗のときだけ)。車の評価には付けない
    var mount: String?
    /// 手持ちのとき、走行中のうち採点に使えた時間の割合(手で端末を動かした区間は外す)
    var usableRatio: Double?

    enum CodingKeys: String, CodingKey {
        case version, score, items, stops, events, source, mount
        case movingS = "moving_s", axesQuality = "axes_quality", usableRatio = "usable_ratio"
    }
}

enum DriveEvalError: LocalizedError {
    case noData
    case tooShort
    case noAttitude

    var errorDescription: String? {
        switch self {
        case .noData: return "位置か加速度のデータがありません"
        case .tooShort: return "走っている時間が短すぎて、端末の向きを決められません"
        case .noAttitude: return "端末の姿勢の記録がないため、手持ちの評価ができません"
        }
    }
}

enum DriveEval {
    static let G0 = 9.80665
    static let HZ = 10

    // 項目: (キー, 名前, 100点の値, 0点の値, 重み)。値が小さいほど良い
    static let items: [(key: String, name: String, good: Double, bad: Double, weight: Double)] = [
        ("sick", "酔いやすさ", 0.15, 0.6, 0.30),      // m/s^2(走行中の 0.1〜0.5Hz の揺れの実効値)
        ("jerk", "躍度", 1.0, 4.0, 0.20),             // m/s^3(走行中の上位5%)
        ("harsh", "急な操作", 0.0, 5.0, 0.20),        // 回 / 10分
        ("stop", "止まり際", 0.5, 4.0, 0.15),         // m/s^3(停止直前1秒の躍度の最大、停止ごとの平均)
        ("curve", "カーブのつなぎ", 1.0, 4.0, 0.15),  // m/s^3(カーブ中の合成Gの変化の速さの上位5%)
    ]

    static let movingKmh = 5.0
    static let harshG = 0.3
    static let harshJerk = 4.0
    static let harshJerkG = 0.15
    static let jerkSmoothS = 1.0
    static let harshMergeS = 1.0
    static let stopEventJerk = 2.5
    static let curveG = 0.15

    // 停止の判定(drivelog2gbowl.py と同じ)
    static let stopMaxKmh = 4.0
    static let stopYaw = 0.05
    static let stopEnterS = 1.0
    static let stopExitS = 0.8
    static let stopMinS = 1.5
    static let stopRampS = 1.0

    static let eventTypes = ["急ブレーキ": "brake", "急加速": "accel", "急ハンドル": "steer", "急な操作": "jerk", "カックン": "stopjerk"]

    // MARK: - 読み込み

    struct Loc {
        var t: Double
        var la: Double
        var lo: Double
        var sp: Double?
        var cs: Double?
    }

    struct Mot {
        var t: Double
        var a: Vec3
        var g: Vec3
        var r: Vec3
        /// 端末の姿勢(Core Motion の attitude)。手持ちの評価に使う。古い記録には無い
        var q: Quat? = nil
    }

    /// 走行フォルダ(location.csv と motion.csv)を評価する。
    /// allowHandheld = true(同乗)なら、端末が固定されていなかったときは手持ちの方法で評価する
    static func evaluate(folder: URL, allowHandheld: Bool = false) throws -> Evaluation {
        let locs = try loadLocations(folder.appendingPathComponent("location.csv"))
        let mot = try loadMotion(folder.appendingPathComponent("motion.csv"))
        return try evaluate(locs: locs, mot: mot, allowHandheld: allowHandheld)
    }

    static func evaluate(locs: [Loc], mot: [Mot], allowHandheld: Bool = false) throws -> Evaluation {
        let p = try prepare(locs: locs, gpsLocs: locs, mot: mot, allowHandheld: allowHandheld)
        var ev = evaluate(rows: p.rows, t0Unix: p.t0)
        ev.axesQuality = (p.quality * 100).rounded() / 100
        ev.mount = p.mount
        ev.usableRatio = p.usable.map { round($0, 3) }
        return ev
    }

    /// 評価に使う 10 Hz の行
    struct Prepared {
        var rows: [Row]
        var t0: Double
        /// 向き合わせの確かさ(GPS の速度の変化との相関)
        var quality: Double
        /// "fixed" か "hand"。allowHandheld = false(車)なら nil
        var mount: String?
        /// 手持ちのとき、走行中のうち採点に使えた割合
        var usable: Double?
    }

    /// 端末の向きを車に合わせて 10 Hz の行にする。
    /// locs は位置と速度に使う点、gpsLocs は向き合わせに使う点(GPS で測れた点だけ)
    static func prepare(locs: [Loc], gpsLocs: [Loc], mot: [Mot], allowHandheld: Bool) throws -> Prepared {
        guard let l0 = locs.first, let l1 = locs.last, let m0 = mot.first, let m1 = mot.last else { throw DriveEvalError.noData }
        if !allowHandheld {
            let axes = try vehicleAxes(locs: gpsLocs, mot: mot)
            let s0 = max(l0.t, m0.t), s1 = min(l1.t, m1.t)
            guard s1 > s0 else { throw DriveEvalError.noData }
            return Prepared(rows: resample(locs: locs, mot: mot, axes: axes, t0: s0, t1: s1), t0: s0,
                            quality: axes.quality, mount: nil, usable: nil)
        }
        let s0 = max(l0.t, m0.t), s1 = min(l1.t, m1.t)
        guard s1 > s0 else { throw DriveEvalError.noData }
        // 重力の向きがほとんど変わらず、向き合わせもうまくいけば固定とみなす(車と同じ方法)
        let axes = try? vehicleAxes(locs: gpsLocs, mot: mot)
        if let axes, axes.quality >= fixedMinQuality, gravitySteady(mot) {
            return Prepared(rows: resample(locs: locs, mot: mot, axes: axes, t0: s0, t1: s1), t0: s0,
                            quality: axes.quality, mount: "fixed", usable: nil)
        }
        do {
            let h = try handheldRows(locs: locs, gpsLocs: gpsLocs, mot: mot, t0: s0, t1: s1)
            return Prepared(rows: h.rows, t0: s0, quality: h.quality, mount: "hand", usable: h.usable)
        } catch {
            // 姿勢の記録が無いなどで手持ちの方法が使えなければ、固定として評価する
            guard let axes else { throw error }
            return Prepared(rows: resample(locs: locs, mot: mot, axes: axes, t0: s0, t1: s1), t0: s0,
                            quality: axes.quality, mount: "fixed", usable: nil)
        }
    }

    /// CSV を見出しの名前で読む。数にならない欄は nil
    static func readCSV(_ url: URL, columns: [String]) throws -> [[Double?]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard let head = lines.next() else { return [] }
        let names = head.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "")
        }
        let idx = columns.map { names.firstIndex(of: $0) }
        var out: [[Double?]] = []
        while let line = lines.next() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            out.append(idx.map { i in
                guard let i, i < f.count, let v = Double(f[i]), v.isFinite else { return nil }
                return v
            })
        }
        return out
    }

    static func loadLocations(_ url: URL) throws -> [Loc] {
        let rows = try readCSV(url, columns: ["unix_s", "lat", "lon", "h_acc_m", "speed_ms", "course_deg"])
        var out: [Loc] = []
        for r in rows {
            guard let t = r[0], let la = r[1], let lo = r[2], let acc = r[3], acc <= 50 else { continue }
            out.append(Loc(t: t, la: la, lo: lo, sp: r[4], cs: r[5]))
        }
        return out.sorted { $0.t < $1.t }
    }

    static func loadMotion(_ url: URL) throws -> [Mot] {
        let rows = try readCSV(url, columns: ["unix_s", "ax_g", "ay_g", "az_g", "grav_x", "grav_y", "grav_z",
                                              "rot_x_rads", "rot_y_rads", "rot_z_rads", "q_w", "q_x", "q_y", "q_z"])
        var out: [Mot] = []
        out.reserveCapacity(rows.count)
        for r in rows {
            let v = r[0..<10].compactMap { $0 }
            guard v.count == 10 else { continue }
            var q: Quat?
            if let w = r[10], let x = r[11], let y = r[12], let z = r[13] { q = Quat(w: w, x: x, y: y, z: z) }
            out.append(Mot(t: v[0], a: Vec3(v[1], v[2], v[3]), g: Vec3(v[4], v[5], v[6]), r: Vec3(v[7], v[8], v[9]), q: q))
        }
        return out.sorted { $0.t < $1.t }
    }

    // MARK: - ベクトル

    static func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

    static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    static func norm(_ a: Vec3) -> Vec3 {
        let n = dot(a, a).squareRoot()
        return Vec3(a.x / n, a.y / n, a.z / n)
    }

    static func corr(_ xs: [Double], _ ys: [Double]) -> Double {
        let n = Double(xs.count)
        guard xs.count >= 3 else { return 0 }
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
            syy += (y - my) * (y - my)
        }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
    }

    /// xs の中で x 以上になる最初の位置(Python の bisect_left)
    static func bisectLeft(_ xs: [Double], _ x: Double) -> Int {
        var lo = 0, hi = xs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if xs[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// xs の中で x より大きくなる最初の位置(Python の bisect_right)
    static func bisectRight(_ xs: [Double], _ x: Double) -> Int {
        var lo = 0, hi = xs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if x < xs[mid] { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    // MARK: - 車の向きに合わせる

    struct Axes {
        var up: Vec3
        var fwd: Vec3
        var left: Vec3
        var quality: Double
    }

    /// 端末の座標で、上・前・左の単位ベクトル。端末はホルダーに固定されている前提
    static func vehicleAxes(locs: [Loc], mot: [Mot]) throws -> Axes {
        var gs = Vec3(0, 0, 0)
        for m in mot { gs += m.g }
        let gm = gs / Double(mot.count)
        let up = norm(-gm) // Core Motion の重力は地面の方を向く
        let ref = abs(up.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        let e1 = norm(cross(up, ref))
        let e2 = cross(up, e1)

        // GPS の速度の変化(前後の加速度)と、端末の水平の加速度(1秒平均)を比べて前向きを決める
        let ts = mot.map(\.t)
        var samples: [(Double, Double, Double)] = []
        for (a, b) in zip(locs, locs.dropFirst()) {
            guard let sa = a.sp, let sb = b.sp, (0.5...2.0).contains(b.t - a.t) else { continue }
            if max(sa, sb) < 2.0 { continue } // 止まっている間は使わない
            let i = bisectLeft(ts, a.t), j = bisectLeft(ts, b.t)
            if j - i < 5 { continue }
            var h1 = 0.0, h2 = 0.0
            for k in i..<j {
                h1 += dot(mot[k].a, e1)
                h2 += dot(mot[k].a, e2)
            }
            samples.append(((sb - sa) / (b.t - a.t) / G0, h1 / Double(j - i), h2 / Double(j - i)))
        }
        guard samples.count >= 20 else { throw DriveEvalError.tooShort }
        // 最小二乗で lon ≈ w1*h1 + w2*h2
        var s11 = 0.0, s12 = 0.0, s22 = 0.0, t1 = 0.0, t2 = 0.0
        for s in samples {
            s11 += s.1 * s.1; s12 += s.1 * s.2; s22 += s.2 * s.2
            t1 += s.0 * s.1; t2 += s.0 * s.2
        }
        let det = s11 * s22 - s12 * s12
        guard det != 0 else { throw DriveEvalError.tooShort }
        let w1 = (t1 * s22 - t2 * s12) / det, w2 = (t2 * s11 - t1 * s12) / det
        let fwd = norm(w1 * e1 + w2 * e2)
        let left = cross(up, fwd)
        let f1 = dot(fwd, e1), f2 = dot(fwd, e2)
        let quality = corr(samples.map { $0.0 }, samples.map { $0.1 * f1 + $0.2 * f2 })
        return Axes(up: up, fwd: fwd, left: left, quality: quality)
    }

    // MARK: - 10 Hz にそろえる

    /// 評価に使う 10 Hz の 1 行
    struct Row {
        /// 左向きの加速度(G)
        var rx: Double
        /// 後ろ向きの加速度(G)
        var ry: Double
        var kmh: Double
        var lat: Double
        var lon: Double
        var stopped: Bool
        /// 採点に使える行か(手持ちで端末を手で動かした区間は false。固定ならいつも true)
        var valid: Bool = true
    }

    static func lerpDeg(_ a: Double, _ b: Double, _ r: Double) -> Double {
        let d = pyMod(b - a + 180, 360) - 180
        return pyMod(a + d * r, 360)
    }

    /// Python の % と同じく、割る数と同じ符号の余り
    static func pyMod(_ a: Double, _ b: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: b)
        return r != 0 && (r < 0) != (b < 0) ? r + b : r
    }

    /// 時刻 t の位置と速度(m/s)。前後の点を直線で補間する
    static func locationAt(_ locs: [Loc], _ lts: [Double], _ t: Double) -> (la: Double, lo: Double, sp: Double) {
        let k = bisectRight(lts, t)
        if k == 0 { return (locs[0].la, locs[0].lo, 0) }
        if k >= locs.count { return (locs[locs.count - 1].la, locs[locs.count - 1].lo, 0) }
        let a = locs[k - 1], b = locs[k]
        let r = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        let sa = a.sp ?? 0, sb = b.sp ?? 0
        return (a.la + (b.la - a.la) * r, a.lo + (b.lo - a.lo) * r, sa + (sb - sa) * r)
    }

    static func resample(locs: [Loc], mot: [Mot], axes: Axes, t0: Double, t1: Double) -> [Row] {
        let ts = mot.map(\.t)
        let lts = locs.map(\.t)
        let n = Int(((t1 - t0) * Double(HZ)).rounded(.down)) + 1
        var raw: [(x: Double, y: Double, yaw: Double)] = []
        var vib: [Double?] = []
        raw.reserveCapacity(n)
        vib.reserveCapacity(n)
        for i in 0..<n {
            let t = t0 + Double(i) / Double(HZ)
            let a = bisectLeft(ts, t - 0.05), b = bisectLeft(ts, t + 0.05)
            if b > a {
                var acc = Vec3(0, 0, 0), rot = Vec3(0, 0, 0)
                for k in a..<b { acc += mot[k].a; rot += mot[k].r }
                acc /= Double(b - a)
                rot /= Double(b - a)
                raw.append((dot(acc, axes.left), -dot(acc, axes.fwd), dot(rot, axes.up)))
                // 0.1 秒の中の細かい揺れ(エンジンや路面の振動)
                var ss = 0.0
                for k in a..<b {
                    let d = mot[k].a - acc
                    ss += d.x * d.x + d.y * d.y + d.z * d.z
                }
                vib.append((ss / Double(b - a)).squareRoot())
            } else {
                raw.append((0, 0, 0)) // 加速度が無い区間は 0
                vib.append(nil)
            }
        }

        var gps = (0..<n).map { locationAt(locs, lts, t0 + Double($0) / Double(HZ)) }
        let stopped = detectStops(yaw: raw.map { $0.yaw }, vib: vib, gpsKmh: gps.map { $0.sp * 3.6 })
        applyStops(&gps, stopped)

        return (0..<n).map { i in
            Row(rx: raw[i].x, ry: raw[i].y, kmh: gps[i].sp * 3.6, lat: gps[i].la, lon: gps[i].lo, stopped: stopped[i])
        }
    }

    /// 止まっている間は速度 0、位置は停止中の中央値に固定する(前後 1 秒はなめらかにつなぐ)
    static func applyStops(_ gps: inout [(la: Double, lo: Double, sp: Double)], _ stopped: [Bool]) {
        let n = gps.count
        var i = 0
        while i < n {
            if !stopped[i] { i += 1; continue }
            var j = i
            while j < n && stopped[j] { j += 1 }
            let mla = gps[i..<j].map { $0.la }.sorted()[(j - i) / 2]
            let mlo = gps[i..<j].map { $0.lo }.sorted()[(j - i) / 2]
            for k in i..<j { gps[k] = (mla, mlo, 0) }
            let r = Int(stopRampS * Double(HZ))
            for k in Array(max(0, i - r)..<i) + Array(j..<min(n, j + r)) {
                if stopped[k] { continue }
                let f = k < i ? Double(i - k) / Double(r + 1) : Double(k - j + 1) / Double(r + 1)
                let g = gps[k]
                gps[k] = (mla + (g.la - mla) * f, mlo + (g.lo - mlo) * f, g.sp * f)
            }
            i = j
        }
    }

    static func pct(_ vals: [Double], _ q: Double) -> Double? {
        guard !vals.isEmpty else { return nil }
        let s = vals.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * q))]
    }

    /// 10 Hz の各行が停止中かどうか(drivelog2gbowl.py の detect_stops と同じ)
    static func detectStops(yaw rawYaw: [Double], vib: [Double?], gpsKmh: [Double]) -> [Bool] {
        let n = rawYaw.count
        let w = HZ
        var preV = [0.0], preY = [0.0], cnt = [0]
        for i in 0..<n {
            preV.append(preV[i] + (vib[i] ?? 0))
            cnt.append(cnt[i] + (vib[i] != nil ? 1 : 0))
            preY.append(preY[i] + abs(rawYaw[i]))
        }
        var shake: [Double?] = [], yaw: [Double] = []
        for i in 0..<n {
            let lo = max(0, i - w), hi = min(n, i + w + 1)
            let c = cnt[hi] - cnt[lo]
            shake.append(c > 0 ? (preV[hi] - preV[lo]) / Double(c) : nil)
            yaw.append((preY[hi] - preY[lo]) / Double(hi - lo))
        }
        let moving = pct(zip(shake, gpsKmh).compactMap { v, s in v != nil && s > 20 ? v : nil }, 0.1)
        let still = pct(zip(shake, gpsKmh).compactMap { v, s in v != nil && s < 2 ? v : nil }, 0.5)
        let thr: Double
        if let moving, let still, still < moving {
            thr = (moving * still).squareRoot()
        } else if let moving {
            thr = moving * 0.5
        } else {
            thr = 0.01
        }

        let quiet = (0..<n).map { i in
            shake[i] != nil && shake[i]! < thr && yaw[i] < stopYaw && gpsKmh[i] < stopMaxKmh
        }
        var out = [Bool](repeating: false, count: n)
        var state = false, run = 0
        let enter = Int(stopEnterS * Double(HZ)), leave = max(1, Int(stopExitS * Double(HZ)))
        for i in 0..<n {
            if quiet[i] != state {
                run += 1
                if run >= (state ? leave : enter) {
                    state = quiet[i]
                    run = 0
                    if state {
                        for k in max(0, i - enter + 1)..<max(max(0, i - enter + 1), i) { out[k] = true }
                    }
                }
            } else {
                run = 0
            }
            out[i] = state
        }
        // 短い隙間でつながる停止はまとめ、短い停止は捨てる
        let m = Int(stopMinS * Double(HZ))
        for (want, fill) in [(false, true), (true, false)] {
            var i = 0
            while i < n {
                if out[i] != want { i += 1; continue }
                var j = i
                while j < n && out[j] == want { j += 1 }
                let inner = i > 0 && j < n
                if (!want && inner && j - i < m) || (want && j - i < m) {
                    for k in i..<j { out[k] = fill }
                }
                i = j
            }
        }
        return out
    }

    // MARK: - 評価(drive_eval.py と同じ)

    static func biquad(_ xs: [Double], _ b: (Double, Double, Double), _ a: (Double, Double, Double)) -> [Double] {
        var y: [Double] = []
        y.reserveCapacity(xs.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for x in xs {
            let v = b.0 * x + b.1 * x1 + b.2 * x2 - a.1 * y1 - a.2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = v
            y.append(v)
        }
        return y
    }

    /// 2次のバターワース(双一次変換)。high = true で高域通過
    static func butter2(_ xs: [Double], _ fc: Double, high: Bool) -> [Double] {
        let k = tan(Double.pi * fc / Double(HZ))
        let q = 2.0.squareRoot()
        let n = 1 / (1 + q * k + k * k)
        let b = high ? (n, -2 * n, n) : (k * k * n, 2 * k * k * n, k * k * n)
        let a = (1.0, 2 * (k * k - 1) * n, (1 - q * k + k * k) * n)
        return biquad(xs, b, a)
    }

    /// 0.1〜0.5 Hz(乗り物酔いを起こしやすい、2〜10秒周期のゆっくりした揺れ)
    static func bandpass(_ xs: [Double]) -> [Double] { butter2(butter2(xs, 0.1, high: true), 0.5, high: false) }

    static func smooth(_ xs: [Double], _ w: Int) -> [Double] {
        var pre = [0.0]
        pre.reserveCapacity(xs.count + 1)
        for v in xs { pre.append(pre[pre.count - 1] + v) }
        let n = xs.count
        return (0..<n).map { i in
            let lo = max(0, i - w), hi = min(n, i + w + 1)
            return (pre[hi] - pre[lo]) / Double(hi - lo)
        }
    }

    static func diff(_ xs: [Double]) -> [Double] {
        guard !xs.isEmpty else { return [] }
        return [0.0] + zip(xs, xs.dropFirst()).map { ($1 - $0) * Double(HZ) }
    }

    static func score(_ v: Double, _ good: Double, _ bad: Double) -> Double {
        max(0, min(100, 100 * (bad - v) / (bad - good)))
    }

    static func round(_ v: Double, _ digits: Int) -> Double {
        let p = pow(10.0, Double(digits))
        return (v * p).rounded() / p
    }

    /// 範囲の中で key がいちばん大きい位置(同じなら最初。Python の max(range, key=) と同じ)
    static func argmax(_ r: Range<Int>, _ key: (Int) -> Double) -> Int {
        var best = r.lowerBound, bv = key(best)
        for i in r.dropFirst() where key(i) > bv { best = i; bv = key(i) }
        return best
    }

    static func evaluate(rows: [Row], t0Unix: Double) -> Evaluation {
        let n = rows.count
        let hz = Double(HZ)
        let lon = rows.map { -$0.ry * G0 } // 前向きの加速度(m/s^2)
        let lat = rows.map { $0.rx * G0 }  // 左向きの加速度(m/s^2)
        let moving = rows.map { $0.kmh > movingKmh }
        let tMoving = Double(moving.filter { $0 }.count) / hz
        // 採点に使える行(手持ちで端末を手で動かした区間を除く)。固定なら全部
        let ok = rows.map(\.valid)
        let use = (0..<n).map { moving[$0] && ok[$0] }
        let tUse = Double(use.filter { $0 }.count) / hz

        // ならしてから微分する(路面の段差などの細かい揺れを躍度と見ないように)
        let w = Int(jerkSmoothS * hz / 2)
        let slon = smooth(lon, w), slat = smooth(lat, w)
        let jlon = diff(slon), jlat = diff(slat)
        let jmag = zip(jlon, jlat).map { ($0 * $0 + $1 * $1).squareRoot() }

        // 1. 酔いやすさ(手持ちで外した区間は GPS の速度の変化で埋めてあるので、走行中は全部使う)
        let blon = bandpass(lon), blat = bandpass(lat)
        var energy = 0.0
        for i in 0..<n where moving[i] { energy += blon[i] * blon[i] + blat[i] * blat[i] }
        energy /= hz
        let sick = tMoving > 0 ? (energy / tMoving).squareRoot() : 0

        // 2. 躍度
        let jerk = pct((0..<n).filter { use[$0] }.map { jmag[$0] }, 0.95) ?? 0

        // 3. 急な操作
        var spans: [(start: Int, end: Int)] = []
        for i in 0..<n where ok[i] {
            let aLon = slon[i] / G0, aLat = slat[i] / G0
            let hit = abs(aLon) > harshG || abs(aLat) > harshG ||
                (moving[i] && jmag[i] > harshJerk && max(abs(aLon), abs(aLat)) > harshJerkG)
            if !hit { continue }
            if let last = spans.last, Double(i - last.end) <= harshMergeS * hz {
                spans[spans.count - 1].end = i
            } else {
                spans.append((i, i))
            }
        }
        var harshEvents: [EvalEvent] = []
        for e in spans {
            let seg = e.start..<(e.end + 1)
            let kLon = argmax(seg) { abs(slon[$0]) }
            let kLat = argmax(seg) { abs(slat[$0]) }
            let kJ = argmax(seg) { jmag[$0] }
            let gLon = slon[kLon] / G0, gLat = slat[kLat] / G0
            if abs(gLon) > harshG && abs(gLon) >= abs(gLat) {
                harshEvents.append(event(gLon < 0 ? "急ブレーキ" : "急加速", rows, t0Unix, e.start, e.end, kLon, abs(gLon), "G"))
            } else if abs(gLat) > harshG {
                harshEvents.append(event("急ハンドル", rows, t0Unix, e.start, e.end, kLat, abs(gLat), "G"))
            } else {
                harshEvents.append(event("急な操作", rows, t0Unix, e.start, e.end, kJ, jmag[kJ], "m/s3"))
            }
        }
        let harsh = tUse > 0 ? Double(harshEvents.count) / (tUse / 600) : 0

        // 4. 止まり際
        var stopVals: [Double] = [], stopEvents: [EvalEvent] = []
        if n > 1 {
            for i in 1..<n where rows[i].stopped && !rows[i - 1].stopped {
                let lo = max(0, i - HZ), hi = min(n, i + HZ / 2)
                if lo >= hi || ok[lo..<hi].contains(false) { continue }
                let k = argmax(lo..<hi) { abs(jlon[$0]) }
                let v = abs(jlon[k])
                stopVals.append(v)
                if v > stopEventJerk { stopEvents.append(event("カックン", rows, t0Unix, lo, hi - 1, k, v, "m/s3")) }
            }
        }
        let stop = stopVals.isEmpty ? 0 : stopVals.reduce(0, +) / Double(stopVals.count)

        // 5. カーブのつなぎ
        let curve = pct((0..<n).filter { use[$0] && abs(slat[$0]) / G0 > curveG }.map { jmag[$0] }, 0.95) ?? 0

        let values = ["sick": sick, "jerk": jerk, "harsh": harsh, "stop": stop, "curve": curve]
        var out: [EvalItem] = []
        var total = 0.0
        for it in items {
            let s = score(values[it.key]!, it.good, it.bad)
            total += s * it.weight
            out.append(EvalItem(key: it.key, name: it.name, value: round(values[it.key]!, 3), score: round(s, 1),
                                weight: it.weight, good: it.good, bad: it.bad))
        }
        let events = (harshEvents + stopEvents).enumerated()
            .sorted { $0.element.tUnix != $1.element.tUnix ? $0.element.tUnix < $1.element.tUnix : $0.offset < $1.offset }
            .map { $0.element }
        return Evaluation(score: round(total, 1), items: out, movingS: round(tMoving, 1), stops: stopVals.count, events: events)
    }

    static func event(_ kind: String, _ rows: [Row], _ t0: Double, _ start: Int, _ end: Int, _ k: Int,
                      _ value: Double, _ unit: String) -> EvalEvent {
        let hz = Double(HZ)
        return EvalEvent(kind: kind, type: eventTypes[kind]!, value: round(value, 3), unit: unit,
                         tUnix: round(t0 + Double(k) / hz, 1),
                         startUnix: round(t0 + Double(start) / hz, 1), endUnix: round(t0 + Double(end) / hz, 1),
                         lat: round(rows[k].lat, 7), lon: round(rows[k].lon, 7), kmh: round(rows[k].kmh, 1))
    }
}
