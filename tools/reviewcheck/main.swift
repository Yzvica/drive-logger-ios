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

exit(failed ? 1 : 0)
