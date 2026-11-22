// 運転評価の Swift 版が、gbowl-log-formatter の Python 版と同じ結果になるかを確かめる(CI の macOS で動かす)
//   swiftc -O DriveLogger/Sources/DriveEval.swift DriveLogger/Sources/SegmentEval.swift DriveLogger/Sources/HandheldEval.swift DriveLogger/Sources/LiveCoach.swift tools/evalcheck/main.swift -o evalcheck
//   ./evalcheck tools/evalcheck/fixture tools/evalcheck/expected.json
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    print("使い方: evalcheck <走行フォルダ> <expected.json>")
    exit(2)
}
let got = try DriveEval.evaluate(folder: URL(fileURLWithPath: args[1]))
let want = try JSONDecoder().decode(Evaluation.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))

var failed = false
func check(_ label: String, _ a: Double, _ b: Double, _ tol: Double) {
    let ok = abs(a - b) <= tol
    print("\(ok ? "OK" : "NG") \(label): Swift \(a) / Python \(b)")
    if !ok { failed = true }
}
check("総合点", got.score, want.score, 0.2)
check("走行時間", got.movingS, want.movingS, 0.2)
check("停止の回数", Double(got.stops), Double(want.stops), 0)
for (g, w) in zip(got.items, want.items) {
    check("\(w.name) の値", g.value, w.value, max(0.002, abs(w.value) * 0.005))
    check("\(w.name) の点数", g.score, w.score, 0.3)
}
check("出来事の件数", Double(got.events.count), Double(want.events.count), 0)
for (g, w) in zip(got.events, want.events) {
    let ok = g.kind == w.kind && abs(g.tUnix - w.tUnix) <= 0.11 && abs(g.value - w.value) <= 0.005
    print("\(ok ? "OK" : "NG") 出来事: Swift \(g.kind) \(g.value) @\(g.tUnix) / Python \(w.kind) \(w.value) @\(w.tUnix)")
    if !ok { failed = true }
}

// 区間ごとの採点(SegmentEval.swift と drive_eval.py の segments)
let gs = got.segments ?? [], ws = want.segments ?? []
check("区間の数", Double(gs.count), Double(ws.count), 0)
for (g, w) in zip(gs, ws) {
    // 停止の判定は Swift と Python で 0.1〜0.2 秒ずれることがある(前からの差。止まり際の値は同じ)ので、時刻は 0.3 秒まで許す
    var ok = g.name == w.name && abs(g.startUnix - w.startUnix) <= 0.31 && abs(g.endUnix - w.endUnix) <= 0.31 &&
        abs(g.score - w.score) <= 0.3 && g.items.count == w.items.count
    for (a, b) in zip(g.items, w.items) where abs(a.value - b.value) > max(0.002, abs(b.value) * 0.005) { ok = false }
    print("\(ok ? "OK" : "NG") 区間: Swift \(g.name) \(g.score) @\(g.endUnix) / Python \(w.name) \(w.score) @\(w.endUnix)")
    if !ok { failed = true }
}
for key in ["curve", "stop", "start"] {
    let a = got.segmentStats?[key], b = want.segmentStats?[key]
    check("区間の平均(\(key))", a?.score ?? -1, b?.score ?? -1, 0.3)
}

// 記録中のサポート(LiveCoach)に同じ走行を流し、向きが分かることと、急な操作を知らせることを確かめる
let folder = URL(fileURLWithPath: args[1])
let locs = try DriveEval.loadLocations(folder.appendingPathComponent("location.csv"))
let mot = try DriveEval.loadMotion(folder.appendingPathComponent("motion.csv"))
let coach = LiveCoach()
var fired: [(CoachEvent, Double)] = []
var now = 0.0
var readyAt: Double?
coach.onEvent = { fired.append(($0, now)) }
var liveSegs: [EvalSegment] = []
coach.onSegment = { liveSegs.append($0) }
var li = 0
for m in mot {
    while li < locs.count && locs[li].t <= m.t {
        let l = locs[li]
        coach.addLocation(t: l.t, lat: l.la, lon: l.lo, speed: l.sp, accuracy: 5)
        li += 1
    }
    now = m.t
    coach.addMotion(t: m.t, a: m.a, g: m.g, r: m.r)
    if readyAt == nil && coach.state.ready { readyAt = m.t }
}
let t0 = mot[0].t
if let readyAt {
    print("OK 記録中: 向きが分かった時刻 +\(String(format: "%.1f", readyAt - t0)) 秒")
} else {
    print("NG 記録中: 向きが分からないまま終わった")
    failed = true
}
for (e, t) in fired { print("   記録中に知らせた: \(e.rawValue) +\(String(format: "%.1f", t - t0)) 秒") }
// 向きが分かったあとの出来事は、同じ種類を 2 秒以内(ならしの遅れを含む)に知らせていること
for w in want.events where w.tUnix > (readyAt ?? .infinity) && w.kind != "カックン" {
    let ok = fired.contains { $0.0.rawValue == w.kind && abs($0.1 - w.tUnix) <= 2 }
    print("\(ok ? "OK" : "NG") 記録中: \(w.kind) +\(String(format: "%.1f", w.tUnix - t0)) 秒を知らせた")
    if !ok { failed = true }
}
// 区間ごとの採点: 記録中にも、走り終えたあとと同じ区間を出していること(向きが分かったあとに終わったもの)
for s in liveSegs { print("   記録中に出した区間: \(s.name) \(s.score) 点 +\(String(format: "%.1f", s.endUnix - t0)) 秒") }
for w in ws where w.startUnix > (readyAt ?? .infinity) + 2 {
    let ok = liveSegs.contains { $0.group == w.group && abs($0.endUnix - w.endUnix) <= 1.5 }
    print("\(ok ? "OK" : "NG") 記録中: \(w.name) +\(String(format: "%.1f", w.endUnix - t0)) 秒を出した")
    if !ok { failed = true }
}
if let s = coach.state.recentScore {
    print("   記録中: 直近 5 分の点数 \(s)(走り終えたあとの点数 \(got.score))")
}
exit(failed ? 1 : 0)
