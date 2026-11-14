import Charts
import MapKit
import SwiftUI

/// 下の段に出すグラフ
enum ReviewLower: String, CaseIterable, Identifiable {
    /// 前後G・横G(重ねて)と躍度
    case motion
    case altitude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .motion: return "G・躍度"
        case .altitude: return "高度"
        }
    }
}

/// グラフの色(地図のリプレイと同じ)
enum ReviewColors {
    static let speed = Color.accentColor
    static let lon = Color(red: 0.12, green: 0.53, blue: 0.90)
    static let lat = Color(red: 0.26, green: 0.63, blue: 0.28)
    static let jerk = Color(red: 0.0, green: 0.54, blue: 0.48)
}

/// 地図とグラフで走行を振り返る画面。グラフをなぞると地図の丸が動き、地図の軌跡をタップするとグラフのカーソルが動く。
/// ▶ で走りを再生(リプレイ)でき、丸が地図の上を走り、グラフのカーソルと G円が一緒に動く
struct ReviewView: View {
    let meta: SessionMeta
    @EnvironmentObject var store: LogStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var uploader: Uploader
    @EnvironmentObject var recorder: Recorder
    @Environment(\.dismiss) private var dismiss
    /// 分ける時刻(「ここで分ける」を押したとき)
    @State private var splitAt: Date?

    @State private var data: ReviewData?
    @State private var failed: String?
    @State private var cursor: Int?
    @State private var focus: Int?
    @State private var lower: ReviewLower = .motion
    @State private var byDistance = false

    // リプレイ
    @State private var playing = false
    @State private var rate: Double = 10
    @State private var follow = true
    /// 再生している時刻(開始からの秒)
    @State private var playT: Double?
    /// 再生がカーソルを動かした最後の点(指でなぞって動かしたのと見分けるため)
    @State private var autoCursor: Int?

    static let rates: [Double] = [1, 5, 10, 30, 60]

    private var events: [EvalEvent] {
        meta.travelMode.hasDriveEval ? (store.evaluation(meta.id)?.events ?? []) : []
    }

