import SwiftUI

/// ログ画面の行き先
enum LogRoute: Hashable {
    case allDays
    case day(String) // yyyy-MM-dd(開始時刻のローカル日付)
    case detail(String) // 走行ID
    case review(String) // 走行ID(地図とグラフで振り返る)
}

struct LogsView: View {
    static let recentCount = 5

    @EnvironmentObject var store: LogStore
    @EnvironmentObject var uploader: Uploader
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        uploader.uploadPending(manual: true)
                    } label: {
                        Label(uploader.isUploading ? "送信中…" : "未送信のログを送る(\(store.unsent.count)件)",
                              systemImage: "arrow.up.circle")
                    }
                    .disabled(uploader.isUploading || recorder.isRecording || store.unsent.isEmpty)
                    if let message = uploader.lastMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("最新") {
                    SessionRows(sessions: Array(store.sessions.prefix(LogsView.recentCount)))
                }
                Section {
                    NavigationLink(value: LogRoute.allDays) {
                        LabeledContent("すべてのログ", value: "\(store.sessions.count)件")
                    }
                }
            }
            .navigationTitle("ログ")
            .navigationDestination(for: LogRoute.self) { route in
                switch route {
                case .allDays: AllDaysView()
                case .day(let key): DayLogsView(dayKey: key)
                case .detail(let id): LogDetailView(id: id)
                case .review(let id): ReviewRoute(id: id)
                }
            }
            .refreshable { store.reload() }
        }
    }
}

/// 走行の行を並べる。押すと詳細、左にスワイプで削除(記録中のものは消せない)
struct SessionRows: View {
    let sessions: [SessionMeta]
    @EnvironmentObject var store: LogStore

    var body: some View {
        ForEach(sessions) { meta in
            NavigationLink(value: LogRoute.detail(meta.id)) { SessionRow(meta: meta) }
                .deleteDisabled(!meta.finished)
        }
        .onDelete { offsets in
            for i in offsets where sessions[i].finished { store.delete(sessions[i].id) }
        }
    }
}

/// 日付の一覧(新しい日付が上)
struct AllDaysView: View {
    @EnvironmentObject var store: LogStore

    struct Day: Identifiable {
        let id: String // yyyy-MM-dd
        let date: Date
        let count: Int
        let distanceM: Double
        let hasUnsent: Bool
    }

    private var days: [Day] {
        let unsent = Set(store.unsent.map(\.id))
        let groups = Dictionary(grouping: store.sessions) { Display.dayKey.string(from: $0.start) }
        return groups.map { key, list in
            Day(id: key, date: list.map(\.start).min() ?? Date(), count: list.count,
                distanceM: list.reduce(0) { $0 + $1.distanceM },
                hasUnsent: list.contains { unsent.contains($0.id) || !$0.finished })
        }
        .sorted { $0.id > $1.id }
    }

    var body: some View {
        List(days) { day in
            NavigationLink(value: LogRoute.day(day.id)) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Display.day.string(from: day.date)).font(.headline)
                        Text("\(day.count)件・合計 \(Display.km(day.distanceM))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if day.hasUnsent {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            .accessibilityLabel("未送信あり")
                    }
                }
            }
        }
        .overlay { if days.isEmpty { Text("ログはまだありません").foregroundStyle(.secondary) } }
        .navigationTitle("すべてのログ")
        .refreshable { store.reload() }
    }
}

/// 1日分の走行の一覧
struct DayLogsView: View {
    let dayKey: String
    @EnvironmentObject var store: LogStore

    var body: some View {
        let list = store.sessions.filter { Display.dayKey.string(from: $0.start) == dayKey }
        List {
            SessionRows(sessions: list)
        }
        .overlay { if list.isEmpty { Text("この日のログはありません").foregroundStyle(.secondary) } }
        .navigationTitle(list.first.map { Display.day.string(from: $0.start) } ?? dayKey)
        .refreshable { store.reload() }
    }
}

struct SessionRow: View {
    let meta: SessionMeta
    @EnvironmentObject var store: LogStore

    var body: some View {
        row(meta)
    }

    private func row(_ meta: SessionMeta) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !meta.travelMode.isCar {
                    Image(systemName: meta.travelMode.systemImage).foregroundStyle(.teal)
                        .accessibilityLabel(meta.travelMode.title)
                }
                Text(Display.date.string(from: meta.start)).font(.headline)
                if meta.travelMode.isCar, let e = store.evaluation(meta.id) { ScoreBadge(score: e.score) }
                Spacer()
                status(meta)
            }
            Text("\(Display.km(meta.distanceM))・\(Display.duration(meta.durationS))・目印 \(meta.markers.count)")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func status(_ meta: SessionMeta) -> some View {
        if !meta.finished {
            Text("記録中").font(.caption.bold()).foregroundStyle(.red)
        } else if LogStore.allSent(meta) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if meta.gpxSent {
            Text("生データ未送信").font(.caption).foregroundStyle(.orange)
        } else {
            Text("未送信").font(.caption).foregroundStyle(.orange)
        }
    }
}

struct LogDetailView: View {
    let id: String
    @EnvironmentObject var store: LogStore

