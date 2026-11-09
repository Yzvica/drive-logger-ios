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
    /// 記録中、急な操作を音で知らせる
    @Published var coachSound: Bool {
        didSet { UserDefaults.standard.set(coachSound, forKey: "coachSound") }
    }

    /// 次に記録する移動手段(前回選んだものを覚えておく)
    @Published var travelMode: TravelMode {
        didSet { UserDefaults.standard.set(travelMode.rawValue, forKey: "travelMode") }
    }

    /// 記録中、GPS が切れたとき・戻ったときにバイブで知らせる
    @Published var gpsVibrate: Bool {
        didSet { UserDefaults.standard.set(gpsVibrate, forKey: "gpsVibrate") }
    }

    /// モバイル通信(SIM)のときは自動で送らない(Wi-Fi・テザリングのときだけ送る)
    @Published var uploadWifiOnly: Bool {
        didSet {
            UserDefaults.standard.set(uploadWifiOnly, forKey: "uploadWifiOnly")
            Uploader.shared.networkPolicyChanged()
        }
    }

    /// 音を一切鳴らさず、画面の表示だけで知らせる(同期・目印・停止・急な操作)
    @Published var soundOff: Bool {
        didSet { UserDefaults.standard.set(soundOff, forKey: "soundOff") }
    }

    /// 地図をダブルタップして上下に動かす拡大縮小で、下に動かすと拡大する(Google マップと同じ向き)。
    /// false なら Apple の地図の標準のまま
    @Published var oneFingerZoomDownIn: Bool {
        didSet { UserDefaults.standard.set(oneFingerZoomDownIn, forKey: "oneFingerZoomDownIn") }
    }

    private init() {
        let d = UserDefaults.standard
        oneFingerZoomDownIn = d.object(forKey: "oneFingerZoomDownIn") as? Bool ?? true
        soundOff = d.bool(forKey: "soundOff")
        uploadWifiOnly = d.object(forKey: "uploadWifiOnly") as? Bool ?? true
        gpsVibrate = d.object(forKey: "gpsVibrate") as? Bool ?? true
        travelMode = d.string(forKey: "travelMode").flatMap(TravelMode.init(rawValue:)) ?? .car
        mapStyle = d.string(forKey: "mapStyle").flatMap(MapStyle.init(rawValue:)) ?? .appleStandard
        mapHeadingUp = d.bool(forKey: "mapHeadingUp")
        coachSound = d.object(forKey: "coachSound") as? Bool ?? true
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
