// 同乗の運転評価(手持ち・固定の見分けと、手持ちの方法 HandheldEval.swift)を確かめる(CI の macOS で動かす)
//   python3 tools/handcheck/make_fixture.py /tmp/handfixture
//   swiftc -O DriveLogger/Sources/DriveEval.swift DriveLogger/Sources/HandheldEval.swift tools/handcheck/main.swift -o handcheck
//   ./handcheck /tmp/handfixture tools/evalcheck/fixture
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    print("使い方: handcheck <手持ちの走行フォルダ> <固定の走行フォルダ>")
    exit(2)
}
let handDir = URL(fileURLWithPath: args[1])
let fixedDir = URL(fileURLWithPath: args[2])
var failed = false
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "OK" : "NG") \(label): \(detail)")
    if !ok { failed = true }
}

// 1. 固定の走行は、同乗として評価しても車と同じ結果(固定とみなす)
let car = try DriveEval.evaluate(folder: fixedDir)
let fixedRide = try DriveEval.evaluate(folder: fixedDir, allowHandheld: true)
check("固定の走行は固定とみなす", fixedRide.mount == "fixed", fixedRide.mount ?? "nil")
check("固定なら車と同じ点数", fixedRide.score == car.score && fixedRide.events.count == car.events.count,
      "同乗 \(fixedRide.score) / 車 \(car.score)")
check("車の評価には持ち方を書かない", car.mount == nil && car.usableRatio == nil, "\(car.mount ?? "nil")")

// 2. 手持ちの走行は手持ちとみなし、車の前後・左右の G を取り戻せる
let locs = try DriveEval.loadLocations(handDir.appendingPathComponent("location.csv"))
let mot = try DriveEval.loadMotion(handDir.appendingPathComponent("motion.csv"))
check("姿勢を読める", mot.allSatisfy { $0.q != nil }, "\(mot.count) 行")
check("手持ちは重力の向きが変わる", !DriveEval.gravitySteady(mot), "")
let p = try DriveEval.prepare(locs: locs, gpsLocs: locs, mot: mot, allowHandheld: true)
check("手持ちとみなす", p.mount == "hand", p.mount ?? "nil")
check("向き合わせの確かさ", p.quality > 0.9, String(format: "%.3f", p.quality))
check("採点に使える割合", (p.usable ?? 0) > 0.8 && (p.usable ?? 0) < 1, String(format: "%.3f", p.usable ?? -1))

let truth = try DriveEval.readCSV(handDir.appendingPathComponent("truth.csv"), columns: ["unix_s", "lon_g", "lat_g", "hand"])
let tt = truth.map { $0[0]! }
func truthAt(_ t: Double) -> (lon: Double, lat: Double, hand: Int) {
    let k = min(truth.count - 1, DriveEval.bisectLeft(tt, t))
    return (truth[k][1]!, truth[k][2]!, Int(truth[k][3]!))
}
let w = 5
let slon = DriveEval.smooth(p.rows.map { -$0.ry }, w), slat = DriveEval.smooth(p.rows.map { $0.rx }, w)
let tr = p.rows.indices.map { truthAt(p.t0 + Double($0) / Double(DriveEval.HZ)) }
let tlon = DriveEval.smooth(tr.map { $0.lon }, w), tlat = DriveEval.smooth(tr.map { $0.lat }, w)
var se = 0.0, cnt = 0, worst = 0.0
for i in p.rows.indices where p.rows[i].valid && p.rows[i].kmh > DriveEval.movingKmh {
    let d = ((slon[i] - tlon[i]) * (slon[i] - tlon[i]) + (slat[i] - tlat[i]) * (slat[i] - tlat[i])).squareRoot()
    se += d * d
    cnt += 1
    worst = max(worst, d)
}
let rms = cnt > 0 ? (se / Double(cnt)).squareRoot() : 1
check("前後・左右の G の誤差(1 秒平均)", rms < 0.02 && worst < 0.08, String(format: "平均 %.4f G・最大 %.3f G(%d 行)", rms, worst, cnt))
let regrip = tr.indices.filter { tr[$0].hand == 1 }
let caught = regrip.filter { !p.rows[$0].valid }.count
check("持ち替えた区間は採点から外す", caught == regrip.count, "\(caught) / \(regrip.count) 行")

// 3. 手持ちの点数と出来事は、同じ走り方を固定で記録したものに近い
let hand = try DriveEval.evaluate(folder: handDir, allowHandheld: true)
check("手持ちの評価に持ち方と割合を書く", hand.mount == "hand" && hand.usableRatio != nil,
      "\(hand.mount ?? "nil") \(hand.usableRatio ?? -1)")
check("総合点が固定と近い", abs(hand.score - car.score) <= 10, "手持ち \(hand.score) / 固定 \(car.score)")
for (h, c) in zip(hand.items, car.items) {
    print("   \(c.name): 手持ち \(h.value)(\(h.score) 点)/ 固定 \(c.value)(\(c.score) 点)")
}
for kind in ["急ブレーキ", "急ハンドル"] {
    let hs = hand.events.filter { $0.kind == kind }.map(\.tUnix)
    let cs = car.events.filter { $0.kind == kind }.map(\.tUnix)
    // 固定でいちばん強かった出来事を、手持ちでも見つけられること。
    // しきい値すれすれの弱い出来事は、手の揺れの分だけ出たり出なかったりするので比べない
    let strongest = car.events.filter { $0.kind == kind }.max { $0.value < $1.value }?.tUnix
    let ok = strongest.map { c in hs.contains { abs($0 - c) <= 1.5 } } ?? false
    check("\(kind)を見つける", ok, "手持ち \(hs) / 固定 \(cs)")
}
print("   手持ちの出来事: " + hand.events.map { "\($0.kind) \($0.value)" }.joined(separator: "、"))

// 4. 姿勢の記録が無い古い走行で、固定でもなければ評価できない(固定とみなせるなら固定で評価する)
let noQ = mot.map { m -> DriveEval.Mot in var m = m; m.q = nil; return m }
let r = Result { try DriveEval.prepare(locs: locs, gpsLocs: locs, mot: noQ, allowHandheld: true) }
switch r {
case .success(let q): check("姿勢が無いときは固定として評価する", q.mount == "fixed", q.mount ?? "nil")
case .failure(let e): check("姿勢が無く固定でもなければ評価しない", true, e.localizedDescription)
}
exit(failed ? 1 : 0)
