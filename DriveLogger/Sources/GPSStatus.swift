import AudioToolbox
import SwiftUI

/// 記録中の GPS の受信状態(画面のランプとバイブに使う)
enum GPSStatus: Equatable {
    /// 記録を始めてから、まだ一度も使える位置が取れていない
    case searching
    /// 精度 ±20m 以内
    case good
    /// 精度 ±20〜50m
    case weak
    /// 使える位置(±50m 以内)が lostAfter 秒以上来ていない
    case lost

    /// この秒数のあいだ使える位置が来なければ「切断」とみなす
    static let lostAfter: TimeInterval = 10
    static let goodAccuracy: Double = 20
    static let usableAccuracy: Double = 50

    var title: String {
        switch self {
        case .searching: return "GPS 測位中"
        case .good: return "GPS 良好"
        case .weak: return "GPS 弱い"
        case .lost: return "GPS 切断"
        }
    }

    var color: Color {
        switch self {
        case .searching: return .gray
        case .good: return .green
        case .weak: return .yellow
        case .lost: return .red
        }
    }

    var receiving: Bool { self == .good || self == .weak }
}

/// 画面のランプ(色の丸と状態の文字)
struct GPSLamp: View {
    let status: GPSStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 10, height: 10)
                .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 0.5))
            Text(status.title).font(.footnote.bold())
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// 記録中に GPS のバイブを切り替えるボタン(ランプの左に出す)
struct GPSVibrateButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
            // オンにしたときは1回振動して、効いていることが手で分かるようにする
            if isOn { GPSHaptics.back() }
        } label: {
            Image(systemName: isOn ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                .font(.footnote.bold())
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .frame(minWidth: 20)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "GPS のバイブ オン" : "GPS のバイブ オフ")
        .accessibilityHint("タップで切り替え")
    }
}

/// GPS が切れた・戻ったことをバイブで知らせる(消音モードでも振動する。画面を消していても記録中は動く)
enum GPSHaptics {
    /// 切れた: 2回
    static func lost() { vibrate(times: 2) }
    /// 戻った・最初に測位できた: 1回
    static func back() { vibrate(times: 1) }

    private static func vibrate(times: Int) {
        for i in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.7) {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }
}
