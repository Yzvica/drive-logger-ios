import Foundation

// 振り返り画面(地図とグラフ)に出すデータを走行フォルダから作る。
// UIKit を使わない(CI で macOS のコマンドとしてもビルドし、サンプルの走行で作れるかを確かめるため)

/// グラフの 1 点(地図の丸もこの点の位置に置く)
struct ReviewSample: Hashable {
    /// 開始からの秒
    var t: Double
    var unix: Double
    var lat: Double
    var lon: Double
    /// 開始からの距離(km)
    var km: Double
    var kmh: Double
    /// 高度(m)。気圧の変化で補正したもの(気圧が無ければ GPS の高度)
    var altM: Double?
    /// 前後の加速度(G、加速が +・減速が -)。車の向きが分からなければ nil
    var lonG: Double?
    /// 左右の加速度(G、体が右に押される向き(左に曲がる)が +)
    var latG: Double?
    /// 躍度(m/s³、前後と左右を合わせた大きさ)
    var jerk: Double?
}

struct ReviewData {
    var samples: [ReviewSample]
    /// 前後G・横G・躍度があるか(車で、端末の向きが決まったとき)
    var hasMotion: Bool
    var hasAltitude: Bool
    /// 気圧で高度を補正したか
    var altitudeFromPressure: Bool

    /// グラフに出す点の数の上限(長い走行でも描くのが重くならないように)
    static let maxSamples = 1500

    /// 時刻(開始からの秒)にいちばん近い点の位置
    func index(atT t: Double) -> Int {
        nearest(samples.map(\.t), t)
    }

    func index(atKm km: Double) -> Int {
        nearest(samples.map(\.km), km)
    }

    func index(atUnix unix: Double) -> Int {
        index(atT: unix - (samples.first?.unix ?? 0))
    }

    private func nearest(_ xs: [Double], _ x: Double) -> Int {
        guard !xs.isEmpty else { return 0 }
        let k = DriveEval.bisectLeft(xs, x)
        if k <= 0 { return 0 }
        if k >= xs.count { return xs.count - 1 }
        return x - xs[k - 1] <= xs[k] - x ? k - 1 : k
    }
}

enum ReviewLoader {
    /// 走行フォルダを読む。motion = false(車以外)なら加速度は読まない
    static func load(folder: URL, motion: Bool) throws -> ReviewData {
        let locURL = folder.appendingPathComponent("location.csv")
        let rows = try DriveEval.readCSV(locURL, columns: ["unix_s", "lat", "lon", "alt_m", "h_acc_m", "v_acc_m", "speed_ms"])
        var gps: [(t: Double, la: Double, lo: Double, alt: Double?, sp: Double?)] = []
        for r in rows {
            guard let t = r[0], let la = r[1], let lo = r[2], let acc = r[4], acc <= 50 else { continue }
            let alt = (r[5].map { $0 >= 0 && $0 <= 30 } ?? false) ? r[3] : nil
            gps.append((t, la, lo, alt, r[6].map { max(0, $0) }))
        }
        gps.sort { $0.t < $1.t }
        guard let g0 = gps.first, let g1 = gps.last, g1.t > g0.t else { throw DriveEvalError.noData }

        // 車なら評価と同じ方法で 10 Hz にそろえ、前後G・横G・躍度を出す
        var dense: [(t: Double, la: Double, lo: Double, kmh: Double, lonG: Double?, latG: Double?, jerk: Double?)] = []
        var hasMotion = false
        if motion, let m = try? motionRows(folder: folder) {
            dense = m
            hasMotion = true
        } else {
            dense = gps.map { ($0.t, $0.la, $0.lo, ($0.sp ?? 0) * 3.6, nil, nil, nil) }
        }
        guard let d0 = dense.first else { throw DriveEvalError.noData }

        // 高度: 気圧の相対高度に、GPS の高度との差(中央値)を足す
        let alt = altitude(folder: folder, gps: gps.compactMap { g in g.alt.map { (g.t, $0) } })

        // 区切りごとにまとめる。速度・位置は平均、G と躍度は絶対値が一番大きいもの(山を見逃さないため)
        let span = (dense.last?.t ?? d0.t) - d0.t
        let step = max(1.0, span / Double(ReviewData.maxSamples))
        var out: [ReviewSample] = []
        var km = 0.0
        var i = 0
        while i < dense.count {
            let bucket = Int((dense[i].t - d0.t) / step)
            var j = i
            var sLa = 0.0, sLo = 0.0, sV = 0.0
            var pLon: Double?, pLat: Double?, pJ: Double?
            while j < dense.count && Int((dense[j].t - d0.t) / step) == bucket {
                let d = dense[j]
                sLa += d.la; sLo += d.lo; sV += d.kmh
                if let v = d.lonG, abs(v) > abs(pLon ?? 0) || pLon == nil { pLon = v }
                if let v = d.latG, abs(v) > abs(pLat ?? 0) || pLat == nil { pLat = v }
                if let v = d.jerk, v > (pJ ?? -1) { pJ = v }
                j += 1
            }
            let n = Double(j - i)
            let la = sLa / n, lo = sLo / n
            if let prev = out.last { km += distanceM(prev.lat, prev.lon, la, lo) / 1000 }
            let t = dense[i].t
            out.append(ReviewSample(t: t - d0.t, unix: t, lat: la, lon: lo, km: km, kmh: sV / n,
                                    altM: alt?.at(t), lonG: pLon, latG: pLat, jerk: pJ))
            i = j
        }
        return ReviewData(samples: out, hasMotion: hasMotion,
                          hasAltitude: out.contains { $0.altM != nil },
                          altitudeFromPressure: alt?.fromPressure ?? false)
    }

