import Foundation

/// 1回の記録を、ある時刻で2つに分ける(バスのあとに歩いた、など移動手段が途中で変わったとき)。
/// ファイルの読み書きだけを行い、meta.json の作り直しは LogStore.split が行う(tools/splitcheck で確かめる)
enum LogSplit {
    /// 時刻(先頭の列 unix_s)で分ける CSV。ヘッダーは両方に入れる
    static let csvFiles = ["location.csv", "motion.csv", "pressure.csv"]
    /// 両方にそのまま写すもの(雨雲レーダー・アメダスは時刻の幅が広いので、分けずに両方に置く)
    static let copyFiles = ["rain_radar.jsonl", "amedas.jsonl"]
    /// 分けたら作り直す・取り直すもの(運転評価・トンネルの補い・天気)。両方から消す
    static let dropFiles = ["evaluation.json", "location_filled.csv", "weather.json"]

    /// CSV を at(UNIX 秒)の前と後に分ける。at ちょうどの行は後ろに入れる。行数 (前, 後) を返す。
    /// 大きなファイル(加速度は数十MB)でも少しずつ読んで書く
    @discardableResult
    static func splitCSV(_ src: URL, before: URL, after: URL, at: Double) throws -> (Int, Int) {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: before.path, contents: nil)
        FileManager.default.createFile(atPath: after.path, contents: nil)
        let outA = try FileHandle(forWritingTo: before)
        let outB = try FileHandle(forWritingTo: after)
        defer { try? outA.close(); try? outB.close() }

        var rest = Data()
        var header = true
        var counts = (0, 0)
        var bufA = Data(), bufB = Data()
        let flushBytes = 1 << 20

        func handle(_ line: Data) {
            var withNL = line
            withNL.append(0x0a)
            if header {
                header = false
                bufA.append(withNL)
                bufB.append(withNL)
                return
            }
            if line.isEmpty { return }
            let comma = line.firstIndex(of: 0x2c) ?? line.endIndex
            let t = Double(String(decoding: line[line.startIndex..<comma], as: UTF8.self)) ?? -Double.infinity
            if t < at {
                bufA.append(withNL)
                counts.0 += 1
            } else {
                bufB.append(withNL)
                counts.1 += 1
            }
        }

