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
    /// 走行フォルダを読む。motion = false(車以外)なら加速度は読まない。
    /// pressure = false なら高度に気圧を使わない(飛行機は機内が与圧されていて、気圧が外の高度と合わないため)。
    /// handheld = true(同乗)なら、端末が固定されていなければ手持ちの方法で前後G・横Gを出す
    static func load(folder: URL, motion: Bool, pressure: Bool = true, handheld: Bool = false) throws -> ReviewData {
        let rows = try DriveEval.readCSV(locationFile(folder), columns: ["unix_s", "lat", "lon", "alt_m", "h_acc_m", "v_acc_m", "speed_ms", "speed_est_ms"])
        var gps: [(t: Double, la: Double, lo: Double, alt: Double?, sp: Double?)] = []
        for r in rows {
            // 補った点(精度が空で推定の速度がある)も使う
            guard let t = r[0], let la = r[1], let lo = r[2], let acc = r[4] ?? (r[7] != nil ? 0 : nil), acc <= 50 else { continue }
            let alt = (r[5].map { $0 >= 0 && $0 <= 30 } ?? false) ? r[3] : nil
            // GPS の速度がない点(トンネルなど)は、記録中に位置の動きから推定した速度を使う
            gps.append((t, la, lo, alt, (r[6] ?? r[7]).map { max(0, $0) }))
        }
        gps.sort { $0.t < $1.t }
        guard let g0 = gps.first, let g1 = gps.last, g1.t > g0.t else { throw DriveEvalError.noData }

        // 車なら評価と同じ方法で 10 Hz にそろえ、前後G・横G・躍度を出す
        var dense: [(t: Double, la: Double, lo: Double, kmh: Double, lonG: Double?, latG: Double?, jerk: Double?)] = []
        var hasMotion = false
        if motion, let m = try? motionRows(folder: folder, handheld: handheld) {
            dense = m
            hasMotion = true
        } else {
            dense = gps.map { ($0.t, $0.la, $0.lo, ($0.sp ?? 0) * 3.6, nil, nil, nil) }
        }
        guard let d0 = dense.first else { throw DriveEvalError.noData }

        // 高度: 気圧の相対高度に、GPS の高度との差(中央値)を足す
        let alt = altitude(folder: folder, gps: gps.compactMap { g in g.alt.map { (g.t, $0) } }, usePressure: pressure)

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

    /// 位置のファイル。地図サーバーがトンネルなどで途切れた区間を道路に沿って補った location_filled.csv を
    /// 受け取っていればそれを、なければ location.csv を使う
    static func locationFile(_ folder: URL) -> URL {
        let filled = folder.appendingPathComponent(filledFile)
        return FileManager.default.fileExists(atPath: filled.path) ? filled : folder.appendingPathComponent("location.csv")
    }

    static let filledFile = "location_filled.csv"

    /// 振り返り用の位置。補った点(精度が空で推定の速度がある)も使い、GPS の速度がない点は推定の速度にする
    static func reviewLocations(_ folder: URL) throws -> [DriveEval.Loc] {
        let rows = try DriveEval.readCSV(locationFile(folder), columns: ["unix_s", "lat", "lon", "h_acc_m", "speed_ms", "course_deg", "speed_est_ms"])
        var out: [DriveEval.Loc] = []
        for r in rows {
            guard let t = r[0], let la = r[1], let lo = r[2], let acc = r[3] ?? (r[6] != nil ? 0 : nil), acc <= 50 else { continue }
            out.append(DriveEval.Loc(t: t, la: la, lo: lo, sp: r[4] ?? r[6], cs: r[5]))
        }
        return out.sorted { $0.t < $1.t }
    }

    /// 10 Hz の行(DriveEval と同じ車の向き・停止の判定・ならし方)
    static func motionRows(folder: URL, handheld: Bool = false) throws -> [(t: Double, la: Double, lo: Double, kmh: Double, lonG: Double?, latG: Double?, jerk: Double?)] {
        // 車の向きは評価と同じく GPS の点だけで決め、位置と速度は補った点も使う
        let gpsLocs = try DriveEval.loadLocations(folder.appendingPathComponent("location.csv"))
        let locs = try reviewLocations(folder)
        let mot = try DriveEval.loadMotion(folder.appendingPathComponent("motion.csv"))
        let p = try DriveEval.prepare(locs: locs, gpsLocs: gpsLocs, mot: mot, allowHandheld: handheld)
        let rows = p.rows, s0 = p.t0
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

    static func altitude(folder: URL, gps: [(Double, Double)], usePressure: Bool = true) -> Altitude? {
        let url = folder.appendingPathComponent("pressure.csv")
        let rows = usePressure ? ((try? DriveEval.readCSV(url, columns: ["unix_s", "rel_alt_m"])) ?? []) : []
        let pr = rows.compactMap { r -> (Double, Double)? in
            guard let t = r[0], let a = r[1] else { return nil }
            return (t, a)
        }.sorted { $0.0 < $1.0 }
        if pr.count >= 2, pressureMatchesGPS(pressure: pr.map(\.1), gps: gps.map(\.1)) {
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

    /// 気圧の高度の変化が GPS の高度の変化と大きく食い違っていないか。
    /// 与圧された乗り物の中などでは、GPS で数千 m 上っても気圧はあまり変わらない
    static func pressureMatchesGPS(pressure: [Double], gps: [Double]) -> Bool {
        guard let gLo = DriveEval.pct(gps, 0.05), let gHi = DriveEval.pct(gps, 0.95),
              let pLo = DriveEval.pct(pressure, 0.05), let pHi = DriveEval.pct(pressure, 0.95) else { return true }
        let g = gHi - gLo, p = pHi - pLo
        return g < 300 || p > g * 0.5
    }

    /// 2 点間の距離(m)
    static func distanceM(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dla = (la2 - la1) * rad, dlo = (lo2 - lo1) * rad
        let a = sin(dla / 2) * sin(dla / 2) + cos(la1 * rad) * cos(la2 * rad) * sin(dlo / 2) * sin(dlo / 2)
        return 2 * r * asin(min(1, a.squareRoot()))
    }
}
