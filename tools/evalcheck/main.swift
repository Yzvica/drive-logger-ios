// 運転評価の Swift 版が、gbowl-log-formatter の Python 版と同じ結果になるかを確かめる(CI の macOS で動かす)
//   swiftc -O DriveLogger/Sources/DriveEval.swift tools/evalcheck/main.swift -o evalcheck
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
exit(failed ? 1 : 0)
