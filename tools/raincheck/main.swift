// 気象庁の雨雲レーダーのタイルを RainRadar.swift で読めるかを確かめる(CI の macOS で動かす)
//   swiftc -O DriveLogger/Sources/RainRadar.swift DriveLogger/Sources/Amedas.swift tools/raincheck/main.swift -o raincheck
//   ./raincheck tools/raincheck
// rain_10_893_415.png は 2026-11-12 12:45 UTC の実際のタイル(z/x/y = 10/893/415)。
// 正解は PC 側の fetch_rain_radar.js(decodePngToIntensities)で同じタイルを読んだ結果。
// empty.png は降水の無いタイルと同じ形(全面が透明な RGBA)
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    print("使い方: raincheck <タイルのあるフォルダ>")
    exit(2)
}
var failed = false
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "OK" : "NG") \(label): \(detail)")
    if !ok { failed = true }
}

let dir = URL(fileURLWithPath: args[1])
guard let rain = try? Data(contentsOf: dir.appendingPathComponent("rain_10_893_415.png")),
      let empty = try? Data(contentsOf: dir.appendingPathComponent("empty.png")) else {
    print("NG タイルを読めません")
    exit(1)
}

// 1. 降水のあるタイル(4bit パレット)
if let grid = RainRadar.intensities(png: rain) {
    var counts = [Int](repeating: 0, count: 9)
    for v in grid { counts[Int(v)] += 1 }
    check("強度ごとの画素数", counts == [59079, 903, 1447, 594, 1121, 459, 759, 464, 710], "\(counts)")
    let row7 = grid[(7 * 256)..<(7 * 256 + 80)].map { String($0) }.joined()
    check("7行目(上から。向きが合っているか)",
          row7 == "00000000000011111111122222222244444444477777777788888888888888888888888888888777", row7)
    check("角と中央", grid[0] == 0 && grid[128 * 256 + 128] == 0 && grid[255 * 256 + 255] == 0, "0 0 0")
    check("最大の強度", grid[7 * 256 + 48] == 8 && grid[48] == 6, "(48,7)=\(grid[7 * 256 + 48]) (48,0)=\(grid[48])")
    check("降水ありと判定", !RainRadar.isEmptyTile(rain), "isEmptyTile = false")

    // 位置 → 強度: タイル 893_415 の画素 (48,7) の中心
    let n = pow(2.0, 10.0)
    let fx = 893 + 48.5 / 256, fy = 415 + 7.5 / 256
    let lon = fx / n * 360 - 180
    let lat = atan(sinh(Double.pi * (1 - 2 * fy / n))) * 180 / Double.pi
    let tile = RainRadar.tile(lat: lat, lon: lon)
    check("位置からタイル", tile == RainRadar.Tile(x: 893, y: 415), tile.key)
    let level = RainRadar.level(lat: lat, lon: lon, tile: tile, intensities: grid)
    check("位置の強度", level == 8, "\(String(describing: level)) \(RainRadar.label(level ?? -1))")
} else {
    check("降水のあるタイルを読む", false, "読めません")
}

// 2. 降水の無いタイル(全面が透明な RGBA)
check("降水なしと判定", RainRadar.isEmptyTile(empty), "isEmptyTile = true")
check("壊れたデータ", RainRadar.intensities(png: Data([1, 2, 3])) == nil, "nil")

// 3. 取るタイル: 位置の周り約5.5km が core、その周り1タイルが all
let plan = RainRadar.tiles(for: [(lat: 35.681, lon: 139.767)])
check("地図に映るタイル", plan.core == [RainRadar.Tile(x: 909, y: 403)], plan.core.map { $0.key }.sorted().joined(separator: " "))
check("周りのタイル", plan.all.count == 9 && plan.all.contains(RainRadar.Tile(x: 908, y: 402)), "\(plan.all.count) 枚")
// タイルの境目の近くでは core が2枚になる
let edge = RainRadar.tiles(for: [(lat: 35.681, lon: 139.92)])
check("タイルの境目", edge.core.count >= 2, edge.core.map { $0.key }.sorted().joined(separator: " "))

// 4. 時刻の一覧と URL
let json = """
[{"basetime":"20261112124500","validtime":"20261112124500","elements":["hrpns","hrpns_nd"]},{"basetime":"20261112124000","validtime":"20261112124000","elements":["hrpns","hrpns_nd"]}]
""".data(using: .utf8)!
let times = RainRadar.targetTimes(json)
check("時刻の一覧", times.count == 2 && times[0].validtime == "20261112124500", "\(times.count) 件")
check("時刻", RainRadar.date("20261112124500")?.timeIntervalSince1970 == 1_794_487_500, "\(RainRadar.date("20261112124500")?.timeIntervalSince1970 ?? 0)")
let url = RainRadar.tileURL(basetime: "20261112124500", validtime: "20261112124500", tile: RainRadar.Tile(x: 893, y: 415))
check("タイルの URL",
      url.absoluteString == "https://www.jma.go.jp/bosai/jmatile/data/nowc/20261112124500/none/20261112124500/surf/hrpns/10/893/415.png",
      url.absoluteString)

