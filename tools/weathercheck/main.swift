// 地図サーバーが書く weather.json を Weather.swift で読めるかを確かめる(CI の macOS で動かす)
//   swiftc -O DriveLogger/Sources/Weather.swift tools/weathercheck/main.swift -o weathercheck
//   ./weathercheck tools/weathercheck
// weather.json は national-route-conquest-map の server/weather.mjs の fetchWeather が作ったもの(値は試験用)
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    print("使い方: weathercheck <weather.json のあるフォルダ>")
    exit(2)
}
var failed = false
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "OK" : "NG") \(label): \(detail)")
    if !ok { failed = true }
}

let url = URL(fileURLWithPath: args[1]).appendingPathComponent(DriveWeather.fileName)
do {
    let w = try JSONDecoder().decode(DriveWeather.self, from: Data(contentsOf: url))
    check("まとめ", w.summary.label == "小雨" && w.summary.rain, WeatherText.headline(w.summary))
    check("気温の幅", WeatherText.range(w.summary.tMin, w.summary.tMax) == "14℃", WeatherText.range(w.summary.tMin, w.summary.tMax) ?? "なし")
    check("瞬間風速がなくても読める", w.summary.gustMax == nil, "\(String(describing: w.summary.gustMax))")
    check("地点", w.samples.count >= 2, "\(w.samples.count) 地点")
    check("風", WeatherText.wind(w.samples[0]) == "南の風 4 m/s", WeatherText.wind(w.samples[0]))
    check("load で読める", DriveWeather.load(folder: URL(fileURLWithPath: args[1])) != nil, url.path)
} catch {
    check("読み込み", false, "\(error)")
}
exit(failed ? 1 : 0)
