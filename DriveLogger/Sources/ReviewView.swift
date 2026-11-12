import Charts
import SwiftUI

/// 下の段のグラフで見るもの
enum ReviewMetric: String, CaseIterable, Identifiable {
    case altitude, lonG, latG, jerk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .altitude: return "高度"
        case .lonG: return "前後G"
        case .latG: return "横G"
        case .jerk: return "躍度"
        }
    }

    var unit: String {
        switch self {
        case .altitude: return "m"
        case .lonG, .latG: return "G"
        case .jerk: return "m/s³"
        }
    }

    var needsMotion: Bool { self != .altitude }

    func value(_ s: ReviewSample) -> Double? {
        switch self {
        case .altitude: return s.altM
        case .lonG: return s.lonG
        case .latG: return s.latG
        case .jerk: return s.jerk
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .altitude: return String(format: "%.0f m", v)
        case .lonG, .latG: return String(format: "%+.2f G", v)
        case .jerk: return String(format: "%.1f m/s³", v)
        }
    }

    /// 目安の線(急な操作の 0.3G、躍度の 4 m/s³)
    var guides: [Double] {
        switch self {
        case .altitude: return []
        case .lonG, .latG: return [DriveEval.harshG, -DriveEval.harshG]
        case .jerk: return [DriveEval.harshJerk]
        }
    }
}

/// 地図とグラフで走行を振り返る画面。グラフをなぞると地図の丸が動き、地図の軌跡をタップするとグラフのカーソルが動く
struct ReviewView: View {
    let meta: SessionMeta
    @EnvironmentObject var store: LogStore
    @EnvironmentObject var settings: AppSettings

    @State private var data: ReviewData?
    @State private var failed: String?
    @State private var cursor: Int?
    @State private var focus: Int?
    @State private var metric: ReviewMetric = .altitude
    @State private var byDistance = false

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
            // 地図サーバーがトンネルの区間を補っていれば受け取り、読み直す
            let folder = store.dir(meta.id)
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(ReviewLoader.filledFile).path),
               await Uploader.shared.fetchFilled(meta) {
                await load(force: true)
            }
        }
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
            if !d.hasAltitude && d.hasMotion { metric = .lonG }
            if d.samples.count < 2 { failed = "位置の記録が少なすぎて表示できません" }
        case .failure(let e):
            failed = "ログを読めませんでした: \(e.localizedDescription)"
        }
    }

    private func metrics(_ d: ReviewData) -> [ReviewMetric] {
        ReviewMetric.allCases.filter { m in m.needsMotion ? d.hasMotion : d.hasAltitude }
    }

    private func content(_ d: ReviewData) -> some View {
        VStack(spacing: 0) {
            ReviewMapView(samples: d.samples, events: events, style: settings.mapStyle, cursor: cursor, focus: focus,
                          zoomDownIn: settings.oneFingerZoomDownIn) { i in
                cursor = i
            }
            .frame(maxHeight: .infinity)
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: 6) {
                if meta.travelMode.hasDriveEval, let eval = store.evaluation(meta.id) {
                    ScoreStrip(eval: eval)
                }
                readout(d)
                if !events.isEmpty { eventChips(d) }
                ReviewChart(data: d, value: { $0.kmh }, unit: "km/h", guides: [], byDistance: byDistance,
                            events: events, cursor: $cursor, format: { String(format: "%.0f km/h", $0) }, title: "速度")
                    .frame(height: 110)
                let ms = metrics(d)
                if !ms.isEmpty {
                    Picker("下のグラフ", selection: $metric) {
                        ForEach(ms) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    let m = ms.contains(metric) ? metric : ms[0]
                    ReviewChart(data: d, value: { m.value($0) }, unit: m.unit, guides: m.guides, byDistance: byDistance,
                                events: events, cursor: $cursor, format: m.format, title: m.title)
                        .frame(height: 110)
                    if m == .altitude && !d.altitudeFromPressure {
                        Text("気圧の記録が無いので、GPS の高度です").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// カーソルの時点の値(カーソルが無ければ、なぞり方の説明)
    private func readout(_ d: ReviewData) -> some View {
        HStack(spacing: 10) {
            if let i = cursor, d.samples.indices.contains(i) {
                let s = d.samples[i]
                Text(Display.time.string(from: Date(timeIntervalSince1970: s.unix))).bold()
                Text(String(format: "%.0f km/h", s.kmh))
                if let a = s.altM { Text(String(format: "%.0f m", a)) }
                if let g = s.lonG { Text(String(format: "前後%+.2f", g)) }
                if let g = s.latG { Text(String(format: "横%+.2f", g)) }
                Spacer(minLength: 0)
                Button {
                    cursor = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("選択を消す")
            } else {
                Text("グラフをなぞるか、地図の線をタップ").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(String(format: "%.1f km", d.samples.last?.km ?? 0)).foregroundStyle(.secondary)
            }
        }
        .font(.caption).monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// 出来事(押すとその場面へ)
    private func eventChips(_ d: ReviewData) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                    Button {
                        let i = d.index(atUnix: e.tUnix)
                        cursor = i
                        focus = i
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

/// 1 段のグラフ。指でなぞるとカーソルが動く
struct ReviewChart: View {
    let data: ReviewData
    let value: (ReviewSample) -> Double?
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
        guard let i = cursor, data.samples.indices.contains(i), let v = value(data.samples[i]) else { return "" }
        return "  " + format(v)
    }

    var body: some View {
        let pts = data.samples.compactMap { s in value(s).map { (x: x(s), y: $0) } }
        let eventXs = events.map { e -> Double in
            let i = data.index(atUnix: e.tUnix)
            return x(data.samples[i])
        }
        Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value(byDistance ? "km" : "分", p.x), y: .value(unit, p.y))
                    .foregroundStyle(Color.accentColor)
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
                    .foregroundStyle(Color.purple)
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
                + Text(cursorText).bold().foregroundColor(.purple))
                .font(.caption2).monospacedDigit()
                .padding(.leading, 28)
                .allowsHitTesting(false)
        }
    }
}
