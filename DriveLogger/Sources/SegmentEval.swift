import Foundation

// 区間ごとの採点(カーブ・交差点の右左折・停止・発進を1つずつ切り出して 0〜100 点を付ける。総合点には入れない)。
// gbowl-log-formatter の src/drive_eval.py の segments() をそのまま Swift に移したもの。数字や手順を変えたら、両方を直すこと。
// UIKit を使わない(CI の evalcheck で Python と同じ結果になるかを確かめるため)

/// 区間の 1 項目
struct EvalSegItem: Codable, Hashable {
    var key: String
    var name: String
    var value: Double
    var score: Double
    var good: Double
    var bad: Double
}

/// 採点した 1 区間
struct EvalSegment: Codable, Hashable {
    /// "curve"(カーブ)・"turn"(交差点の右左折)・"stop"(停止)・"start"(発進)
    var kind: String
    /// 「右カーブ」「左折」「停止」「発進」など
    var name: String
    /// "left" か "right"(カーブと右左折だけ)
    var side: String?
    var score: Double
    var items: [EvalSegItem]
    var startUnix: Double
    var endUnix: Double
    /// いちばん強かった所の時刻(停止は止まった時刻)
    var tUnix: Double
    var lat: Double
    var lon: Double
    var kmh: Double
    /// 向きの変わり方(度。カーブと右左折だけ)
    var angleDeg: Double?
    /// 区間の最低速度(km/h。カーブと右左折だけ)
    var minKmh: Double?

    enum CodingKeys: String, CodingKey {
        case kind, name, side, score, items, lat, lon, kmh
        case startUnix = "start_unix", endUnix = "end_unix", tUnix = "t_unix", angleDeg = "angle_deg", minKmh = "min_kmh"
    }

    /// カーブ(右左折を含む)・停止・発進のどれか。種類ごとの平均に使う
    var group: String { kind == "turn" ? "curve" : kind }
}

/// 種類ごとの回数と平均点
struct EvalSegStat: Codable, Hashable {
    var count: Int
    var score: Double?
}

enum SegmentEval {
    typealias G = DriveEval

    // 項目: (キー, 名前, 100点の値, 0点の値)。値が小さいほど良い。区間の点数は項目の平均
    static let items: [String: [(key: String, name: String, good: Double, bad: Double)]] = [
        "curve": [("size", "小ささ", 0.15, 0.35),     // G(区間の最大の横G)
                  ("slow", "ゆっくり", 1.0, 4.0),      // m/s^3(区間の合成Gの変化の速さの最大)
                  ("stroke", "一筆", 0.0, 0.15)],      // G(合成Gが途中で落ちてまた上がった量)
        "stop": [("size", "減速の強さ", 0.15, 0.35),  // G(最大の減速G)
                 ("onset", "踏み始め", 1.0, 4.0),      // m/s^3(減速が強まるまでの前後の躍度の最大)
                 ("stop", "止まり際", 0.5, 4.0)],      // m/s^3(停止直前1秒の前後の躍度の最大)
        "start": [("size", "加速の強さ", 0.12, 0.30), // G(最大の加速G)
                  ("onset", "踏み始め", 1.0, 4.0)],    // m/s^3(加速が強まるまでの前後の躍度の最大)
    ]
    static let edgeG = 0.05
    static let edgeMaxS = 5.0
    static let mergeS = 1.0
    static let minS = 2.0
    static let turnKmh = 25.0
    static let turnDeg = 60.0
    static let lonG = 0.03
    static let stopLookS = 3.0
    static let stopSegMaxS = 20.0
    static let startSegMaxS = 15.0
    static let startWaitS = 3.0
    static let startEndKmh = 40.0

    static let names: [String: String] = [
        "curve/left": "左カーブ", "curve/right": "右カーブ", "turn/left": "左折", "turn/right": "右折",
        "stop/": "停止", "start/": "発進",
    ]

