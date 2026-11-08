import CoreLocation

/// 移動手段。車以外は国道制覇マップに送らず(GPX を /api/inbox に送らない)、運転評価もしない。
/// 生データは地図サーバーの trips フォルダ(_drivelog\trips\<走行ID>)に送る
enum TravelMode: String, Codable, CaseIterable, Identifiable {
    case car, train, plane, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .car: return "車"
        case .train: return "電車"
        case .plane: return "飛行機"
        case .other: return "その他"
        }
    }

    var systemImage: String {
        switch self {
        case .car: return "car.fill"
        case .train: return "tram.fill"
        case .plane: return "airplane"
        case .other: return "figure.walk"
        }
    }

    var isCar: Bool { self == .car }

    /// 位置の取り方(iOS が移動の種類に合わせて測位を調整する)
    var activityType: CLActivityType {
        switch self {
        case .car: return .automotiveNavigation
        case .plane: return .airborne
        case .train, .other: return .otherNavigation
        }
    }

    /// 車以外は加速度などを 10Hz で記録する(長時間の移動でファイルと電池を節約する)
    static let tripMotionHz = 10
}
