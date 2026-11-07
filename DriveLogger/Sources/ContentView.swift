import SwiftUI

struct ContentView: View {
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        ZStack {
            TabView {
                RecordView()
                    .tabItem { Label("記録", systemImage: "record.circle") }
                LogsView()
                    .tabItem { Label("ログ", systemImage: "list.bullet") }
                SettingsView()
                    .tabItem { Label("設定", systemImage: "gearshape") }
            }
            // 動画と合わせる合図: 画面全体を白く光らせる
            if recorder.flash {
                Color.white.ignoresSafeArea().allowsHitTesting(false)
            }
        }
    }
}

enum Display {
    static func km(_ m: Double) -> String { String(format: "%.1f km", m / 1000) }
    static func kmh(_ ms: Double) -> String { String(format: "%.0f", ms * 3.6) }
    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()
    /// 日付の一覧に出す日付(曜日付き)
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd(E)"
        return f
    }()
    /// 日付ごとにまとめるときのキー(ローカル日付)
    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
