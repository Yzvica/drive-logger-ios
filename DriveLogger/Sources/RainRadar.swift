import CoreGraphics
import Foundation
import ImageIO

/// 気象庁の高解像度降水ナウキャスト(雨雲レーダー)のタイルを扱う。
/// 5分おき・約250m・降水強度は8段階。タイルは色分けの PNG で、色から強度の段階を読む。
/// ここは計算だけ(通信は RainFetcher)。CI の macOS でも動かして確かめる(tools/raincheck)
enum RainRadar {
    /// タイルのズーム(動画の雨雲レーダーと同じ。元データの細かさ=約250m がこのズームでほぼ1画素)
    static let zoom = 10
    static let tileSize = 256
    static let base = "https://www.jma.go.jp/bosai/jmatile/data/nowc"

    /// 降水強度の段階(0 = 降っていない、1〜8)
    static let labels = [
        "降っていない", "1mm/h未満", "1〜5mm/h", "5〜10mm/h", "10〜20mm/h",
        "20〜30mm/h", "30〜50mm/h", "50〜80mm/h", "80mm/h以上",
    ]

    static func label(_ level: Int) -> String {
        labels.indices.contains(level) ? labels[level] : "不明"
    }

    /// 気象庁の凡例の色(強度1〜8)。タイルの色にいちばん近いものの段階にする
    static let colors: [(r: Int, g: Int, b: Int)] = [
        (242, 242, 255), (160, 210, 255), (33, 140, 255), (0, 65, 255),
        (250, 245, 0), (255, 153, 0), (255, 40, 0), (180, 0, 104),
    ]

    // MARK: - タイル座標

    struct Tile: Hashable {
        var x: Int
        var y: Int
        var key: String { "\(x)_\(y)" }
    }

    /// 緯度経度 → タイル座標(小数つき。整数部がタイル番号、小数部がタイルの中の位置)
    static func tilePosition(lat: Double, lon: Double, zoom: Int = RainRadar.zoom) -> (x: Double, y: Double) {
        let n = pow(2.0, Double(zoom))
        let x = (lon + 180) / 360 * n
        let r = lat * .pi / 180
        let y = (1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * n
        return (x, y)
    }

    static func tile(lat: Double, lon: Double) -> Tile {
        let p = tilePosition(lat: lat, lon: lon)
        return Tile(x: Int(floor(p.x)), y: Int(floor(p.y)))
    }

    /// 地図に映る範囲ぶんの余裕(約5.5km)。PC 側の fetch_rain_radar.js と同じ
    static let latMargin = 0.05
    static let lonMargin = 0.06

    /// 通った位置から、取っておくタイルを決める。
    /// core = 地図に映るタイル(位置の周り約5.5km)、all = それに周り1タイルを足したもの
    /// (範囲の外から入ってくる雨と、雨雲の動きを見るため。動画用の30秒おきの推定に使う)
    static func tiles(for points: [(lat: Double, lon: Double)], ring: Int = 1) -> (core: Set<Tile>, all: Set<Tile>) {
        var core = Set<Tile>()
        for p in points {
            let a = tile(lat: p.lat + latMargin, lon: p.lon - lonMargin)
            let b = tile(lat: p.lat - latMargin, lon: p.lon + lonMargin)
            guard a.x <= b.x, a.y <= b.y else { continue }
            for x in a.x...b.x { for y in a.y...b.y { core.insert(Tile(x: x, y: y)) } }
        }
        var all = core
        for t in core {
            for dx in -ring...ring { for dy in -ring...ring { all.insert(Tile(x: t.x + dx, y: t.y + dy)) } }
        }
        return (core, all)
    }

    static func tileURL(basetime: String, validtime: String, tile: Tile) -> URL {
        URL(string: "\(base)/\(basetime)/none/\(validtime)/surf/hrpns/\(zoom)/\(tile.x)/\(tile.y).png")!
    }

    // MARK: - 時刻

    /// 気象庁の時刻(UTC の yyyyMMddHHmmss)
    static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    static func date(_ s: String) -> Date? { timeFormat.date(from: s) }

    /// targetTimes_N1.json(実況)・targetTimes_N2.json(予測)の1件
    struct TargetTime: Codable {
        var basetime: String
        var validtime: String
        var elements: [String]?

        var hasRain: Bool { elements?.contains("hrpns") ?? true }
    }

    static func targetTimes(_ data: Data) -> [TargetTime] {
        ((try? JSONDecoder().decode([TargetTime].self, from: data)) ?? []).filter { $0.hasRain }
    }

    // MARK: - PNG → 降水強度

    /// タイルの PNG を 256×256 の降水強度(0〜8、左上から行ごと)にする。読めなければ nil
    static func intensities(png: Data) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = image.width, h = image.height
        guard w == tileSize, h == tileSize else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let a = Int(rgba[i * 4 + 3])
            // 透明(降っていない)か、ほぼ透明な縁は 0
            if a < 128 { continue }
            // 色は透明度が掛かった値で入っているので、元に戻してから比べる
            let r = Int(rgba[i * 4]) * 255 / a
            let g = Int(rgba[i * 4 + 1]) * 255 / a
            let b = Int(rgba[i * 4 + 2]) * 255 / a
            out[i] = UInt8(nearestLevel(r: r, g: g, b: b))
        }
        return out
    }

    static func nearestLevel(r: Int, g: Int, b: Int) -> Int {
        var best = 0
        var bestD = Int.max
        for (i, c) in colors.enumerated() {
            let d = (r - c.r) * (r - c.r) + (g - c.g) * (g - c.g) + (b - c.b) * (b - c.b)
            if d < bestD {
                bestD = d
                best = i + 1
            }
        }
        return best
    }

    /// 降水の無いタイルか。気象庁は降水の無いタイルも、全面が透明な PNG を 200 で返す。
    /// 降水が少しだけのタイルは小さいので、大きさでは見分けず、中身を読んで確かめる
    static func isEmptyTile(_ png: Data) -> Bool {
        guard let grid = intensities(png: png) else { return false }
        return !grid.contains { $0 > 0 }
    }

    /// 位置の降水強度。その位置を含むタイルの強度(intensities の結果)から読む
    static func level(lat: Double, lon: Double, tile: Tile, intensities: [UInt8]) -> Int? {
        let p = tilePosition(lat: lat, lon: lon)
        let px = Int(floor((p.x - Double(tile.x)) * Double(tileSize)))
        let py = Int(floor((p.y - Double(tile.y)) * Double(tileSize)))
        guard (0..<tileSize).contains(px), (0..<tileSize).contains(py),
              intensities.count == tileSize * tileSize else { return nil }
        return Int(intensities[py * tileSize + px])
    }

    // MARK: - 保存する形(rain_radar.jsonl の1行 = タイル1枚)

    /// 走行フォルダの rain_radar.jsonl に、取ったタイルを1行ずつ書く。
    /// PC 側(_drivelog の fetch_rain_radar.js)がこれを読んで、動画用の雨雲レーダーのデータにする
    struct Record: Codable {
        /// 実況の時刻(UTC の yyyyMMddHHmmss。basetime も同じ)
        var v: String
        var z: Int
        var x: Int
        var y: Int
        /// 地図に映るタイルなら true、動きを見るための周りのタイルなら false
        var core: Bool
        /// PNG を base64 にしたもの(気象庁から届いたまま)。このタイルに降水が無ければ入れない
        var png: String?
    }

    static let fileName = "rain_radar.jsonl"

    static func line(_ r: Record) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard var d = try? enc.encode(r) else { return nil }
        d.append(0x0a)
        return d
    }
}
