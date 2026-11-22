import SwiftUI

// 運転評価の表示(記録画面・ログの一覧・ログの詳細で使う)

enum EvalStyle {
    /// 点数の色(80 点以上は緑、60 点以上は黄、それより下はオレンジ)
    static func color(_ score: Double) -> Color {
        score >= 80 ? .green : score >= 60 ? .yellow : .orange
    }

    /// 項目ごとの、点数を上げるためのひとこと
    static let tips: [String: String] = [
        "sick": "加速もブレーキも、ゆっくり踏んでゆっくり戻す",
        "jerk": "ペダルとハンドルを急に動かさない",
        "harsh": "早めに気づいて早めに減速し、急な操作を減らす",
        "stop": "止まる直前にブレーキを少しゆるめる(カックンを防ぐ)",
        "curve": "カーブの手前で減速を終え、曲がりながら強く踏まない",
    ]

    static func value(_ item: EvalItem) -> String {
        switch item.key {
        case "harsh": return String(format: "%.1f 回/10分", item.value)
        case "sick": return String(format: "%.2f m/s²", item.value)
        default: return String(format: "%.2f m/s³", item.value)
        }
    }

    static func event(_ e: EvalEvent) -> String {
        e.unit == "G" ? String(format: "%.2f G", e.value) : String(format: "%.1f %@", e.value, e.unit)
    }
}

/// 区間ごとの採点(カーブ・停止・発進)の表示
enum SegStyle {
    struct Kind: Hashable {
        var key: String
        var title: String
    }

    static let groups = [Kind(key: "curve", title: "カーブ"), Kind(key: "stop", title: "停止"), Kind(key: "start", title: "発進")]

    /// 項目の点数の印(◎ 90〜、○ 70〜、△ 50〜、×)。スキンと同じ
    static func mark(_ score: Double) -> String {
        score >= 90 ? "◎" : score >= 70 ? "○" : score >= 50 ? "△" : "×"
    }

    /// 「小ささ○ ゆっくり◎ 一筆△」
    static func marks(_ s: EvalSegment) -> String {
        s.items.map { "\($0.name)\(mark($0.score))" }.joined(separator: " ")
    }

    /// いちばん強かった G(「横G 0.28G」など)
    static func strength(_ s: EvalSegment) -> String {
        let label = s.group == "curve" ? "横G" : s.kind == "stop" ? "減速" : "加速"
        return label + String(format: " %.2fG", s.items.first?.value ?? 0)
    }

    /// 項目ごとの、点数を上げるためのひとこと
    static let tips: [String: String] = [
        "curve/size": "カーブの手前で、もう少し速度を落とす",
        "curve/slow": "ハンドルはゆっくり切って、ゆっくり戻す",
        "curve/stroke": "ブレーキを少し残したまま曲がり始め、Gを途切れさせない",
        "stop/size": "早めにブレーキを始めて、弱く長く減速する",
        "stop/onset": "ブレーキはそっと踏み始める",
        "stop/stop": "止まる直前にブレーキを少しゆるめる",
        "start/size": "アクセルを控えめにして、ゆっくり速度を上げる",
        "start/onset": "アクセルはそっと踏み始める",
    ]

    static func tip(_ s: EvalSegment) -> String? {
        guard let worst = s.items.min(by: { $0.score < $1.score }), worst.score < 70 else { return nil }
        return tips["\(s.group)/\(worst.key)"]
    }
}

/// 点数の丸いバッジ
struct ScoreBadge: View {
    let score: Double
    var body: some View {
        Text(String(format: "%.0f", score))
            .font(.caption.bold()).monospacedDigit()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(EvalStyle.color(score).opacity(0.25), in: Capsule())
            .accessibilityLabel("運転の点数 \(Int(score.rounded()))点")
    }
}