    var body: some View {
        Group {
            if let data, data.samples.count >= 2 {
                content(data)
            } else if let failed {
                Text(failed).foregroundStyle(.secondary).padding()
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("ログを読んでいます…").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("振り返り")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { splitAt != nil }, set: { if !$0 { splitAt = nil } })) {
            if let at = splitAt {
                SplitSheet(meta: meta, at: at) {
                    splitAt = nil
                    // 分けたら、前半だけになったログの詳細に戻る
                    dismiss()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("地図", selection: $settings.mapStyle) {
                        ForEach(MapStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("横軸", selection: $byDistance) {
                        Text("時間").tag(false)
                        Text("距離").tag(true)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await load()
            // 地図サーバーがトンネル(電車は線路)の区間を補っていれば受け取り、変わっていたら読み直す。
            // サーバーはあとから補い直すことがあるので、開くたびに確かめる
            if await Uploader.shared.fetchFilled(meta) {
                await load(force: true)
            }
            await sendReplayIfNeeded()
        }
        .task(id: playing) {
            guard playing else { return }
            var last = Date()
            while !Task.isCancelled && playing {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let d = data, let end = d.samples.last?.t else { break }
                let now = Date()
                // 再生中に指でグラフをなぞった・地図の線を押したら、そこから続ける
                if let c = cursor, c != autoCursor, d.samples.indices.contains(c) { playT = d.samples[c].t }
                var t = (playT ?? 0) + now.timeIntervalSince(last) * rate
                last = now
                if t >= end {
                    t = end
                    playing = false
                }
                playT = t
                let i = d.index(atT: t)
                autoCursor = i
                cursor = i
            }
        }
        .onDisappear { playing = false }
    }

    private func load(force: Bool = false) async {
        guard data == nil || force else { return }
        let folder = store.dir(meta.id)
        let motion = meta.travelMode.hasDriveEval
        let handheld = meta.travelMode == .ride
        let pressure = meta.travelMode != .plane
        let result: Result<ReviewData, Error> = await Task.detached(priority: .userInitiated) {
            Result { try ReviewLoader.load(folder: folder, motion: motion, pressure: pressure, handheld: handheld) }
        }.value
        switch result {
        case .success(let d):
            data = d
            if !d.hasMotion { lower = .altitude }
            if d.samples.count < 2 { failed = "位置の記録が少なすぎて表示できません" }
        case .failure(let e):
            failed = "ログを読めませんでした: \(e.localizedDescription)"
        }
    }

    /// 地図の運転リプレイ用の replay.csv を、無ければ作り、地図サーバーにまだ送っていなければ送る
    /// (リプレイの機能ができる前に記録した走行のため)
    private func sendReplayIfNeeded() async {
        guard meta.finished, meta.travelMode.hasDriveEval, data?.hasMotion == true else { return }
        let folder = store.dir(meta.id)
        let handheld = meta.travelMode.allowsHandheldEval
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(ReplayExport.fileName).path) {
            let made: Bool = await Task.detached(priority: .utility) {
                (try? ReplayExport.write(folder: folder, handheld: handheld)) != nil
            }.value
            guard made else { return }
        }
        await Uploader.shared.sendReplay(meta.id)
    }

    private func togglePlay(_ d: ReviewData) {
        if playing {
            playing = false
            return
        }
        let end = d.samples.last?.t ?? 0
        // カーソルがあればそこから、最後まで見ていたら最初から
        var t = cursor.flatMap { d.samples.indices.contains($0) ? d.samples[$0].t : nil } ?? playT ?? 0
        if t >= end - 0.5 { t = 0 }
        playT = t
        let i = d.index(atT: t)
        autoCursor = i
        cursor = i
        playing = true
    }

    private func content(_ d: ReviewData) -> some View {
        let t = playing ? playT : nil
        let pos = t.flatMap { d.position(atT: $0) }.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        return VStack(spacing: 0) {
            ReviewMapView(samples: d.samples, events: events, style: settings.mapStyle, cursor: cursor, focus: focus,
                          zoomDownIn: settings.oneFingerZoomDownIn,
                          playPosition: pos, heading: t.flatMap { d.bearing(atT: $0) }, follow: playing && follow,
                          onUserPan: { follow = false }) { i in
                cursor = i
            }
            .frame(maxHeight: .infinity)
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: 6) {
                if meta.travelMode.hasDriveEval, let eval = store.evaluation(meta.id) {
                    ScoreStrip(eval: eval)
                }
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        controls(d)
                        readout(d)
                        if !events.isEmpty { eventChips(d) }
                    }
                    if d.hasMotion {
                        GCircleView(data: d, index: cursor)
                            .frame(width: 84, height: 84)
                    }
                }
                ReviewChart(data: d, series: [ChartSeries(name: "速度", short: "", color: ReviewColors.speed, value: { $0.kmh })],
                            unit: "km/h", guides: [], byDistance: byDistance, events: events, cursor: $cursor,
                            format: { String(format: "%.0f km/h", $0) }, title: "速度")
                    .frame(height: 88)
                if d.hasMotion && d.hasAltitude {
                    Picker("下のグラフ", selection: $lower) {
                        ForEach(ReviewLower.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if d.hasMotion && (lower == .motion || !d.hasAltitude) {
                    ReviewChart(data: d,
                                series: [ChartSeries(name: "横G", short: "横", color: ReviewColors.lat, value: { $0.latG }),
                                         ChartSeries(name: "前後G", short: "前後", color: ReviewColors.lon, value: { $0.lonG })],
                                unit: "G", guides: [DriveEval.harshG, -DriveEval.harshG], byDistance: byDistance, events: events,
                                cursor: $cursor, format: { String(format: "%+.2f", $0) }, title: "前後G・横G")
                        .frame(height: 88)
                    ReviewChart(data: d, series: [ChartSeries(name: "躍度", short: "", color: ReviewColors.jerk, value: { $0.jerk })],
                                unit: "m/s³", guides: [DriveEval.harshJerk], byDistance: byDistance, events: events,
                                cursor: $cursor, format: { String(format: "%.1f m/s³", $0) }, title: "躍度")
                        .frame(height: 76)
                } else if d.hasAltitude {
                    ReviewChart(data: d, series: [ChartSeries(name: "高度", short: "", color: ReviewColors.speed, value: { $0.altM })],
                                unit: "m", guides: [], byDistance: byDistance, events: events, cursor: $cursor,
                                format: { String(format: "%.0f m", $0) }, title: "高度")
                        .frame(height: 88)
                    if !d.altitudeFromPressure {
                        Text("気圧の記録が無いので、GPS の高度です").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// 再生・速さ・追尾
    private func controls(_ d: ReviewData) -> some View {
        HStack(spacing: 8) {
            Button {
                togglePlay(d)
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .frame(width: 30, height: 20)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(playing ? "一時停止" : "再生")
            Menu {
                Picker("再生の速さ", selection: $rate) {
                    ForEach(ReviewView.rates, id: \.self) { r in Text("×\(Int(r))").tag(r) }
                }
            } label: {
                Text("×\(Int(rate))").monospacedDigit().frame(minWidth: 30)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("再生の速さ ×\(Int(rate))")
            Button {
                follow.toggle()
            } label: {
                Label("追尾", systemImage: follow ? "location.fill" : "location")
            }
            .buttonStyle(.bordered)
            .tint(follow ? .purple : .secondary)
            .accessibilityHint("再生中、地図が丸についていきます")
        }
        .font(.subheadline)
        .controlSize(.small)
    }

    /// カーソルの時点の値(カーソルが無ければ、なぞり方の説明)
    private func readout(_ d: ReviewData) -> some View {
        HStack(spacing: 8) {
            if let i = cursor, d.samples.indices.contains(i) {
                let s = d.samples[i]
                Text(Display.time.string(from: Date(timeIntervalSince1970: s.unix))).bold()
                Text(String(format: "%.0f km/h", s.kmh))
                if let g = s.lonG { Text(String(format: "前後%+.2f", g)).foregroundStyle(ReviewColors.lon) }
                if let g = s.latG { Text(String(format: "横%+.2f", g)).foregroundStyle(ReviewColors.lat) }
                if let j = s.jerk { Text(String(format: "躍度%.1f", j)).foregroundStyle(ReviewColors.jerk) }
                if s.lonG == nil, let a = s.altM { Text(String(format: "%.0f m", a)) }
                Spacer(minLength: 0)
                if meta.finished && !playing && i > 0 && i < d.samples.count - 1 {
                    Button {
                        splitAt = Date(timeIntervalSince1970: s.unix)
                    } label: {
                        Label("ここで分ける", systemImage: "scissors").labelStyle(.iconOnly)
                    }
                    .disabled(uploader.isUploading || recorder.isRecording)
                    .accessibilityLabel("ここで記録を分ける")
                }
                Button {
                    playing = false
                    cursor = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("選択を消す")
            } else {
                Text("▶で再生、グラフをなぞるか地図の線をタップ").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(String(format: "%.1f km", d.samples.last?.km ?? 0)).foregroundStyle(.secondary)
            }
        }
        .font(.caption).monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    /// 出来事(押すとその 5 秒前から等倍で再生)
    private func eventChips(_ d: ReviewData) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                    Button {
                        let at = d.index(atUnix: e.tUnix)
                        let t = max(0, d.samples[at].t - 5)
                        let i = d.index(atT: t)
                        rate = 1
                        playT = t
                        autoCursor = i
                        cursor = i
                        focus = at
                        follow = true
                        playing = true
                    } label: {
                        VStack(spacing: 0) {
                            Text(e.kind).font(.caption.bold())
                            Text("\(Display.time.string(from: Date(timeIntervalSince1970: e.tUnix)))・\(EvalStyle.event(e))")
                                .font(.caption2).monospacedDigit()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// G円: 前後G(上が加速)と横G(左に曲がると左)を点で、直近 4 秒を尾で出す。点線の円は急な操作の目安
struct GCircleView: View {
    let data: ReviewData
    let index: Int?

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 9
            let maxG = 0.5
            func p(_ lon: Double, _ lat: Double) -> CGPoint {
                var x = -lat / maxG * r, y = -lon / maxG * r
                let d = (x * x + y * y).squareRoot()
                if d > r { x *= r / d; y *= r / d }
                return CGPoint(x: c.x + x, y: c.y + y)
            }
            for k in 1...5 {
                let rr = r * Double(k) / 5
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                           with: .color(.secondary.opacity(0.25)), lineWidth: 0.6)
            }
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - r, y: c.y)); cross.addLine(to: CGPoint(x: c.x + r, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: c.y - r)); cross.addLine(to: CGPoint(x: c.x, y: c.y + r))
            ctx.stroke(cross, with: .color(.secondary.opacity(0.25)), lineWidth: 0.6)
            let hr = r * DriveEval.harshG / maxG
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - hr, y: c.y - hr, width: hr * 2, height: hr * 2)),
                       with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            ctx.draw(Text("加速").font(.system(size: 7)).foregroundColor(.secondary), at: CGPoint(x: c.x, y: 4))
            ctx.draw(Text("減速").font(.system(size: 7)).foregroundColor(.secondary), at: CGPoint(x: c.x, y: size.height - 4))

            guard let i = index, data.samples.indices.contains(i),
                  let lon = data.samples[i].lonG, let lat = data.samples[i].latG else { return }
            let now = data.samples[i].t
            var k = i
            while k > 0 && now - data.samples[k - 1].t <= 4 { k -= 1 }
            if k < i {
                var trail = Path()
                var started = false
                for s in data.samples[k...i] {
                    guard let a = s.lonG, let b = s.latG else { continue }
                    if started { trail.addLine(to: p(a, b)) } else { trail.move(to: p(a, b)); started = true }
                }
                ctx.stroke(trail, with: .color(ReviewColors.lon.opacity(0.45)), lineWidth: 1.5)
            }
            let q = p(lon, lat)
            let over = max(abs(lon), abs(lat)) > DriveEval.harshG
            let dot = Path(ellipseIn: CGRect(x: q.x - 4.5, y: q.y - 4.5, width: 9, height: 9))
            ctx.fill(dot, with: .color(over ? .orange : ReviewColors.lon))
            ctx.stroke(dot, with: .color(.white), lineWidth: 1.5)
        }
        .accessibilityLabel("G円")
    }
}

/// 総合点と 5 項目を 1 行で
struct ScoreStrip: View {
    let eval: Evaluation

    static let short: [String: String] = ["sick": "酔い", "jerk": "躍度", "harsh": "急操作", "stop": "止まり際", "curve": "カーブ"]

    var body: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(String(format: "%.0f", eval.score)).font(.title3.bold()).monospacedDigit()
                    .foregroundStyle(EvalStyle.color(eval.score))
                Text("点").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(eval.items, id: \.key) { item in
                VStack(spacing: 0) {
                    Text(ScoreStrip.short[item.key] ?? item.name).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(String(format: "%.0f", item.score)).font(.caption.bold()).monospacedDigit()
                        .foregroundStyle(EvalStyle.color(item.score))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// グラフの 1 本の線
struct ChartSeries {
    let name: String
    /// カーソルの値の前に付ける短い名前(線が 1 本なら空)
    let short: String
    let color: Color
    let value: (ReviewSample) -> Double?
}

/// 1 段のグラフ(線は 1 本か、重ねて数本)。指でなぞるとカーソルが動く
struct ReviewChart: View {
    let data: ReviewData
    let series: [ChartSeries]
    let unit: String
    let guides: [Double]
    let byDistance: Bool
    let events: [EvalEvent]
    @Binding var cursor: Int?
    let format: (Double) -> String
    let title: String

    private func x(_ s: ReviewSample) -> Double { byDistance ? s.km : s.t / 60 }

    /// 横軸の範囲(走行の最初から最後まで。カーソルや出来事の線で広がらないよう固定する)
    private var xDomain: ClosedRange<Double> {
        let hi = data.samples.last.map(x) ?? 1
        return 0...max(hi, 0.01)
    }

    /// 縦軸の範囲(値と目安の線が収まる幅。少し余白を付ける)
    private func yDomain(_ ys: [Double]) -> ClosedRange<Double> {
        var lo = min(ys.min() ?? 0, guides.min() ?? .infinity)
        var hi = max(ys.max() ?? 1, guides.max() ?? -.infinity)
        if lo >= 0 && lo < (hi - lo) * 0.5 { lo = 0 } // 速度や高度は 0 から
        if hi - lo < 1e-6 { hi = lo + 1 }
        let pad = (hi - lo) * 0.05
        return (lo == 0 ? 0 : lo - pad)...(hi + pad)
    }

    /// カーソルの時点の値(グラフの左上の見出しに出す)
    private var cursorText: String {
        guard let i = cursor, data.samples.indices.contains(i) else { return "" }
        let parts = series.compactMap { sr in sr.value(data.samples[i]).map { sr.short + format($0) } }
        return parts.isEmpty ? "" : "  " + parts.joined(separator: " ")
    }

    private struct Pt {
        let k: Int
        let x: Double
        let y: Double
    }

    var body: some View {
        let pts: [Pt] = series.indices.flatMap { k in
            data.samples.compactMap { s in series[k].value(s).map { Pt(k: k, x: x(s), y: $0) } }
        }
        let eventXs = events.map { e -> Double in
            let i = data.index(atUnix: e.tUnix)
            return x(data.samples[i])
        }
        Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value(byDistance ? "km" : "分", p.x), y: .value(unit, p.y), series: .value("系列", p.k))
                    .foregroundStyle(series[p.k].color)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            ForEach(guides, id: \.self) { g in
                RuleMark(y: .value("目安", g))
                    .foregroundStyle(Color.orange.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }
            ForEach(Array(eventXs.enumerated()), id: \.offset) { _, ex in
                RuleMark(x: .value("出来事", ex))
                    .foregroundStyle(Color.orange.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            if let i = cursor, data.samples.indices.contains(i) {
                RuleMark(x: .value("選択", x(data.samples[i])))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain(pts.map(\.y)))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(byDistance ? String(format: "%.0fkm", d) : String(format: "%.0f分", d)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                let plot = geo[proxy.plotAreaFrame]
                                // グラフの外まで指が出ても、端の点に留める
                                let px = min(max(g.location.x - plot.origin.x, 0), plot.width)
                                guard let xv: Double = proxy.value(atX: px) else { return }
                                cursor = byDistance ? data.index(atKm: xv) : data.index(atT: xv * 60)
                            }
                    )
            }
        }
        .overlay(alignment: .topLeading) {
            (Text("\(title)(\(unit))").foregroundColor(.secondary)
                + Text(cursorText).bold().foregroundColor(.primary))
                .font(.caption2).monospacedDigit()
                .padding(.leading, 28)
                .allowsHitTesting(false)
        }
    }
}

/// 記録を分ける確認(前半と後半の移動手段を選ぶ)
struct SplitSheet: View {
    let meta: SessionMeta
    let at: Date
    let onDone: () -> Void
    @EnvironmentObject var store: LogStore
    @EnvironmentObject var uploader: Uploader
    @Environment(\.dismiss) private var dismiss
    @State private var modeA: TravelMode
    @State private var modeB: TravelMode
    @State private var working = false
    @State private var error: String?

    init(meta: SessionMeta, at: Date, onDone: @escaping () -> Void) {
        self.meta = meta
        self.at = at
        self.onDone = onDone
        _modeA = State(initialValue: meta.travelMode)
        // 後半ははじめ「その他」(歩いた、など)。違えば選び直す
        _modeB = State(initialValue: meta.travelMode == .other ? .car : .other)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("移動手段", selection: $modeA) {
                        ForEach(TravelMode.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                } header: {
                    Text("前半 \(Display.time.string(from: meta.start))〜\(Display.time.string(from: at))")
                }
                Section {
                    Picker("移動手段", selection: $modeB) {
                        ForEach(TravelMode.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                } header: {
                    Text("後半 \(Display.time.string(from: at))〜\(meta.end.map { Display.time.string(from: $0) } ?? "")")
                } footer: {
                    Text("後半は \(Fmt.sessionID.string(from: at)) の別の記録になります。運転評価は前半・後半それぞれで計算し直します。"
                         + (meta.gpxSent || !meta.rawSent.isEmpty ? "地図サーバーに送ってある記録は、次に送るときに分けたものに置き換えます(車の部分だけが国道の制覇に入ります)。" : ""))
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        split()
                    } label: {
                        HStack {
                            Text("ここで分ける")
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(working)
                }
            }
            .navigationTitle("記録を分ける")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }.disabled(working)
                }
            }
        }
        .interactiveDismissDisabled(working)
    }

    private func split() {
        working = true
        error = nil
        store.split(meta.id, at: at, modeA: modeA, modeB: modeB) { result in
            working = false
            switch result {
            case .success:
                if AppSettings.shared.autoUpload && uploader.canAutoSend { uploader.uploadPending() }
                onDone()
            case .failure(let e):
                error = e.localizedDescription
            }
        }
    }
}
