import UserNotifications

/// 記録中にアプリが落ちた・iOS に止められたことに気づけるようにする。
/// 記録中は「90秒後に鳴る通知」を30秒ごとに先送りし続ける。アプリが止まると先送りされなくなり、通知が届く。
/// 停止ボタンで止めたときは取り消す
enum Watchdog {
    static let id = "recording-watchdog"
    /// アプリが止まってから通知が届くまでの最長秒数
    static let delay: TimeInterval = 90
    /// 先送りする間隔
    static let interval: TimeInterval = 30

    private static var lastArm: TimeInterval = 0

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 記録中に1秒ごとに呼ぶ(30秒ごとに先送りする)。force なら必ず先送りする
    static func arm(mode: TravelMode, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastArm >= interval else { return }
        lastArm = now
        let content = UNMutableNotificationContent()
        content.title = "\(mode.title)の記録が止まっています"
        content.body = "走行ロガーが裏で終了したようです。アプリを開いて、記録し直してください(ここまでのログは残っています)"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        // 同じ id で登録し直すと前のものは置き換わる
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func disarm() {
        lastArm = 0
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: [id])
        c.removeDeliveredNotifications(withIdentifiers: [id])
    }
}
