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
            if let q = eval.axesQuality, q < 0.5 {
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
