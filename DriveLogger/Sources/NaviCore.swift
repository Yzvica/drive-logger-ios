import Foundation

// ナビ(コースの音声案内)の計算。位置からコースのどこにいるかを求め、曲がる所の手前で読み上げる文を作る。
// 画面・位置・音には触らない(Foundation だけ)ので、tools/navicheck で走行をまねて確かめられる。
// コースのデータは地図(national-route-conquest-map)の src/naviGuide.ts が作り、MiniPC の /api/navi/guide から受け取る。

/// 地図が作る案内のデータ(/api/navi/guide)
struct NaviGuideData: Codable {
    struct Maneuver: Codable {
        /// pts の添字
        var i: Int
        /// コースの最初からの距離(m)
        var at: Double
        /// turn / road / enterExp / jct / exitExp / free / arrive
        var kind: String
        /// 曲がる角度(右がプラス)
        var angle: Double
        /// 読み上げる文(「300メートル先、」は前に付ける)
        var text: String
        /// その先の道の名前
        var road: String
    }
    struct RoadMark: Codable {
        var i: Int
        var name: String
    }
    var v: Int
    var name: String
    var length: Double
    /// [緯度, 経度, 緯度, 経度, ...]
    var pts: [Double]
    var man: [Maneuver]
    var roads: [RoadMark]
    /// 一般道(データにない道)の区間 [始めの添字, 終わりの添字]
    var free: [[Int]]
    /// 高速道路の区間
    var exp: [[Int]]
    var savedAt: String?
}

struct GeoPoint: Equatable {
    var lat: Double
    var lon: Double
}

/// 2点の距離(m)。短い距離用の近似
func geoDistance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
    let x = (b.lon - a.lon) * 111_320 * cos((a.lat + b.lat) / 2 * .pi / 180)
    let y = (b.lat - a.lat) * 110_950
    return (x * x + y * y).squareRoot()
}

/// a から b への方位(度。北が 0、東が 90)
func geoBearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
    let x = (b.lon - a.lon) * cos((a.lat + b.lat) / 2 * .pi / 180)
    let y = b.lat - a.lat
    return atan2(x, y) * 180 / .pi
}

/// 角度の差(-180〜180)
func angleDiff(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}

/// 案内する線(コース、または Apple の経路)と、その上の案内
struct NaviLine {
    struct Step {
        /// 線の最初からの距離(m)
        var at: Double
        var kind: String
        var angle: Double
        var text: String
        var road: String
    }
    let pts: [GeoPoint]
    /// 各点の、線の最初からの距離(m)
    let acc: [Double]
    let steps: [Step]
    /// 道の名前が変わる所(距離 m, 名前)
    let roads: [(at: Double, name: String)]
    /// 一般道の区間(距離 m)
    let free: [ClosedRange<Double>]
    let exp: [ClosedRange<Double>]

    var length: Double { acc.last ?? 0 }

    init(pts: [GeoPoint], steps: [Step], roads: [(at: Double, name: String)] = [], free: [ClosedRange<Double>] = [], exp: [ClosedRange<Double>] = []) {
        self.pts = pts
        var acc: [Double] = [0]
        for k in pts.indices.dropFirst() { acc.append(acc[k - 1] + geoDistance(pts[k - 1], pts[k])) }
        self.acc = acc
        self.steps = steps.sorted { $0.at < $1.at }
        self.roads = roads
        self.free = free
        self.exp = exp
    }

    /// 地図の案内のデータから作る。点が 2 つ未満なら nil
    init?(guide g: NaviGuideData) {
        var pts: [GeoPoint] = []
        var k = 0
        while k + 1 < g.pts.count {
            pts.append(GeoPoint(lat: g.pts[k], lon: g.pts[k + 1]))
            k += 2
        }
        guard pts.count >= 2 else { return nil }
        var acc: [Double] = [0]
        for j in pts.indices.dropFirst() { acc.append(acc[j - 1] + geoDistance(pts[j - 1], pts[j])) }
        let at = { (i: Int) -> Double in acc[max(0, min(acc.count - 1, i))] }
        let steps = g.man.map { Step(at: at($0.i), kind: $0.kind, angle: $0.angle, text: $0.text, road: $0.road) }
        let ranges = { (list: [[Int]]) -> [ClosedRange<Double>] in
            list.compactMap { r -> ClosedRange<Double>? in r.count == 2 && at(r[0]) <= at(r[1]) ? at(r[0])...at(r[1]) : nil }
        }
        self.init(pts: pts, steps: steps, roads: g.roads.map { (at: at($0.i), name: $0.name) }, free: ranges(g.free), exp: ranges(g.exp))
    }