    /// true が続く範囲 [(始め, 終わり+1)]
    static func runs(_ flags: [Bool]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var i = 0
        let n = flags.count
        while i < n {
            if !flags[i] { i += 1; continue }
            var j = i
            while j < n && flags[j] { j += 1 }
            out.append((i, j))
            i = j
        }
        return out
    }

    /// 一筆で描けたか: 合成Gが山を1つ越える以外に、途中で落ちてまた上がった量(G)
    static func strokeBack(_ g: ArraySlice<Double>) -> Double {
        guard g.count >= 2, let mx = g.max(), let first = g.first, let last = g.last else { return 0 }
        var tv = 0.0
        for (a, b) in zip(g, g.dropFirst()) { tv += abs(b - a) }
        return max(0, (tv - (2 * mx - first - last)) / 2)
    }

    static func argmin(_ r: Range<Int>, _ key: (Int) -> Double) -> Int {
        var best = r.lowerBound, bv = key(best)
        for i in r.dropFirst() where key(i) < bv { best = i; bv = key(i) }
        return best
    }

    static func segment(_ kind: String, _ side: String?, _ rows: [DriveEval.Row], _ t0: Double,
                        _ a: Int, _ b: Int, _ k: Int, _ values: [String: Double],
                        angle: Double? = nil, minKmh: Double? = nil) -> EvalSegment {
        let hz = Double(G.HZ)
        var out: [EvalSegItem] = []
        var total = 0.0
        for it in items[kind == "turn" ? "curve" : kind]! {
            let s = G.score(values[it.key]!, it.good, it.bad)
            total += s
            out.append(EvalSegItem(key: it.key, name: it.name, value: G.round(values[it.key]!, 3), score: G.round(s, 1),
                                   good: it.good, bad: it.bad))
        }
        return EvalSegment(kind: kind, name: names["\(kind)/\(side ?? "")"]!, side: side,
                           score: G.round(total / Double(out.count), 1), items: out,
                           startUnix: G.round(t0 + Double(a) / hz, 1), endUnix: G.round(t0 + Double(b - 1) / hz, 1),
                           tUnix: G.round(t0 + Double(k) / hz, 1),
                           lat: G.round(rows[k].lat, 7), lon: G.round(rows[k].lon, 7), kmh: G.round(rows[k].kmh, 1),
                           angleDeg: angle, minKmh: minKmh)
    }

