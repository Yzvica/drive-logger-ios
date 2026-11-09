import Foundation

/// 走ったときの天気。地図サーバー(MiniPC)が走り終えたあとに Open-Meteo から取って、
/// 走行フォルダに weather.json として書いたもの(national-route-conquest-map の server/weather.mjs)。
/// 値は気象モデルの解析値で、観測所の実測ではない
struct DriveWeather: Codable {
    struct Summary: Codable {
        var code: Int
        var label: String
        var icon: String
        var tMin: Double?
        var tMax: Double?
        /// 1時間の降水量の最大(mm)
        var precipMax: Double?
        var windMax: Double?
        var gustMax: Double?
        /// 雨か雪に一度でも当たった
        var rain: Bool
        /// 暗い時間を走った
        var night: Bool
        /// 走り始めた日・場所の日の出・日の入り(UNIX 秒)
        var sunrise: Double?
        var sunset: Double?
    }

    /// 地点ごとの天気(最初と最後、その間は30分か30kmごと)
    struct Sample: Codable {
        var t: Double
        var lat: Double
        var lon: Double
        var code: Int?
        var label: String
        var icon: String
        var temp: Double?
        var feels: Double?
        var humidity: Double?
        /// その時刻を含む1時間の降水量(mm)
        var precip: Double?
        var snow: Double?
        var cloud: Double?
        var pressure: Double?
        /// 風速・最大瞬間風速(m/s)と風向(風が吹いてくる方角、北=0度)
        var wind: Double?
        var windDir: Double?
        var gust: Double?
        var isDay: Bool?
    }

    var source: String
    /// forecast(約3か月以内)か archive(過去データ・再解析)
    var api: String
    var fetchedAt: String
    var summary: Summary
    var samples: [Sample]

    static let fileName = "weather.json"

    static func load(folder: URL) -> DriveWeather? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(DriveWeather.self, from: data)
    }
}

enum WeatherText {
    private static let dirs = ["北", "北東", "東", "南東", "南", "南西", "西", "北西"]

    static func temp(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f℃", v)
    }

    /// 気温の幅(「12〜15℃」、同じなら「12℃」)
    static func range(_ a: Double?, _ b: Double?) -> String? {
        guard let a, let b else { return nil }
        let lo = Int(a.rounded()), hi = Int(b.rounded())
        return lo == hi ? "\(lo)℃" : "\(lo)〜\(hi)℃"
    }

    static func wind(_ s: DriveWeather.Sample) -> String {
        guard let w = s.wind else { return "—" }
        let dir = s.windDir.map { dirs[Int(($0 / 45).rounded()) % 8] + "の風 " } ?? ""
        return dir + String(format: "%.0f m/s", w)
    }

    /// まとめの1行(「🌧️ 小雨・12〜13℃」)
    static func headline(_ s: DriveWeather.Summary) -> String {
        ([s.icon + " " + s.label] + [range(s.tMin, s.tMax)].compactMap { $0 }).joined(separator: "・")
    }
}
