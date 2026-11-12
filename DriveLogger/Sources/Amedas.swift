import Foundation

/// 気象庁のアメダス(観測所の実測)を扱う。10分ごと。雨量計で測った雨量は、雨雲レーダーの8段階より確か。
/// 観測所は約17km おきなので、値は「最寄りの観測所」のもの(走っている場所そのものではない)。
/// ここは計算だけ(通信は AmedasFetcher)。CI の macOS でも動かして確かめる(tools/raincheck)
enum Amedas {
    static let base = "https://www.jma.go.jp/bosai/amedas"
    static let tableURL = URL(string: "\(base)/const/amedastable.json")!
    static let latestURL = URL(string: "\(base)/data/latest_time.txt")!

    // MARK: - 観測所の一覧(amedastable.json)

    struct Station: Hashable {
        var code: String
        var name: String
        var lat: Double
        var lon: Double
        /// 気温を測っている(雨量だけの観測所もある)
        var hasTemp: Bool
    }

    private struct RawStation: Decodable {
        var type: String?
        var elems: String?
        var lat: [Double]
        var lon: [Double]
        var kjName: String
    }

    /// amedastable.json を読む。緯度経度は [度, 分] で入っている
    static func stations(_ data: Data) -> [Station] {
        guard let raw = try? JSONDecoder().decode([String: RawStation].self, from: data) else { return [] }
        return raw.compactMap { code, s in
            guard s.lat.count == 2, s.lon.count == 2 else { return nil }
            // elems の1桁目が気温(雨量だけの観測所は "0")
            let temp = s.elems.map { $0.first == "1" } ?? true
            return Station(code: code, name: s.kjName, lat: s.lat[0] + s.lat[1] / 60,
                           lon: s.lon[0] + s.lon[1] / 60, hasTemp: temp)
        }
        .sorted { $0.code < $1.code }
    }

    /// 2点間の距離(km)
    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, a.squareRoot()))
    }

    /// 近い順に count 個。遠すぎる(maxKm より先)観測所は入れない
    static func nearest(_ list: [Station], lat: Double, lon: Double, count: Int, maxKm: Double = 40,
                        where ok: (Station) -> Bool = { _ in true }) -> [(station: Station, km: Double)] {
        list.lazy.filter(ok)
            .map { (station: $0, km: distanceKm(lat, lon, $0.lat, $0.lon)) }
            .filter { $0.km <= maxKm }
            .sorted { $0.km < $1.km }
            .prefix(count)
            .map { $0 }
    }

    // MARK: - 時刻(アメダスの時刻は日本時間)

    static let jst = TimeZone(identifier: "Asia/Tokyo")!

    /// 観測所ごとのデータの時刻(日本時間の yyyyMMddHHmmss)
    static let keyFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = jst
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    /// latest_time.txt(例 2026-11-12T21:40:00+09:00)
    static func latest(_ data: Data) -> Date? {
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    /// 観測所ごとのデータの URL。1ファイルに3時間ぶん(日本時間の 0,3,6,...,21 時から)入っている
    static func pointURL(code: String, time: Date) -> URL {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = jst
        let c = cal.dateComponents([.year, .month, .day, .hour], from: time)
        let h = (c.hour ?? 0) / 3 * 3
        let name = String(format: "%04d%02d%02d_%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, h)
        return URL(string: "\(base)/data/point/\(code)/\(name).json")!
    }

    // MARK: - 観測値

    /// 1つの観測所の、ある時刻の値。測っていない・欠測の値は nil
    struct Observation: Codable, Equatable {
        /// 観測の時刻(日本時間の yyyyMMddHHmmss)
        var t: String
        var code: String
        var name: String
        /// 走っていた位置から観測所までの距離(km)
        var km: Double
        /// 10分間・1時間の雨量(mm)
        var precip10m: Double?
        var precip1h: Double?
        var temp: Double?
        var humidity: Double?
        /// 風速(m/s)と風向(16方位の番号。1=北北東 … 16=北、0=静穏)
        var wind: Double?
        var windDir: Int?

        var time: Date? { Amedas.keyFormat.date(from: t) }
    }

    /// 値は [数値, 品質] の2つ。品質が 0(正常)か 1(準正常)で値が null でないものだけ使う
    /// (気象庁のアメダスの画面と同じ扱い。4 = 資料不足・5 = 休止中・6 = 欠測など)
    private static func value(_ any: Any?) -> Double? {
        guard let a = any as? [Any], let v = a.first as? NSNumber else { return nil }
        if a.count >= 2, let q = a[1] as? NSNumber, q.intValue > 1 { return nil }
        return v.doubleValue
    }

    /// 観測所ごとのデータ(point/{番号}/{日付}_{時}.json)から、いちばん新しい時刻の値を読む。
    /// at を渡すとその時刻の値
    static func observation(_ data: Data, station: Station, km: Double, at key: String? = nil) -> Observation? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let keys = obj.keys.filter { $0.count == 14 && Int($0) != nil }.sorted()
        guard let k = key.flatMap({ keys.contains($0) ? $0 : nil }) ?? keys.last,
              let d = obj[k] as? [String: Any] else { return nil }
        let o = Observation(
            t: k, code: station.code, name: station.name, km: (km * 10).rounded() / 10,
            precip10m: value(d["precipitation10m"]), precip1h: value(d["precipitation1h"]),
            temp: value(d["temp"]), humidity: value(d["humidity"]),
            wind: value(d["wind"]), windDir: value(d["windDirection"]).map { Int($0) })
        // 何も測れていなければ使わない
        if o.precip10m == nil && o.precip1h == nil && o.temp == nil && o.wind == nil { return nil }
        return o
    }

    // MARK: - 表示

    static let directions = ["北北東", "北東", "東北東", "東", "東南東", "南東", "南南東", "南",
                             "南南西", "南西", "西南西", "西", "西北西", "北西", "北北西", "北"]

    static func windText(_ o: Observation) -> String? {
        guard let w = o.wind else { return nil }
        if let d = o.windDir, (1...16).contains(d) {
            return "\(directions[d - 1])の風 \(String(format: "%.0f", w)) m/s"
        }
        return o.windDir == 0 ? "静穏" : "風 \(String(format: "%.0f", w)) m/s"
    }

    static func mm(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    // MARK: - 保存する形(amedas.jsonl の1行 = 1つの観測所の1つの時刻)

    static let fileName = "amedas.jsonl"

    static func line(_ o: Observation) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard var d = try? enc.encode(o) else { return nil }
        d.append(0x0a)
        return d
    }
}