    var body: some View {
        let meta = store.sessions.first { $0.id == id }
        let dir = store.dir(id)
        let files = ["track.gpx", "location.csv", "motion.csv", "pressure.csv", "evaluation.json", DriveWeather.fileName, "meta.json"]
        List {
            if let meta {
                if meta.finished && meta.points >= 2 {
                    Section {
                        NavigationLink(value: LogRoute.review(meta.id)) {
                            Label("地図とグラフで振り返る", systemImage: "chart.xyaxis.line")
                        }
                    }
                }
                Section("概要") {
                    LabeledContent("移動手段") {
                        Label(meta.travelMode.title, systemImage: meta.travelMode.systemImage)
                    }
                    LabeledContent("開始", value: Display.date.string(from: meta.start))
                    LabeledContent("距離", value: Display.km(meta.distanceM))
                    LabeledContent("時間", value: Display.duration(meta.durationS))
                    LabeledContent("最高速度", value: "\(Display.kmh(meta.maxSpeedMS)) km/h")
                    if let alt = meta.maxAltitudeM {
                        LabeledContent("最高高度(GPS)", value: String(format: "%.0f m", alt))
                    }
                    LabeledContent("位置の点数", value: "\(meta.points)")
                    LabeledContent("端末", value: "\(meta.device) / iOS \(meta.systemVersion)")
                }
                if meta.finished && meta.travelMode != .plane {
                    WeatherSection(meta: meta)
                }
                if meta.travelMode.isCar {
                    EvalSection(id: meta.id, finished: meta.finished)
                } else {
                    Section {
                        Text("\(meta.travelMode.title)の記録は地図に送らず、生データだけを Google ドライブの _drivelog\\trips に送ります")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !meta.markers.isEmpty {
                    Section("目印") {
                        ForEach(meta.markers, id: \.self) { m in
                            LabeledContent(m.kind == "sync" ? "同期" : "目印",
                                           value: Fmt.iso.string(from: m.time))
                        }
                    }
                }
            }
            Section("ファイル") {
                ForEach(files, id: \.self) { name in
                    let url = dir.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: url.path) {
                        ShareLink(item: url) {
                            LabeledContent(name, value: size(url))
                        }
                    }
                }
            }
        }
        .navigationTitle(id)
    }

    private func size(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// 走ったときの天気。地図サーバーが走り終えたあとに取ったものを、ログを開いたときに受け取る
struct WeatherSection: View {
    let meta: SessionMeta
    @EnvironmentObject var store: LogStore
    @State private var weather: DriveWeather?
    @State private var loading = true
    @State private var showAll = false

    var body: some View {
        Section {
            if let w = weather {
                let s = w.summary
                Text(WeatherText.headline(s)).font(.headline)
                if let p = s.precipMax, p > 0 {
                    LabeledContent("雨(1時間の最大)", value: String(format: "%.1f mm", p))
                }
                if let wind = s.windMax {
                    LabeledContent("風(最大)", value: String(format: "%.0f m/s", wind) + (s.gustMax.map { String(format: "(瞬間 %.0f)", $0) } ?? ""))
                }
                if let rise = s.sunrise, let set = s.sunset {
                    LabeledContent("日の出・日の入り", value: "\(Display.time.string(from: Date(timeIntervalSince1970: rise)))・\(Display.time.string(from: Date(timeIntervalSince1970: set)))")
                }
                DisclosureGroup("\(w.samples.count) 地点の天気", isExpanded: $showAll) {
                    ForEach(Array(w.samples.enumerated()), id: \.offset) { _, x in
                        LabeledContent {
                            Text("\(WeatherText.temp(x.temp))・\(WeatherText.wind(x))" + ((x.precip ?? 0) > 0 ? String(format: "・雨 %.1f mm", x.precip!) : ""))
                        } label: {
                            VStack(alignment: .leading) {
                                Text("\(x.icon) \(x.label)")
                                Text(Display.time.string(from: Date(timeIntervalSince1970: x.t)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if loading {
                HStack { ProgressView(); Text("天気を確かめています…").foregroundStyle(.secondary) }
            } else {
                Text(meta.rawSent.contains("meta.json")
                     ? "地図サーバーがまだ天気を取っていません(取れたら、次に開いたときに出ます)"
                     : "地図サーバーに送ると、走ったときの天気を取ってきます")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("天気")
        } footer: {
            if weather != nil {
                Text("Open-Meteo の気象モデルの値です(観測所の実測ではありません)")
            }
        }
        .task(id: meta.rawSent.count) {
            let folder = store.dir(meta.id)
            weather = DriveWeather.load(folder: folder)
            if weather == nil, await Uploader.shared.fetchWeather(meta) {
                weather = DriveWeather.load(folder: folder)
            }
            loading = false
        }
    }
}

/// 振り返り画面(走行IDから開く)
struct ReviewRoute: View {
    let id: String
    @EnvironmentObject var store: LogStore

    var body: some View {
        if let meta = store.sessions.first(where: { $0.id == id }) {
            ReviewView(meta: meta).toolbar(.hidden, for: .tabBar)
        } else {
            Text("ログが見つかりません").foregroundStyle(.secondary)
        }
    }
}

/// 車以外の移動のまとめ(距離・時間・最高速度・最高高度)
struct TripSummary: View {
    let meta: SessionMeta

    var body: some View {
        HStack {
            item("距離", Display.km(meta.distanceM))
            item("時間", Display.duration(meta.durationS))
            item("最高速度", "\(Display.kmh(meta.maxSpeedMS)) km/h")
            item("最高高度", meta.maxAltitudeM.map { String(format: "%.0fm", $0) } ?? "-")
        }
    }

    private func item(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}
