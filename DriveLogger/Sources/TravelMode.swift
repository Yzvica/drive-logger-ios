import CoreLocation

/// 移動手段。車以外は国道制覇マップに送らない(GPX を /api/inbox に送らない)。運転評価は車と同乗だけ。
/// 生データは地図サーバーの trips フォルダ(_drivelog\trips\<走行ID>)に送る
enum TravelMode: String, Codable, CaseIterable, Identifiable {
    /// ride は同乗(バス・タクシー・人の運転する車)。自分が運転していないので地図には入れないが、運転評価はする
    case car, ride, train, plane, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .car: return "車"
        case .ride: return "同乗"
        case .train: return "電車"
        case .plane: return "飛行機"
        case .other: return "その他"
        }
    }

    var systemImage: String {
        switch self {
        case .car: return "car.fill"
        case .ride: return "bus.fill"
        case .train: return "tram.fill"
        case .plane: return "airplane"
        case .other: return "figure.walk"
        }
    }

    var isCar: Bool { self == .car }

    /// 運転評価を出すか。同乗(人の運転)も評価する。端末は固定でも手持ちでもよい(手持ちは参考値)
    var hasDriveEval: Bool { self == .car || self == .ride }

    /// 運転評価の計算で、固定されていない端末(手持ち)を許すか
    var allowsHandheldEval: Bool { self == .ride }

    /// 位置の取り方(iOS が移動の種類に合わせて測位を調整する)
    var activityType: CLActivityType {
        switch self {
        // 同乗も車と同じ取り方にする(トンネルの中で iOS が道路に沿って位置を進めてくれる)
        case .car, .ride: return .automotiveNavigation
        case .plane: return .airborne
        case .train, .other: return .otherNavigation
        }
    }

    /// 車以外は加速度などを 10Hz で記録する(長時間の移動でファイルと電池を節約する)
    static let tripMotionHz = 10
}