    /// slon / slat は 1 秒ならした前後・左右の加速度(m/s^2)、jlon / jmag は躍度。ok は採点に使える行
    static func segments(rows: [DriveEval.Row], t0: Double, slon: [Double], slat: [Double], jlon: [Double],
                         jmag: [Double], moving: [Bool], ok: [Bool]) -> [EvalSegment] {
        let n = rows.count
        let hz = G.HZ
        let glat = slat.map { $0 / G.G0 }
        let glon = slon.map { $0 / G.G0 }
        let gmag = zip(glon, glat).map { ($0 * $0 + $1 * $1).squareRoot() }
        let stopped = rows.map(\.stopped)
        let kmh = rows.map(\.kmh)
        var out: [EvalSegment] = []

        // カーブ: 横Gが curveG を超えた所を芯にし、同じ向きの短い切れ目はつなぐ
        var cores: [(a: Int, b: Int, left: Bool)] = []
        for (a, b) in runs((0..<n).map { moving[$0] && abs(glat[$0]) > G.curveG }) {
            let left = glat[a] > 0
            if let last = cores.last, last.left == left, Double(a - last.b) < mergeS * Double(hz) {
                cores[cores.count - 1].b = b
            } else {
                cores.append((a, b, left))
            }
        }
        let edge = Int(edgeMaxS * Double(hz))
        var prevEnd = 0
        for (c, core) in cores.enumerated() {
            let sign = core.left ? 1.0 : -1.0
            var lo = core.a
            while lo > max(prevEnd, core.a - edge) && moving[lo - 1] && sign * glat[lo - 1] > edgeG { lo -= 1 }
            let nxt = c + 1 < cores.count ? cores[c + 1].a : n
            var hi = core.b
            while hi < min(nxt, core.b + edge) && moving[hi] && sign * glat[hi] > edgeG { hi += 1 }
            prevEnd = hi
            if Double(hi - lo) < minS * Double(hz) || ok[lo..<hi].contains(false) { continue }
            var ang = 0.0
            for i in lo..<hi { ang += slat[i] / max(kmh[i] / 3.6, 3.0) }
            ang = ang / Double(hz) * 180 / Double.pi
            let vmin = kmh[lo..<hi].min()!
            let kind = vmin < turnKmh && abs(ang) >= turnDeg ? "turn" : "curve"
            let k = DriveEval.argmax(lo..<hi) { abs(glat[$0]) }
            let values = ["size": abs(glat[k]), "slow": jmag[lo..<hi].max()!, "stroke": strokeBack(gmag[lo..<hi])]
            out.append(segment(kind, core.left ? "left" : "right", rows, t0, lo, hi, k, values,
                               angle: abs(ang).rounded(), minKmh: G.round(vmin, 1)))
        }

        if n > 1 {
            for i in 1..<n {
                // 停止: 止まる直前はブレーキをゆるめて減速が弱まっていることが多いので、stopLookS さかのぼって減速を探す
                if stopped[i] && !stopped[i - 1] {
                    var j = i
                    while j > max(0, i - Int(stopLookS * Double(hz))) && !stopped[j - 1] && glon[j - 1] >= -lonG { j -= 1 }
                    var lo = j
                    while lo > max(0, i - Int(stopSegMaxS * Double(hz))) && !stopped[lo - 1] && glon[lo - 1] < -lonG { lo -= 1 }
                    if lo == j { lo = max(0, i - Int(stopLookS * Double(hz))) }
                    if !moving[lo..<i].contains(true) { continue }
                    let hi = min(n, i + hz / 2)
                    if i - lo < hz || ok[max(0, lo)..<hi].contains(false) { continue }
                    let kb = argmin(lo..<i) { glon[$0] }
                    let ks = DriveEval.argmax(max(0, i - hz)..<hi) { abs(jlon[$0]) }
                    let onset = (lo...kb).map { abs(jlon[$0]) }.max()!
                    out.append(segment("stop", nil, rows, t0, lo, i, i - 1,
                                       ["size": -glon[kb], "onset": onset, "stop": abs(jlon[ks])]))
                }
                // 発進: 停止の終わりから、加速が弱まるか startEndKmh に届くまで
                if !stopped[i] && stopped[i - 1] {
                    let a = i
                    let wait = min(n, i + Int(startWaitS * Double(hz)))
                    var j = a
                    while j < wait && !stopped[j] && glon[j] <= lonG { j += 1 }
                    if j >= wait || stopped[j] { continue }
                    var hi = j
                    let top = min(n, a + Int(startSegMaxS * Double(hz)))
                    while hi < top && !stopped[hi] && glon[hi] > lonG && kmh[hi] < startEndKmh { hi += 1 }
                    if hi - a < hz || ok[a..<hi].contains(false) { continue }
                    let kp = DriveEval.argmax(a..<hi) { glon[$0] }
                    let onset = (a...kp).map { abs(jlon[$0]) }.max()!
                    out.append(segment("start", nil, rows, t0, a, hi, kp, ["size": glon[kp], "onset": onset]))
                }
            }
        }
        return out.enumerated().sorted {
            let x = $0.element, y = $1.element
            if x.endUnix != y.endUnix { return x.endUnix < y.endUnix }
            if x.startUnix != y.startUnix { return x.startUnix < y.startUnix }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    /// 種類ごとの回数と平均点。カーブは交差点の右左折も含む
    static func stats(_ segs: [EvalSegment]) -> [String: EvalSegStat] {
        var out: [String: EvalSegStat] = [:]
        for key in ["curve", "stop", "start"] {
            let sc = segs.filter { $0.group == key }.map(\.score)
            out[key] = EvalSegStat(count: sc.count, score: sc.isEmpty ? nil : G.round(sc.reduce(0, +) / Double(sc.count), 1))
        }
        return out
    }
}