        while true {
            let chunk = input.readData(ofLength: flushBytes)
            if chunk.isEmpty { break }
            rest.append(chunk)
            var start = rest.startIndex
            while let nl = rest[start...].firstIndex(of: 0x0a) {
                var line = rest[start..<nl]
                if line.last == 0x0d { line = line.dropLast() }
                handle(Data(line))
                start = rest.index(after: nl)
            }
            rest = Data(rest[start...])
            if bufA.count > flushBytes { outA.write(bufA); bufA.removeAll(keepingCapacity: true) }
            if bufB.count > flushBytes { outB.write(bufB); bufB.removeAll(keepingCapacity: true) }
        }
        // 最後の行(改行なし・記録中に落ちて書きかけのものも含む)
        if !rest.isEmpty { handle(rest) }
        outA.write(bufA)
        outB.write(bufB)
        return counts
    }

    /// location.csv から作り直した軌跡のまとめ(アプリが記録中に数えるのと同じ方法)
    struct TrackStats: Equatable {
        var points = 0
        var distanceM = 0.0
        var maxSpeedMS = 0.0
        var maxAltitudeM: Double?
        var firstUnix: Double?
        var lastUnix: Double?
    }

    /// location.csv から track.gpx を作り直し、点の数・距離などを数える。
    /// 記録中(Recorder)と同じく、精度 50m 以内の点だけを GPX に入れ、距離は精度 30m 以内の点どうしで足す
    static func rebuildTrack(location: URL, gpx: URL, name: String) throws -> TrackStats {
        let text = try String(contentsOf: location, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let head = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func col(_ n: String) -> Int? { head.firstIndex(of: n) }
        guard let ti = col("unix_s"), let la = col("lat"), let lo = col("lon") else { throw CocoaError(.fileReadCorruptFile) }
        let al = col("alt_m"), ac = col("h_acc_m"), sp = col("speed_ms")

        var st = TrackStats()
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="DriveLogger" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>\(name)</name><trkseg>

        """
        var lastGood: (lat: Double, lon: Double)?
        for line in lines {
            let c = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            func num(_ i: Int?) -> Double? {
                guard let i, i < c.count, !c[i].isEmpty else { return nil }
                return Double(c[i])
            }
            guard let t = num(ti), let lat = num(la), let lon = num(lo) else { continue }
            if st.firstUnix == nil { st.firstUnix = t }
            st.lastUnix = t
            let acc = num(ac) ?? 0
            guard acc <= 50 else { continue }
            let alt = num(al)
            let speed = num(sp).flatMap { $0 >= 0 ? $0 : nil }
            if let prev = lastGood, acc <= 30 { st.distanceM += distance(prev.lat, prev.lon, lat, lon) }
            if acc <= 30 || lastGood == nil { lastGood = (lat, lon) }
            st.points += 1
            if let s = speed { st.maxSpeedMS = max(st.maxSpeedMS, s) }
            if let a = alt { st.maxAltitudeM = max(st.maxAltitudeM ?? a, a) }
            var s = "<trkpt lat=\"\(Fmt.n(lat, 7))\" lon=\"\(Fmt.n(lon, 7))\">"
            if let alt { s += "<ele>\(Fmt.n(alt, 1))</ele>" }
            s += "<time>\(Fmt.iso.string(from: Date(timeIntervalSince1970: t)))</time>"
            if let speed { s += "<extensions><speed>\(Fmt.n(speed, 2))</speed></extensions>" }
            out += s + "</trkpt>\n"
        }
        out += "</trkseg></trk>\n</gpx>\n"
        try out.write(to: gpx, atomically: true, encoding: .utf8)
        return st
    }

    /// 2点間の距離(m、球面で近似)
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * rad) * cos(lat2 * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    /// 記録フォルダ from を at で分け、後半を新しいフォルダ to に置く(from は前半だけになる)。
    /// 前半・後半の軌跡のまとめを返す。どちらかに位置の点が無ければ何も変えずに例外
    static func split(from: URL, to: URL, at: Double, fromName: String, toName: String) throws -> (TrackStats, TrackStats) {
        let fm = FileManager.default
        let loc = from.appendingPathComponent("location.csv")
        // 位置の行が前後どちらにもあるか、先に確かめる(分けたあとで片方が空にならないように)
        let tmp = fm.temporaryDirectory.appendingPathComponent("split-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let (na, nb) = try splitCSV(loc, before: tmp.appendingPathComponent("a.csv"), after: tmp.appendingPathComponent("b.csv"), at: at)
        guard na >= 2, nb >= 2 else { throw SplitError.tooShort }

        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in csvFiles {
            let src = from.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let a = tmp.appendingPathComponent("\(name).a")
            try splitCSV(src, before: a, after: to.appendingPathComponent(name), at: at)
            _ = try fm.replaceItemAt(src, withItemAt: a)
        }
        for name in copyFiles {
            let src = from.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: to.appendingPathComponent(name)) }
        }
        for name in dropFiles { try? fm.removeItem(at: from.appendingPathComponent(name)) }
        let sa = try rebuildTrack(location: loc, gpx: from.appendingPathComponent("track.gpx"), name: fromName)
        let sb = try rebuildTrack(location: to.appendingPathComponent("location.csv"), gpx: to.appendingPathComponent("track.gpx"), name: toName)
        return (sa, sb)
    }

    enum SplitError: LocalizedError {
        case tooShort
        var errorDescription: String? { "分けると片方の位置の記録が少なすぎます(もう少し内側で分けてください)" }
    }
}