    /// 線の最初から m の位置
    func point(at m: Double) -> GeoPoint {
        guard let last = pts.last else { return GeoPoint(lat: 0, lon: 0) }
        if m <= 0 { return pts[0] }
        if m >= length { return last }
        var lo = 0
        var hi = acc.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if acc[mid] <= m { lo = mid } else { hi = mid }
        }
        let t = (m - acc[lo]) / max(1e-9, acc[hi] - acc[lo])
        return GeoPoint(lat: pts[lo].lat + (pts[hi].lat - pts[lo].lat) * t, lon: pts[lo].lon + (pts[hi].lon - pts[lo].lon) * t)
    }

    /// m の所の道の名前
    func road(at m: Double) -> String {
        var name = ""
        for r in roads where r.at <= m + 1 { name = r.name }
        return name
    }

    func inFree(_ m: Double) -> ClosedRange<Double>? { free.first { $0.contains(m) } }

    struct Match {
        /// 線の最初からの距離(m)
        var at: Double
        /// 線からの距離(m)
        var off: Double
    }

    /// 位置に近い線上の点。near(前回の距離)があればその前後を先に探し、heading(進む向き)と逆向きの所は避ける
    func match(_ p: GeoPoint, heading: Double?, near: Double?) -> Match? {
        guard pts.count >= 2 else { return nil }
        let cosLat = cos(p.lat * .pi / 180)
        func search(_ range: Range<Int>) -> (Match, Double)? {
            var best: (Match, Double)?
            for k in range {
                let a = pts[k], b = pts[k + 1]
                let ax = (a.lon - p.lon) * 111_320 * cosLat, ay = (a.lat - p.lat) * 110_950
                let bx = (b.lon - p.lon) * 111_320 * cosLat, by = (b.lat - p.lat) * 110_950
                let dx = bx - ax, dy = by - ay
                let len2 = dx * dx + dy * dy
                let t = len2 < 1e-6 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / len2))
                let off = ((ax + t * dx) * (ax + t * dx) + (ay + t * dy) * (ay + t * dy)).squareRoot()
                var score = off
                if let h = heading, len2 > 1 {
                    let segBearing = atan2(dx, dy) * 180 / .pi
                    if abs(angleDiff(h, segBearing)) > 100 { score += 150 }
                }
                if best == nil || score < best!.1 {
                    best = (Match(at: acc[k] + t * (acc[k + 1] - acc[k]), off: off), score)
                }
            }
            return best
        }
        let segs = pts.count - 1
        if let n = near {
            var lo = 0
            // near の 300m 手前から 3km 先まで
            while lo < segs && acc[lo + 1] < n - 300 { lo += 1 }
            var hi = lo
            while hi < segs && acc[hi] <= n + 3000 { hi += 1 }
            if hi > lo, let r = search(lo..<hi), r.1 < 60 { return r.0 }
        }
        return search(0..<segs)?.0
    }
}

/// 読み上げの文に使う距離
enum NaviSpeech {
    static func distance(_ m: Double) -> String {
        if m >= 950 {
            let km = (m / 500).rounded() / 2
            return km == km.rounded() ? "\(Int(km))キロ" : String(format: "%.1fキロ", km)
        }
        let step: Double = m >= 300 ? 100 : 50
        return "\(Int(max(step, (m / step).rounded() * step)))メートル"
    }

    /// 画面に出す距離
    static func label(_ m: Double) -> String {
        if m >= 1000 { return String(format: m >= 10_000 ? "%.0f km" : "%.1f km", m / 1000) }
        return "\(Int((m / 10).rounded() * 10)) m"
    }
}

/// 線に沿った案内。位置を渡すたびに、読み上げる文を返す
final class NaviEngine {
    let line: NaviLine
    /// Apple の経路(コースに戻る道)のときは true。外れたとき・道なりの読み上げをしない
    let isDetour: Bool

    /// いまの位置(線の最初からの距離 m)。まだわからなければ nil
    private(set) var progress: Double?
    /// 線から離れている距離(m)
    private(set) var offDistance: Double = 0
    /// コースから外れているか
    private(set) var offRoute = false
    /// 目的地に着いた
    private(set) var arrived = false
    /// 次の案内(steps の添字)
    private(set) var nextIndex = 0

    /// 案内ごとに読み上げた段階(0 = まだ、1 = 遠く、2 = 近く、3 = まもなく)
    private var said: [Int]
    /// 「道なり」を言った案内
    private var cruiseSaid = Set<Int>()
    private var offSince: Double?
    private var onSince: Double?
    private var lastFix: Double?
    private var lastSpeed: Double = 0
    private var lastProgressAtFix: Double = 0

    init(line: NaviLine, isDetour: Bool = false) {
        self.line = line
        self.isDetour = isDetour
        said = Array(repeating: 0, count: line.steps.count)
    }

    var nextStep: NaviLine.Step? { nextIndex < line.steps.count ? line.steps[nextIndex] : nil }
    var distanceToNext: Double? {
        guard let p = progress, let s = nextStep else { return nil }
        return max(0, s.at - p)
    }
    var remaining: Double? { progress.map { max(0, line.length - $0) } }
    var currentRoad: String { progress.map { line.road(at: $0) } ?? "" }
    var inFree: Bool { progress.flatMap { line.inFree($0) } != nil }

