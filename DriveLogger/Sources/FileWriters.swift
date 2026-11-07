import Foundation

/// 追記していくテキストファイル。少しずつ貯めてまとめて書く(1秒に50行でも電池を使いすぎないため)
final class AppendFile {
    private let handle: FileHandle
    private var buffer = Data()
    private let flushBytes: Int

    init(url: URL, header: String? = nil, flushBytes: Int = 64 * 1024) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.flushBytes = flushBytes
        if let header { append(header) }
    }

    func append(_ text: String) {
        buffer.append(contentsOf: Array(text.utf8))
        if buffer.count >= flushBytes { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() {
        flush()
        try? handle.close()
    }
}

enum Fmt {
    /// 数値を決まった桁数で書く(nil や NaN は空欄)
    static func n(_ v: Double?, _ digits: Int) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(digits)f", v)
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 走行ID(ローカル時刻の yyyyMMdd-HHmmss)
    static let sessionID: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

/// 走行中に GPX を少しずつ書く。途中で落ちても、地図側は閉じタグがなくても読める
final class GPXWriter {
    private let file: AppendFile

    init(url: URL, name: String) throws {
        file = try AppendFile(url: url, header: """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="DriveLogger" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>\(name)</name><trkseg>

        """)
    }

    func add(lat: Double, lon: Double, ele: Double?, time: Date, speed: Double?) {
        var s = "<trkpt lat=\"\(Fmt.n(lat, 7))\" lon=\"\(Fmt.n(lon, 7))\">"
        if let ele { s += "<ele>\(Fmt.n(ele, 1))</ele>" }
        s += "<time>\(Fmt.iso.string(from: time))</time>"
        if let speed, speed >= 0 { s += "<extensions><speed>\(Fmt.n(speed, 2))</speed></extensions>" }
        s += "</trkpt>\n"
        file.append(s)
    }

    func close() {
        file.append("</trkseg></trk>\n</gpx>\n")
        file.close()
    }
}
