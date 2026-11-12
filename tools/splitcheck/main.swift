// 記録を分ける処理(LogSplit.swift)を、サンプルの走行で確かめる(CI の macOS で動かす)
//   swiftc -O DriveLogger/Sources/FileWriters.swift DriveLogger/Sources/LogSplit.swift tools/splitcheck/main.swift -o splitcheck
//   ./splitcheck tools/evalcheck/fixture
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    print("使い方: splitcheck <走行フォルダ>")
    exit(2)
}
var failed = false
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "OK" : "NG") \(label): \(detail)")
    if !ok { failed = true }
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("splitcheck-\(UUID().uuidString)", isDirectory: true)
let a = work.appendingPathComponent("a", isDirectory: true)
let b = work.appendingPathComponent("b", isDirectory: true)
try fm.createDirectory(at: work, withIntermediateDirectories: true)
try fm.copyItem(at: URL(fileURLWithPath: args[1]), to: a)
// 消えるべきファイルと、両方に写すファイル
try "{}".write(to: a.appendingPathComponent("evaluation.json"), atomically: true, encoding: .utf8)
try "{\"v\":\"x\"}\n".write(to: a.appendingPathComponent("rain_radar.jsonl"), atomically: true, encoding: .utf8)

func rows(_ url: URL) -> [String] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}
func times(_ url: URL) -> [Double] {
    rows(url).dropFirst().compactMap { Double($0.split(separator: ",", maxSplits: 1).first ?? "") }
}

let loc0 = rows(a.appendingPathComponent("location.csv"))
let mot0 = rows(a.appendingPathComponent("motion.csv"))
let whole = try LogSplit.rebuildTrack(location: a.appendingPathComponent("location.csv"), gpx: work.appendingPathComponent("whole.gpx"), name: "whole")
let lt = times(a.appendingPathComponent("location.csv"))
let at = lt[lt.count / 2]

// 端すぎる位置では分けない
do {
    _ = try LogSplit.split(from: a, to: work.appendingPathComponent("x"), at: lt[1], fromName: "a", toName: "x")
    check("端すぎると分けない", false, "分けてしまった")
} catch {
    check("端すぎると分けない", !fm.fileExists(atPath: work.appendingPathComponent("x/location.csv").path)
        && rows(a.appendingPathComponent("location.csv")).count == loc0.count, error.localizedDescription)
}

let (sa, sb) = try LogSplit.split(from: a, to: b, at: at, fromName: "a", toName: "b")
for name in ["location.csv", "motion.csv"] {
    let ra = rows(a.appendingPathComponent(name)), rb = rows(b.appendingPathComponent(name))
    let all = name == "location.csv" ? loc0 : mot0
    check("\(name) のヘッダー", ra.first == all.first && rb.first == all.first, ra.first ?? "")
    check("\(name) の行数", ra.count - 1 + rb.count - 1 == all.count - 1, "\(ra.count - 1) + \(rb.count - 1) = \(all.count - 1)")
    let ta = times(a.appendingPathComponent(name)), tb = times(b.appendingPathComponent(name))
    check("\(name) の時刻", (ta.max() ?? 0) < at && (tb.min() ?? 0) >= at && !ta.isEmpty && !tb.isEmpty, "\(ta.last ?? 0) < \(at) <= \(tb.first ?? 0)")
}
check("点の数", sa.points + sb.points == whole.points && sa.points > 0 && sb.points > 0, "\(sa.points) + \(sb.points) = \(whole.points)")
// 分けた所の1区間ぶんだけ短くなる
let gap = whole.distanceM - sa.distanceM - sb.distanceM
check("距離", gap >= 0 && gap < 100, String(format: "%.0f + %.0f m(全体 %.0f m)", sa.distanceM, sb.distanceM, whole.distanceM))
check("時刻の範囲", sa.firstUnix == whole.firstUnix && sb.lastUnix == whole.lastUnix && (sa.lastUnix ?? 0) < at, "\(sa.firstUnix ?? 0)〜\(sb.lastUnix ?? 0)")
let gpxA = (try? String(contentsOf: a.appendingPathComponent("track.gpx"), encoding: .utf8)) ?? ""
check("GPX を作り直す", gpxA.components(separatedBy: "<trkpt ").count - 1 == sa.points && gpxA.hasSuffix("</gpx>\n"), "\(sa.points) 点")
check("評価は消す", !fm.fileExists(atPath: a.appendingPathComponent("evaluation.json").path), "evaluation.json")
check("雨雲は両方に写す", fm.fileExists(atPath: a.appendingPathComponent("rain_radar.jsonl").path)
    && fm.fileExists(atPath: b.appendingPathComponent("rain_radar.jsonl").path), "rain_radar.jsonl")

try? fm.removeItem(at: work)
exit(failed ? 1 : 0)
