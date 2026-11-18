import Foundation
import MetricKit

/// アプリが落ちた・固まったときに iOS が次の起動で渡してくれる診断(MetricKit。落ちた理由と、そのときの処理の場所)を保存する。
/// 端末の設定の「解析データ」を探さなくても原因を調べられるようにするため。
/// - いちばん新しい(記録中のものを除く)走行のフォルダに diagnostics_<受け取った時刻>.json として置き、
///   その走行の生データと一緒に地図サーバー(_drivelog)へ送る
/// - 走行が無ければ Documents/diagnostics/ に置く(ファイル App の「このiPhone内」から見られる)
final class Diagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = Diagnostics()
    static let prefix = "diagnostics_"

    private var started = false

    /// メインスレッドで呼ぶ(何度呼んでもよい)
    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    /// 走行フォルダにある診断のファイル名
    static func files(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }.sorted()
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let data = payloads.map { $0.jsonRepresentation() }
        guard !data.isEmpty else { return }
        DispatchQueue.main.async { Diagnostics.save(data) }
    }

    /// メインスレッドで呼ぶ
    private static func save(_ payloads: [Data]) {
        let store = LogStore.shared
        store.reload()
        let recording = Recorder.shared.current?.id
        let name = prefix + Fmt.sessionID.string(from: Date())
        if var meta = store.sessions.first(where: { $0.id != recording && $0.finished }) {
            let folder = store.dir(meta.id)
            for (i, d) in payloads.enumerated() {
                let file = folder.appendingPathComponent(payloads.count > 1 ? "\(name)-\(i + 1).json" : "\(name).json")
                try? d.write(to: file, options: .atomic)
            }
            // 送ってあった走行も、診断と meta.json をもう一度送る
            meta.rawSent.removeAll { $0 == "meta.json" }
            store.save(meta)
            NSLog("落ちた・固まったときの診断を \(meta.id) に保存しました(\(payloads.count)件)")
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docs.appendingPathComponent("diagnostics", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, d) in payloads.enumerated() {
                try? d.write(to: dir.appendingPathComponent("\(name)-\(i + 1).json"), options: .atomic)
            }
        }
    }
}