    /// 10 Hz の行(DriveEval と同じ車の向き・停止の判定・ならし方)
    static func motionRows(folder: URL) throws -> [(t: Double, la: Double, lo: Double, kmh: Double, lonG: Double?, latG: Double?, jerk: Double?)] {
        let locs = try DriveEval.loadLocations(folder.appendingPathComponent("location.csv"))
        let mot = try DriveEval.loadMotion(folder.appendingPathComponent("motion.csv"))
        guard let l0 = locs.first, let l1 = locs.last, let m0 = mot.first, let m1 = mot.last else { throw DriveEvalError.noData }
        let axes = try DriveEval.vehicleAxes(locs: locs, mot: mot)
        let s0 = max(l0.t, m0.t), s1 = min(l1.t, m1.t)
        guard s1 > s0 else { throw DriveEvalError.noData }
        let rows = DriveEval.resample(locs: locs, mot: mot, axes: axes, t0: s0, t1: s1)
        let g0 = DriveEval.G0
        let w = Int(DriveEval.jerkSmoothS * Double(DriveEval.HZ) / 2)
        let slon = DriveEval.smooth(rows.map { -$0.ry * g0 }, w)
        let slat = DriveEval.smooth(rows.map { $0.rx * g0 }, w)
        let jlon = DriveEval.diff(slon), jlat = DriveEval.diff(slat)
        return rows.indices.map { i in
            (s0 + Double(i) / Double(DriveEval.HZ), rows[i].lat, rows[i].lon, rows[i].kmh,
             slon[i] / g0, slat[i] / g0, (jlon[i] * jlon[i] + jlat[i] * jlat[i]).squareRoot())
        }
    }

    struct Altitude {
        var ts: [Double]
        var alts: [Double]
        var fromPressure: Bool

        func at(_ t: Double) -> Double? {
            guard !ts.isEmpty else { return nil }
            let k = DriveEval.bisectLeft(ts, t)
            if k <= 0 { return ts[0] - t <= 5 ? alts[0] : nil }
            if k >= ts.count { return t - ts[ts.count - 1] <= 5 ? alts[alts.count - 1] : nil }
            let r = (t - ts[k - 1]) / (ts[k] - ts[k - 1])
            return alts[k - 1] + (alts[k] - alts[k - 1]) * r
        }
    }

    static func altitude(folder: URL, gps: [(Double, Double)]) -> Altitude? {
        let url = folder.appendingPathComponent("pressure.csv")
        let rows = (try? DriveEval.readCSV(url, columns: ["unix_s", "rel_alt_m"])) ?? []
        let pr = rows.compactMap { r -> (Double, Double)? in
            guard let t = r[0], let a = r[1] else { return nil }
            return (t, a)
        }.sorted { $0.0 < $1.0 }
        if pr.count >= 2 {
            let pts = pr.map(\.0), pas = pr.map(\.1)
            let rel = Altitude(ts: pts, alts: pas, fromPressure: true)
            // GPS の高度との差の中央値で、気圧の相対高度を海抜にそろえる(GPS が無ければ開始地点を 0 m)
            let diffs = gps.compactMap { t, a in rel.at(t).map { a - $0 } }.sorted()
            let offset = diffs.isEmpty ? 0 : diffs[diffs.count / 2]
            return Altitude(ts: pts, alts: pas.map { $0 + offset }, fromPressure: true)
        }
        guard gps.count >= 2 else { return nil }
        return Altitude(ts: gps.map(\.0), alts: gps.map(\.1), fromPressure: false)
    }

    /// 2 点間の距離(m)
    static func distanceM(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dla = (la2 - la1) * rad, dlo = (lo2 - lo1) * rad
        let a = sin(dla / 2) * sin(dla / 2) + cos(la1 * rad) * cos(la2 * rad) * sin(dlo / 2) * sin(dlo / 2)
        return 2 * r * asin(min(1, a.squareRoot()))
    }
}