/// 点数と 5 項目(一番低い項目には、上げるためのひとことを付ける)
struct EvalSummary: View {
    let eval: Evaluation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.0f", eval.score))
                    .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(EvalStyle.color(eval.score))
                Text("点").foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing) {
                    Text("急な操作など \(eval.events.count) 回").font(.caption)
                    Text("停止 \(eval.stops) 回・走行 \(Display.duration(eval.movingS))").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            ForEach(eval.items, id: \.key) { item in
                HStack(spacing: 8) {
                    Text(item.name).font(.subheadline).frame(width: 104, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(EvalStyle.color(item.score))
                                .frame(width: g.size.width * max(0, min(1, item.score / 100)))
                        }
                    }
                    .frame(height: 8)
                    Text(String(format: "%.0f", item.score)).font(.subheadline).monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
            }
            if let worst = eval.items.min(by: { $0.score < $1.score }), worst.score < 80,
               let tip = EvalStyle.tips[worst.key] {
                Label("\(worst.name): \(tip)", systemImage: "lightbulb")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if eval.mount == "hand" {
                let r = eval.usableRatio ?? 0
                Label(String(format: "手持ちで記録(参考値)・採点に使えた時間 %.0f%%", r * 100), systemImage: "hand.raised")
                    .font(.footnote).foregroundStyle(r < 0.5 ? .orange : .secondary)
                if r < 0.5 {
                    Text("端末を動かした時間が長く、躍度・急な操作・止まり際・カーブの確かさが下がります")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if eval.mount == "fixed" {
                Label("端末を固定して記録(同乗)", systemImage: "iphone")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if eval.mount != "hand", let q = eval.axesQuality, q < 0.5 {
                Label("端末の固定が甘かったかもしれません(点数の確かさが下がります)", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }
}

/// ログの詳細に出す評価の欄。まだ無ければ計算する
struct EvalSection: View {
    let id: String
    let finished: Bool
    @EnvironmentObject var store: LogStore
    @State private var computing = false
    @State private var failed = false

    var body: some View {
        if let eval = store.evaluation(id) {
            Section("運転の評価") {
                EvalSummary(eval: eval).padding(.vertical, 4)
                ForEach(eval.items, id: \.key) { item in
                    LabeledContent(item.name, value: EvalStyle.value(item))
                }
            }
            if let segs = eval.segments, !segs.isEmpty {
                SegmentSection(id: id, eval: eval, segments: segs)
            }
            if !eval.events.isEmpty {
                Section("点数を下げた出来事") {
                    ForEach(Array(eval.events.enumerated()), id: \.offset) { _, e in
                        LabeledContent {
                            Text("\(EvalStyle.event(e))・\(String(format: "%.0f", e.kmh)) km/h")
                        } label: {
                            VStack(alignment: .leading) {
                                Text(e.kind)
                                Text(Display.time.string(from: Date(timeIntervalSince1970: e.tUnix)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } else if finished {
            Section("運転の評価") {
                if computing {
                    HStack { ProgressView(); Text("計算しています…").foregroundStyle(.secondary) }
                } else if failed {
                    Text("評価できませんでした(短すぎる・データが足りないなど)").foregroundStyle(.secondary)
                } else {
                    Button("評価する") { compute() }
                }
            }
            .onAppear { if !computing && !failed { compute() } }
        }
    }

    private func compute() {
        computing = true
        store.evaluate(id) { e in
            computing = false
            failed = e == nil
        }
    }
}

/// カーブ・停止・発進ごとの採点: 種類ごとの回数と平均点、点数の低い場面 3 つ(押すとその場面から振り返る)
struct SegmentSection: View {
    let id: String
    let eval: Evaluation
    let segments: [EvalSegment]

    /// 点数の低い順に 3 つ(同じ点数なら早い順)
    private var worst: [EvalSegment] {
        let sorted = segments.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score < b.element.score : a.offset < b.offset
        }
        return sorted.prefix(3).map { $0.element }
    }

    var body: some View {
        Section {
            ForEach(SegStyle.groups, id: \.self) { g in
                if let st = eval.segmentStats?[g.key], st.count > 0 {
                    LabeledContent(g.title) {
                        HStack(spacing: 6) {
                            Text("\(st.count)回").foregroundStyle(.secondary)
                            if let sc = st.score {
                                Text("平均 \(String(format: "%.0f", sc))点").bold().foregroundStyle(EvalStyle.color(sc))
                            }
                        }
                        .monospacedDigit()
                    }
                }
            }
            ForEach(Array(worst.enumerated()), id: \.offset) { _, s in
                NavigationLink(value: LogRoute.reviewAt(id, s.tUnix)) {
                    SegmentRow(segment: s)
                }
            }
        } header: {
            Text("カーブ・停止・発進ごと")
        } footer: {
            Text("下の 3 つは点数の低い場面です。押すとその場面から振り返りを再生します。区間の点数は総合点には入りません")
        }
    }
}

/// 区間 1 つの行(名前・点数・時刻・項目の印・ひとこと)
struct SegmentRow: View {
    let segment: EvalSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(segment.name).bold()
                Text(String(format: "%.0f点", segment.score)).bold().monospacedDigit()
                    .foregroundStyle(EvalStyle.color(segment.score))
                Spacer()
                Text(Display.time.string(from: Date(timeIntervalSince1970: segment.tUnix)))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("\(SegStyle.marks(segment))・\(SegStyle.strength(segment))")
                .font(.caption).monospacedDigit()
            if let tip = SegStyle.tip(segment) {
                Label(tip, systemImage: "lightbulb").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 記録中のサポート

/// 記録中に出す、G の点・直近 5 分の点数・出来事の回数
struct CoachPanel: View {
    let state: CoachState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            GDot(lonG: state.lonG, latG: state.latG, ready: state.ready)
                .frame(width: 104, height: 104)
            VStack(alignment: .leading, spacing: 4) {
                if !state.ready {
                    Text("車の向きを合わせています").font(.subheadline.bold())
                    ProgressView(value: state.progress)
                    Text("ふつうに走りだせば、1〜2分で合います").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("直近5分").font(.caption).foregroundStyle(.secondary)
                        if let s = state.recentScore {
                            Text(String(format: "%.0f", s))
                                .font(.title.bold()).monospacedDigit()
                                .foregroundStyle(EvalStyle.color(s))
                            Text("点").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("走行中に出ます").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let key = state.recentWorst, let tip = EvalStyle.tips[key] {
                        Text(tip).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    countsRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var countsRow: some View {
        let total = state.counts.values.reduce(0, +)
        let parts = CoachEvent.allCases.compactMap { e in state.counts[e].map { "\(e.rawValue) \($0)" } }
        return VStack(alignment: .leading, spacing: 2) {
            Text(total == 0 ? "急な操作 0 回" : parts.joined(separator: "・"))
                .font(.caption.bold()).monospacedDigit()
            if let last = state.last, Date().timeIntervalSince(last.at) < 8 {
                Text("いま: \(last.event.rawValue)").font(.caption.bold()).foregroundStyle(.orange)
            }
            // 直前のカーブ・停止・発進の点数(終わってから 3 秒だけ。音は鳴らさない)
            if let seg = state.lastSegment, Date().timeIntervalSince(seg.at) < LiveCoach.segShowS {
                Text("\(seg.segment.name) \(String(format: "%.0f", seg.segment.score))点・\(SegStyle.marks(seg.segment))")
                    .font(.caption.bold()).monospacedDigit()
                    .foregroundStyle(EvalStyle.color(seg.segment.score))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
}

/// G の点。上が減速、下が加速、左右は体が押される向き。内側の円が 0.15G、外側が急な操作の境目(DriveEval.harshG)
struct GDot: View {
    let lonG: Double
    let latG: Double
    let ready: Bool
    static let fullG = 0.4

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let mag = (lonG * lonG + latG * latG).squareRoot()
            let k = mag > GDot.fullG ? GDot.fullG / mag : 1
            let p = CGPoint(x: c.x + CGFloat(latG * k / GDot.fullG) * r,
                            y: c.y + CGFloat(lonG * k / GDot.fullG) * r)
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 1)
                Circle().stroke(Color.orange.opacity(0.6), lineWidth: 1.5)
                    .frame(width: r * 2 * DriveEval.harshG / GDot.fullG, height: r * 2 * DriveEval.harshG / GDot.fullG)
                Circle().stroke(Color.green.opacity(0.6), lineWidth: 1.5)
                    .frame(width: r * 2 * 0.15 / GDot.fullG, height: r * 2 * 0.15 / GDot.fullG)
                Path { path in
                    path.move(to: CGPoint(x: c.x - r, y: c.y)); path.addLine(to: CGPoint(x: c.x + r, y: c.y))
                    path.move(to: CGPoint(x: c.x, y: c.y - r)); path.addLine(to: CGPoint(x: c.x, y: c.y + r))
                }
                .stroke(.quaternary, lineWidth: 0.5)
                if ready {
                    Circle().fill(mag >= DriveEval.harshG ? Color.red : mag >= 0.15 ? Color.yellow : Color.green)
                        .frame(width: 16, height: 16)
                        .position(p)
                        .animation(.linear(duration: 0.2), value: lonG)
                }
            }
        }
        .accessibilityLabel(ready ? String(format: "前後 %.2f G、左右 %.2f G", lonG, latG) : "向き合わせ中")
    }
}
