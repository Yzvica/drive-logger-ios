import Foundation

/// 設定(送り先など)。UserDefaults に保存する
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let defaultServer = "http://192.168.11.123:8080"

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    /// 加速度などを記録する頻度(Hz)
    @Published var motionHz: Int {
        didSet { UserDefaults.standard.set(motionHz, forKey: "motionHz") }
    }
    /// 走行が終わったら自動で送る
    @Published var autoUpload: Bool {
        didSet { UserDefaults.standard.set(autoUpload, forKey: "autoUpload") }
    }

    /// 記録中は画面を自動で消さない(画面を消しても記録は続くが、念のため)
    @Published var keepScreenOn: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenOn, forKey: "keepScreenOn")
            Recorder.shared.updateIdleTimer()
        }
    }

    /// 記録画面の地図の種類
    @Published var mapStyle: MapStyle {
        didSet { UserDefaults.standard.set(mapStyle.rawValue, forKey: "mapStyle") }
    }
    /// 地図の追尾で進行方向を上にする(false なら北が上)
    @Published var mapHeadingUp: Bool {
        didSet { UserDefaults.standard.set(mapHeadingUp, forKey: "mapHeadingUp") }
    }

    private init() {
        let d = UserDefaults.standard
        mapStyle = d.string(forKey: "mapStyle").flatMap(MapStyle.init(rawValue:)) ?? .appleStandard
        mapHeadingUp = d.bool(forKey: "mapHeadingUp")
        serverURL = d.string(forKey: "serverURL") ?? AppSettings.defaultServer
        motionHz = d.object(forKey: "motionHz") as? Int ?? 50
        autoUpload = d.object(forKey: "autoUpload") as? Bool ?? true
        keepScreenOn = d.object(forKey: "keepScreenOn") as? Bool ?? true
    }

    /// 末尾の / を除いた送り先
    var baseURL: URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
}