    /// 案内を始めるときの文
    func startText() -> String {
        guard let s = line.steps.first(where: { $0.kind != "arrive" }) ?? line.steps.first else { return "" }
        let d = max(0, s.at - (progress ?? 0))
        if s.kind == "arrive" { return "目的地まで\(NaviSpeech.distance(d))です" }
        return "最初の案内は\(NaviSpeech.distance(d))先、\(s.text)です"
    }

    /// 位置が来たとき。speed は m/s(わからなければ負)、heading は進む向き(度、わからなければ nil)、hAcc は位置の誤差(m)、time は秒
    func update(_ p: GeoPoint, speed: Double, heading: Double?, hAcc: Double, time: Double) -> [String] {
        var out: [String] = []
        let h = speed > 2 ? heading : nil
        guard let m = line.match(p, heading: h, near: progress) else { return out }
        offDistance = m.off
        let free = line.inFree(m.at) != nil
        // 外れたか: 誤差を見込んで 45m より離れた状態が 5 秒続いたら(一般道の区間は直線なので見ない)
        let offLimit = max(45, min(hAcc, 60) * 1.5)
        if !isDetour {
            if m.off > offLimit && !free && speed > 1 {
                onSince = nil
                if offSince == nil { offSince = time }
                if !offRoute, let s = offSince, time - s >= 5 {
                    offRoute = true
                    out.append("コースから外れました")
                }
            } else if m.off < 30 + min(hAcc, 30) {
                offSince = nil
                if onSince == nil { onSince = time }
                if offRoute, let s = onSince, time - s >= 3 {
                    offRoute = false
                    out.append("コースに戻りました")
                }
            }
        }
        // 外れているあいだは位置を進めない(戻ったところから続ける)。ただし大きく先へ進んだ所で戻ったときはそこから
        if offRoute { return out }
        progress = m.at
        lastFix = time
        lastSpeed = max(0, speed)
        lastProgressAtFix = m.at
        out += announce(speed: max(0, speed))
        return out
    }

    /// 1 秒ごとに呼ぶ。トンネルなどで位置が来ないあいだは、最後の速さで進んだとみなして案内を続ける(最大 5km)
    func tick(time: Double) -> [String] {
        guard !offRoute, !arrived, let f = lastFix, time - f > 3, lastSpeed > 5 else { return [] }
        let p = lastProgressAtFix + min(5000, lastSpeed * (time - f))
        if p <= (progress ?? 0) { return [] }
        progress = min(p, line.length)
        return announce(speed: lastSpeed)
    }

    /// 次の案内までの距離に応じて読み上げる
    private func announce(speed v: Double) -> [String] {
        guard let p = progress, !arrived else { return [] }
        var out: [String] = []
        // 通り過ぎた案内を飛ばす
        while nextIndex < line.steps.count && line.steps[nextIndex].at < p - 15 && line.steps[nextIndex].kind != "arrive" {
            nextIndex += 1
        }
        guard nextIndex < line.steps.count else { return out }
        let s = line.steps[nextIndex]
        let d = s.at - p
        if s.kind == "arrive" && d < 25 {
            arrived = true
            out.append(isDetour ? "" : "目的地に到着しました。案内を終わります")
            return out.filter { !$0.isEmpty }
        }
        // 前の案内を過ぎてしばらく何もなければ「道なり」
        if !isDetour, nextIndex > 0, !cruiseSaid.contains(nextIndex), d > 5000, p - line.steps[nextIndex - 1].at > 30 {
            cruiseSaid.insert(nextIndex)
            out.append("しばらく道なりです。次の案内は\(NaviSpeech.distance(d))先です")
        }
        let near = max(40, v * 7)
        let mid: Double = v >= 11 ? 300 : 150
        let far: Double = v >= 16.7 ? 2000 : v >= 11 ? 1000 : 500
        var stage = 0
        if d <= near { stage = 3 } else if d <= mid { stage = 2 } else if d <= far && d > mid + v * 8 { stage = 1 }
        guard stage > said[nextIndex] else { return out }
        said[nextIndex] = stage
        var text: String
        if s.kind == "arrive" {
            text = stage == 3 ? "まもなく目的地です" : "\(NaviSpeech.distance(d))先、目的地です"
        } else {
            text = (stage == 3 ? "まもなく、" : "\(NaviSpeech.distance(d))先、") + s.text
            // すぐ次の案内(200m 以内)もまとめて言う
            if nextIndex + 1 < line.steps.count {
                let n = line.steps[nextIndex + 1]
                if n.at - s.at < 200 {
                    text += n.kind == "arrive" ? "。その先、目的地です" : "。その先、\(n.text)"
                    said[nextIndex + 1] = max(said[nextIndex + 1], 2)
                }
            }
        }
        out.append(text)
        return out
    }
}
