// 振り返り画面のデータ(ReviewData.swift)が、サンプルの走行から作れるかを確かめる(CI の macOS で動かす)
//   swiftc -O DriveLogger/Sources/DriveEval.swift DriveLogger/Sources/ReviewData.swift tools/reviewcheck/main.swift -o reviewcheck
//   ./reviewcheck tools/evalcheck/fixture
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    print("使い方: reviewcheck <走行フォルダ>")
    exit(2)
}
let folder = URL(fileURLWithPath: args[1])
var failed = false
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "OK" : "NG") \(label): \(detail)")
    if !ok { failed = true }
}

let car = try ReviewLoader.load(folder: folder, motion: true)
let s = car.samples
check("点の数", s.count >= 2 && s.count <= ReviewData.maxSamples + 1, "\(s.count)")
check("時刻が増えていく", zip(s, s.dropFirst()).allSatisfy { $0.t < $1.t }, "\(s.first?.t ?? -1)〜\(s.last?.t ?? -1) 秒")
check("距離が増えていく", zip(s, s.dropFirst()).allSatisfy { $0.km <= $1.km }, String(format: "%.2f km", s.last?.km ?? 0))
check("前後G・横G・躍度がある", car.hasMotion && s.allSatisfy { $0.lonG != nil && $0.latG != nil && $0.jerk != nil }, "\(car.hasMotion)")
let maxKmh = s.map(\.kmh).max() ?? 0
check("速度", maxKmh > 5 && maxKmh < 250, String(format: "最高 %.0f km/h", maxKmh))
let maxG = s.compactMap { $0.lonG.map(abs) }.max() ?? 0
check("前後G", maxG > 0.01 && maxG < 2, String(format: "最大 %.2f G", maxG))
check("時刻から点を探す", car.index(atT: s[s.count / 2].t) == s.count / 2, "\(s.count / 2)")
check("距離から点を探す", car.index(atKm: 1e9) == s.count - 1 && car.index(atKm: -1) == 0, "端")

let trip = try ReviewLoader.load(folder: folder, motion: false)
check("車以外は加速度を使わない", !trip.hasMotion && trip.samples.allSatisfy { $0.lonG == nil }, "\(trip.samples.count) 点")

// 飛行機: 機内は与圧されていて、GPS で 10,000 m 上っても気圧の高度は 2,000 m ほどしか変わらない
let cabin = (0..<100).map { Double($0) * 20 }      // 0〜1,980 m
let gpsPlane = (0..<100).map { Double($0) * 120 }  // 0〜11,880 m
check("与圧された機内の気圧は使わない", !ReviewLoader.pressureMatchesGPS(pressure: cabin, gps: gpsPlane), "気圧 2,000 m / GPS 12,000 m")
let road = (0..<100).map { Double($0) * 8 }
check("車の坂道の気圧は使う", ReviewLoader.pressureMatchesGPS(pressure: road, gps: road.map { $0 + 15 }), "800 m")
check("平地(GPS の揺れだけ)の気圧は使う", ReviewLoader.pressureMatchesGPS(pressure: [0, 1, 2], gps: [30, 80, 10]), "変化 70 m")

// トンネルを補った location_filled.csv: 途中の 60 秒を「補った点」(精度・GPS の速度が空、推定の速度あり)にしても読める
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reviewcheck-filled-\(getpid())")
try? FileManager.default.removeItem(at: tmp)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for name in ["location.csv", "motion.csv"] {
    try FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: tmp.appendingPathComponent(name))
}
let locText = try String(contentsOf: folder.appendingPathComponent("location.csv"), encoding: .utf8)
var locLines = locText.split(whereSeparator: \.isNewline).map(String.init)
let head = locLines.removeFirst().split(separator: ",", omittingEmptySubsequences: false).map(String.init)
let ci = { (n: String) in head.firstIndex(of: n)! }
let t0 = Double(locLines[0].split(separator: ",", omittingEmptySubsequences: false)[ci("unix_s")])!
var filledLines = [(head + (head.contains("speed_est_ms") ? [] : ["speed_est_ms"]) + ["src"]).joined(separator: ",")]
var roadRows = 0
for line in locLines {
    var f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    while f.count < head.count { f.append("") }
    var est = ""
    var src = "gps"
    let t = Double(f[ci("unix_s")]) ?? 0
    if t - t0 > 60 && t - t0 <= 120 {
        est = f[ci("speed_ms")]
        f[ci("h_acc_m")] = ""
        f[ci("speed_ms")] = ""
        src = "road"
        roadRows += 1
    }
    if !head.contains("speed_est_ms") { f.append(est) } else { f[ci("speed_est_ms")] = est }
    f.append(src)
    filledLines.append(f.joined(separator: ","))
}
try (filledLines.joined(separator: "\n") + "\n").write(to: tmp.appendingPathComponent(ReviewLoader.filledFile), atomically: true, encoding: .utf8)
let filled = try ReviewLoader.load(folder: tmp, motion: true)
let fs = filled.samples
check("補った点を含めて読める", roadRows > 30 && fs.count >= 2 && abs((fs.last?.km ?? 0) - (s.last?.km ?? 0)) < max(0.05, (s.last?.km ?? 0) * 0.05),
      String(format: "補った点 %d / %.2f km(元 %.2f km)", roadRows, fs.last?.km ?? 0, s.last?.km ?? 0))
let filledKmh = fs.filter { $0.unix - t0 > 70 && $0.unix - t0 < 110 }.map(\.kmh).max() ?? 0
let origKmh = s.filter { $0.unix - t0 > 70 && $0.unix - t0 < 110 }.map(\.kmh).max() ?? 0
check("補った区間の速度は推定の速度", abs(filledKmh - origKmh) < 1, String(format: "%.1f km/h(元 %.1f km/h)", filledKmh, origKmh))
try? FileManager.default.removeItem(at: tmp)

exit(failed ? 1 : 0)