// 5. 保存する1行(PC 側が読む形)
let rec = RainRadar.Record(v: "20261112124500", z: 10, x: 893, y: 415, core: true, png: rain.base64EncodedString())
if let line = RainRadar.line(rec), let text = String(data: line, encoding: .utf8) {
    check("保存する行", text.hasPrefix("{\"core\":true,\"png\":\"iVBOR") && text.hasSuffix("\"z\":10}\n"), "\(text.count) 文字")
} else {
    check("保存する行", false, "作れません")
}
let none = RainRadar.Record(v: "20261112124500", z: 10, x: 909, y: 403, core: false, png: nil)
check("降水なしの行", RainRadar.line(none).flatMap { String(data: $0, encoding: .utf8) } == "{\"core\":false,\"v\":\"20261112124500\",\"x\":909,\"y\":403,\"z\":10}\n", "png なし")

// 6. アメダス(観測所の一覧と、観測所ごとのデータ)
if let tdata = try? Data(contentsOf: dir.appendingPathComponent("amedastable.json")),
   let pdata = try? Data(contentsOf: dir.appendingPathComponent("amedas_point.json")) {
    let list = Amedas.stations(tdata)
    check("観測所の一覧", list.count == 3, "\(list.count) 件")
    let tokyo = list.first { $0.code == "44132" }
    check("緯度経度([度, 分])", tokyo.map { abs($0.lat - 35.6917) < 0.001 && abs($0.lon - 139.75) < 0.001 } ?? false,
          tokyo.map { "\($0.lat), \($0.lon)" } ?? "なし")
    check("気温のない観測所", list.first { $0.code == "44136" }?.hasTemp == false, "44136")
    // 東京駅の近く: いちばん近いのは雨量だけの観測所、気温を測っている所では東京
    let near = Amedas.nearest(list, lat: 35.681, lon: 139.767, count: 2)
    check("最寄り", near.first?.station.code == "44136", near.map { "\($0.station.name) \(String(format: "%.1f", $0.km))km" }.joined(separator: ", "))
    let nearT = Amedas.nearest(list, lat: 35.681, lon: 139.767, count: 1, where: { $0.hasTemp })
    check("気温を測っている最寄り", nearT.first?.station.code == "44132", nearT.first?.station.name ?? "なし")
    check("遠すぎる観測所は入れない", Amedas.nearest(list, lat: 26.2, lon: 127.7, count: 3).isEmpty, "那覇の近くに観測所なし")

    if let tokyo, let o = Amedas.observation(pdata, station: tokyo, km: 2.04) {
        check("いちばん新しい時刻", o.t == "20261112214000", o.t)
        check("雨量", o.precip10m == 0.5 && o.precip1h == 1.5, "\(o.precip10m ?? -1) / \(o.precip1h ?? -1)")
        check("気温・湿度", o.temp == 12.6 && o.humidity == 83, "\(o.temp ?? -1) / \(o.humidity ?? -1)")
        check("風", Amedas.windText(o) == "西の風 2 m/s", Amedas.windText(o) ?? "なし")
        check("距離は 0.1km に丸める", o.km == 2.0, "\(o.km)")
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "HH:mm"
        check("時刻は日本時間", o.time.map { f.string(from: $0) } == "12:40", o.time.map { f.string(from: $0) } ?? "なし")
        let line = Amedas.line(o).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("保存する行", line.hasPrefix("{\"code\":\"44132\"") && line.hasSuffix("}\n"), line.trimmingCharacters(in: .newlines))
    } else {
        check("観測所ごとのデータを読む", false, "読めません")
    }
    if let tokyo, let o = Amedas.observation(pdata, station: tokyo, km: 1, at: "20261112213000") {
        check("時刻を指定して読む", o.t == "20261112213000" && o.temp == 12.8 && o.precip1h == 0, o.t)
    } else {
        check("時刻を指定して読む", false, "読めません")
    }
    let jst = Amedas.keyFormat.date(from: "20261112214000")!
    check("観測所ごとのデータの URL(3時間ごとのファイル)",
          Amedas.pointURL(code: "44132", time: jst).absoluteString == "https://www.jma.go.jp/bosai/amedas/data/point/44132/20261112_21.json",
          Amedas.pointURL(code: "44132", time: jst).absoluteString)
    check("最新時刻の読み取り", Amedas.latest("2026-11-12T21:40:00+09:00\n".data(using: .utf8)!) == jst, "21:40 JST")
} else {
    check("アメダスの試験データ", false, "読めません")
}

exit(failed ? 1 : 0)
