import CoreLocation
import SwiftUI

/// 「情報」タブ: 記録していないときも、いまいる場所の雨雲レーダー(実況とこの先60分の予測)と、
/// 最寄りのアメダス観測所の実測を見られる。ここで取ったものは保存しない
final class InfoModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Step: Identifiable, Equatable {
        var time: Date
        var level: Int
        /// 予測(false なら実況)
        var forecast: Bool
        var id: Date { time }
    }

    @Published private(set) var place: CLLocationCoordinate2D?
    @Published private(set) var placeTime: Date?
    @Published private(set) var steps: [Step] = []
    @Published private(set) var rain: Amedas.Observation?
    @Published private(set) var weather: Amedas.Observation?
    @Published private(set) var loading = false
    @Published private(set) var problem: String?
    @Published private(set) var updated: Date?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// 位置を取ってから天気を取る。記録中は記録の位置を使う
    func refresh() {
        guard !loading else { return }
        problem = nil
        if Recorder.shared.isRecording, let c = Recorder.shared.track.last {
            got(c, at: Date())
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            problem = "位置情報が許可されていません(設定アプリで許可してください)"
            return
        default:
            break
        }
        loading = true
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways,
           place == nil, !loading {
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async {
            self.loading = false
            self.got(loc.coordinate, at: loc.timestamp)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.loading = false
            if self.place == nil { self.problem = "位置を取れませんでした" }
        }
    }

    private func got(_ c: CLLocationCoordinate2D, at t: Date) {
        place = c
        placeTime = t
        loading = true
        Task.detached(priority: .userInitiated) {
            async let radar = InfoModel.radar(lat: c.latitude, lon: c.longitude)
            async let amedas = InfoModel.amedas(lat: c.latitude, lon: c.longitude)
            let (s, a) = await (radar, amedas)
            DispatchQueue.main.async {
                self.loading = false
                self.updated = Date()
                if s == nil && a == nil {
                    self.problem = "取れませんでした(ネットにつながっているか確かめてください)"
                    return
                }
                if let s { self.steps = s }
                if let a {
                    self.rain = a.rain
                    self.weather = a.weather ?? a.rain
                }
            }
        }
    }

    // MARK: - 通信

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private static func get(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func level(_ png: Data, lat: Double, lon: Double, tile: RainRadar.Tile) -> Int? {
        guard let grid = RainRadar.intensities(png: png) else { return nil }
        return RainRadar.level(lat: lat, lon: lon, tile: tile, intensities: grid)
    }

    /// 実況(いちばん新しいもの)と、この先60分の予測(5分おき)
    static func radar(lat: Double, lon: Double) async -> [Step]? {
        let tile = RainRadar.tile(lat: lat, lon: lon)
        guard let n1 = await get(URL(string: "\(RainRadar.base)/targetTimes_N1.json")!),
              let now = RainRadar.targetTimes(n1).filter({ $0.basetime == $0.validtime }).max(by: { $0.validtime < $1.validtime }),
              let nowDate = RainRadar.date(now.validtime),
              let png = await get(RainRadar.tileURL(basetime: now.basetime, validtime: now.validtime, tile: tile)),
              let l0 = level(png, lat: lat, lon: lon, tile: tile) else { return nil }
        var steps = [Step(time: nowDate, level: l0, forecast: false)]
        // 予測は実況の basetime から 5〜60 分先(N2 の一覧に無い組み合わせも配信されている)
        for m in stride(from: 5, through: 60, by: 5) {
            let v = nowDate.addingTimeInterval(Double(m) * 60)
            let vs = RainRadar.timeFormat.string(from: v)
            guard let p = await get(RainRadar.tileURL(basetime: now.basetime, validtime: vs, tile: tile)),
                  let l = level(p, lat: lat, lon: lon, tile: tile) else { continue }
            steps.append(Step(time: v, level: l, forecast: true))
        }
        return steps
    }

    static func amedas(lat: Double, lon: Double) async -> (rain: Amedas.Observation?, weather: Amedas.Observation?)? {
        let stations = await AmedasFetcher.table()
        guard !stations.isEmpty, let lt = await get(Amedas.latestURL), let latest = Amedas.latest(lt) else { return nil }
        let key = Amedas.keyFormat.string(from: latest)
        var rain: Amedas.Observation?
        var weather: Amedas.Observation?
        for c in Amedas.nearest(stations, lat: lat, lon: lon, count: 3) {
            guard let d = await get(Amedas.pointURL(code: c.station.code, time: latest)),
                  let o = Amedas.observation(d, station: c.station, km: c.km, at: key),
                  o.t == key, o.precip10m != nil else { continue }
            rain = o
            break
        }
        for c in Amedas.nearest(stations, lat: lat, lon: lon, count: 3, where: { $0.hasTemp }) {
            if let r = rain, r.code == c.station.code, r.temp != nil { weather = r; break }
            guard let d = await get(Amedas.pointURL(code: c.station.code, time: latest)),
                  let o = Amedas.observation(d, station: c.station, km: c.km, at: key),
                  o.t == key, o.temp != nil else { continue }
            weather = o
            break
        }
        if rain == nil && weather == nil { return nil }
        return (rain, weather)
    }
}

struct InfoView: View {
    @StateObject private var model = InfoModel()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = Amedas.jst
        f.dateFormat = "H:mm"
        return f
    }()

    var body: some View {
        NavigationView {
            List {
                Section {
                    if let now = model.steps.first {
                        HStack(spacing: 8) {
                            Circle().fill(RainPanel.color(now.level)).frame(width: 16, height: 16)
                                .overlay(Circle().stroke(Color.secondary, lineWidth: 0.5))
                            Text(now.level > 0 ? "雨 \(RainRadar.label(now.level))" : "雨は降っていない")
                                .font(.headline)
                            Spacer()
                            Text("\(InfoView.clock.string(from: now.time)) 時点")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.steps.count > 1 {
                            forecastBar
                            Text(forecastText).font(.footnote)
                        }
                    } else {
                        Text(model.loading ? "取っています…" : "まだ取っていません").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("雨雲レーダー(いまいる場所)")
                } footer: {
                    Text("気象庁の高解像度降水ナウキャスト(約250m・5分おき)。予測はこの先60分まで")
                }

                Section {
                    if let r = model.rain {
                        row("雨量の観測所", "\(r.name)(\(String(format: "%.0f", r.km))km)")
                        if let v = r.precip10m { row("10分間の雨量", "\(Amedas.mm(v)) mm") }
                        if let v = r.precip1h { row("1時間の雨量", "\(Amedas.mm(v)) mm") }
                    }
                    if let w = model.weather {
                        if w.code != model.rain?.code {
                            row("気温・風の観測所", "\(w.name)(\(String(format: "%.0f", w.km))km)")
                        }
                        if let t = w.temp { row("気温", String(format: "%.1f ℃", t)) }
                        if let h = w.humidity { row("湿度", String(format: "%.0f %%", h)) }
                        if let s = Amedas.windText(w) { row("風", s) }
                    }
                    if model.rain == nil && model.weather == nil {
                        Text(model.loading ? "取っています…" : "近くの観測所の値がありません").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("アメダス(最寄りの観測所の実測)")
                } footer: {
                    if let t = (model.rain ?? model.weather)?.time {
                        Text("\(InfoView.clock.string(from: t)) の観測。観測所は約17km おきなので、いまいる場所そのものの値ではありません")
                    }
                }

                Section {
                    if let p = model.place {
                        row("緯度・経度", String(format: "%.5f, %.5f", p.latitude, p.longitude))
                    }
                    if let u = model.updated {
                        row("更新", Display.time.string(from: u))
                    }
                    if let problem = model.problem {
                        Text(problem).font(.footnote).foregroundStyle(.orange)
                    }
                    Button {
                        model.refresh()
                    } label: {
                        Label(model.loading ? "取っています…" : "更新", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.loading)
                } header: {
                    Text("位置")
                }
            }
            .navigationTitle("情報")
            .refreshable { model.refresh() }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            // 開いたとき、前に取ってから5分たっていれば取り直す
            if model.updated.map({ Date().timeIntervalSince($0) > 5 * 60 }) ?? true { model.refresh() }
        }
    }

    /// 実況と予測を、5分ごとの色の帯で並べる
    private var forecastBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                ForEach(model.steps) { s in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(RainPanel.color(s.level))
                        .frame(height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                }
            }
            HStack {
                Text("いま").font(.caption2)
                Spacer()
                if let last = model.steps.last {
                    Text(InfoView.clock.string(from: last.time)).font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var forecastText: String {
        let f = model.steps.filter { $0.forecast }
        guard let maxLevel = f.map({ $0.level }).max() else { return "" }
        if maxLevel == 0 { return "この先60分は降らない予測" }
        let now = model.steps.first?.level ?? 0
        if now == 0, let start = f.first(where: { $0.level > 0 }) {
            return "\(InfoView.clock.string(from: start.time)) ごろから降り出す予測(最大 \(RainRadar.label(maxLevel)))"
        }
        if let stop = f.first(where: { $0.level == 0 }), now > 0 {
            return "\(InfoView.clock.string(from: stop.time)) ごろにやむ予測"
        }
        return "この先60分の最大 \(RainRadar.label(maxLevel))"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
