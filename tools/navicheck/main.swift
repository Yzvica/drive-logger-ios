// ナビの計算(NaviCore.swift)を、地図が作った本物の案内のデータで走行をまねて確かめる(CI の macOS で動かす)
//   swiftc -O DriveLogger/Sources/NaviCore.swift tools/navicheck/main.swift -o navicheck
//   ./navicheck tools/navicheck
// exp.json / free.json は national-route-conquest-map の src/naviGuide.ts で作った香嵐渓→用賀(高速も使う/下道のみ)
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    print("使い方: navicheck <exp.json と free.json のあるフォルダ>")
    exit(2)
}
var failed = false
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "OK" : "NG") \(label): \(detail)")
    if !ok { failed = true }
}

check("距離 1.5km", NaviSpeech.distance(1500) == "1.5キロ", NaviSpeech.distance(1500))
check("距離 2km", NaviSpeech.distance(2000) == "2キロ", NaviSpeech.distance(2000))
check("距離 300m", NaviSpeech.distance(310) == "300メートル", NaviSpeech.distance(310))
check("距離 120m", NaviSpeech.distance(120) == "100メートル", NaviSpeech.distance(120))
check("角度の差", angleDiff(10, 350) == 20 && angleDiff(350, 10) == -20, "\(angleDiff(10, 350))")

/// 線から右へ side m ずらした点
func offset(_ line: NaviLine, _ m: Double, _ side: Double) -> GeoPoint {
    let a = line.point(at: max(0, m - 5)), b = line.point(at: min(line.length, m + 5))
    let p = line.point(at: m)
    let br = geoBearing(a, b) * .pi / 180
    // 右向き = 方位 + 90 度
    let dx = side * cos(br), dy = -side * sin(br)
    return GeoPoint(lat: p.lat + dy / 110_950, lon: p.lon + dx / (111_320 * cos(p.lat * .pi / 180)))
}

struct Drive {
    var said: [(Double, String)] = []
    var engine: NaviEngine
}

/// 線を速さ v m/s で走る。noGps の区間(距離 m)は位置を渡さない。detour は (始め, 終わり, ずらす m)
func drive(_ line: NaviLine, v: Double, noGps: ClosedRange<Double>? = nil, detour: (Double, Double, Double)? = nil) -> Drive {
    let e = NaviEngine(line: line)
    var d = Drive(engine: e)
    var t = 0.0
    var seed: UInt64 = 42
    func noise() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 33) / Double(1 << 31) * 10 - 5
    }
    var m = 0.0
    while m <= line.length + 50 && !e.arrived {
        let at = min(m, line.length)
        var side = noise()
        if let dt = detour, at >= dt.0 && at <= dt.1 { side = dt.2 }
        let p = offset(line, at, side)
        let br = geoBearing(line.point(at: max(0, at - 10)), line.point(at: min(line.length, at + 10)))
        var out: [String]
        if let ng = noGps, ng.contains(at) {
            out = e.tick(time: t)
        } else {
            out = e.update(p, speed: v, heading: br, hAcc: 8, time: t)
        }
        for s in out { d.said.append((at, s)) }
        t += 1
        m += v
    }
    return d
}

for name in ["exp", "free"] {
    let url = URL(fileURLWithPath: args[1]).appendingPathComponent("\(name).json")
    guard let data = try? Data(contentsOf: url), let g = try? JSONDecoder().decode(NaviGuideData.self, from: data), let line = NaviLine(guide: g) else {
        check("\(name) 読み込み", false, url.path)
        continue
    }
    check("\(name) 長さ", abs(line.length - g.length) < g.length * 0.01, "\(Int(line.length)) m / 地図 \(Int(g.length)) m")
    let r = drive(line, v: 20)
    check("\(name) 到着", r.engine.arrived, r.said.last?.1 ?? "なし")
    check("\(name) 外れない", !r.said.contains { $0.1.contains("外れ") }, "\(r.said.count) 回読み上げ")
    // どの案内も手前で読み上げる(まとめて言ったものを含む)
    let all = r.said.map { $0.1 }.joined(separator: "\n")
    let missed = line.steps.filter { $0.kind != "arrive" && !all.contains($0.text) }
    check("\(name) 全部の案内を読む", missed.isEmpty, missed.map(\.text).joined(separator: " / "))
    for s in r.said.prefix(8) { print("   \(Int(s.0)) m: \(s.1)") }

    // 途中でコースから 150m 外れて戻る
    let mid = line.length / 2
    let off = drive(line, v: 15, detour: (mid, mid + 600, 150))
    let iOff = off.said.firstIndex { $0.1 == "コースから外れました" }
    let iOn = off.said.firstIndex { $0.1 == "コースに戻りました" }
    check("\(name) 外れて戻る", iOff != nil && iOn != nil && iOff! < iOn! && off.engine.arrived, "\(iOff.map { Int(off.said[$0].0) } ?? -1) m → \(iOn.map { Int(off.said[$0].0) } ?? -1) m")

    // トンネル(位置が来ない 3km)の中の案内も、速さから進んだ距離で読む
    if let s = line.steps.first(where: { $0.at > 20_000 && $0.kind != "arrive" }) {
        let tun = drive(line, v: 20, noGps: (s.at - 2500)...(s.at + 500))
        let got = tun.said.first { $0.1.contains("まもなく") && $0.1.contains(s.text) }
        check("\(name) トンネル", got != nil && abs(got!.0 - s.at) < 300, "\(s.text) を \(got.map { Int($0.0) } ?? -1) m で(案内は \(Int(s.at)) m)")
    }
}
exit(failed ? 1 : 0)
