import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var recording = RecordingState.shared
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.11.123:8080", text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("既定(自宅のMiniPC)に戻す") { settings.serverURL = AppSettings.defaultServer }
                    Button("つながるか確かめる") { Task { await test() } }
                    if let testResult { Text(testResult).font(.footnote) }
                } header: {
                    Text("送り先(地図サーバー)")
                } footer: {
                    Text("外出先からは、Tailscale をつないで MiniPC の Tailscale のアドレス(http://100.x.x.x:8080 など)を入れてください。")
                }
                Section {
                    Toggle("音を鳴らさない(画面で知らせる)", isOn: $settings.soundOff)
                    Toggle("急な操作を音で知らせる", isOn: $settings.coachSound)
                        .disabled(settings.soundOff)
                } header: {
                    Text("記録中のサポート")
                } footer: {
                    Text("急ブレーキは下がる音、急加速は上がる音、急ハンドルは短く2回、そのほかの急な操作は短く1回、止まり際のカックンは低い音。音は DJI Mic にも入ります。「音を鳴らさない」にすると、記録開始・停止の同期の合図も含めて音を出さず、画面の上に文字で出します(動画との時刻合わせは DriveLog のジャイロの波形合わせで行えます)。")
                }
                Section {
                    Picker("ダブルタップして上下", selection: $settings.oneFingerZoomDownIn) {
                        Text("下で拡大(Google マップ)").tag(true)
                        Text("上で拡大(Apple の標準)").tag(false)
                    }
                } header: {
                    Text("地図")
                } footer: {
                    Text("地図をダブルタップして指を離さずに上下に動かしたときの、拡大縮小の向き")
                }
                Section {
                    Toggle("GPS が切れた・戻ったらバイブ", isOn: $settings.gpsVibrate)
                        // 記録中にここを変えたら、今の記録にもそのまま効かせる
                        .onChange(of: settings.gpsVibrate) { on in
                            if recording.isRecording { Recorder.shared.gpsVibrateNow = on }
                        }
                } header: {
                    Text("GPS の受信状態")
                } footer: {
                    Text("記録中は地図の右上に GPS のランプ(緑=良好 ±20m 以内・黄=弱い ±50m 以内・赤=切断・灰=測位中)を出します。使える位置が\(Int(GPSStatus.lostAfter))秒来ないと切断とみなし2回振動、戻ったら(最初に測位できたときも)1回振動します。車・電車・飛行機のどれでも動きます。ここは記録を始めるときの値で、記録中はランプの左のボタンでその記録だけ切り替えられます。")
                }
                Section {
                    Toggle("記録中に雨雲レーダーとアメダスを取る", isOn: $settings.rainRadar)
                        .disabled(recording.isRecording)
                } header: {
                    Text("雨")
                } footer: {
                    Text("記録中、ネットにつながっていれば(テザリングなど)、気象庁の雨雲レーダーを5分ごとに取って保管し、いまいる場所の雨の強さとこの先30分の予測を記録画面に出します。あわせて最寄りのアメダス観測所の実測(10分ごとの雨量・気温・風)も取って出します。保管したデータは走行ログと一緒に送り、動画の雨雲レーダーに使います。通信量は1時間で1MB ほどです。つながっていない間のぶんは、つながったときに3時間前までさかのぼって取ります。飛行機の記録では取りません。")
                }
                Section {
                    Text("記録中にアプリが裏で終了すると、\(Int(Watchdog.delay))秒ほどで通知が届きます。初めて記録するときに通知を許可してください")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("アプリが止まったとき")
                }
                Section {
                    Picker("加速度などの頻度", selection: $settings.motionHz) {
                        Text("25 Hz").tag(25)
                        Text("50 Hz").tag(50)
                        Text("100 Hz").tag(100)
                    }
                    .disabled(recording.isRecording)
                    Toggle("走行が終わったら自動で送る", isOn: $settings.autoUpload)
                    Toggle("自動で送るのは Wi-Fi のときだけ", isOn: $settings.uploadWifiOnly)
                    Toggle("記録中は画面を消さない", isOn: $settings.keepScreenOn)
                } header: {
                    Text("記録")
                } footer: {
                    Text("Wi-Fi のときだけにすると、SIM のモバイル通信では自動で送りません(テザリングは Wi-Fi 扱いで送ります)。ログ画面の「未送信のログを送る」はモバイル通信でも送ります。")
                }
                Section("このアプリについて") {
                    LabeledContent("バージョン", value: AppInfo.version)
                    if let commit = AppInfo.commit {
                        LabeledContent("コミット", value: commit)
                    }
                    if let pr = AppInfo.pullRequest {
                        LabeledContent("プルリクエスト", value: pr)
                    }
                }
            }
            .navigationTitle("設定")
        }
    }

    private func test() async {
        guard let base = settings.baseURL else { testResult = "アドレスが正しくありません"; return }
        do {
            let (_, response) = try await URLSession.shared.data(from: base.appendingPathComponent("api/inbox"))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            testResult = code == 200 ? "つながりました" : "応答がおかしいです(HTTP \(code))"
        } catch {
            testResult = "つながりません: \(error.localizedDescription)"
        }
    }
}

/// アプリのバージョン。ビルド番号は CI の実行番号(GitHub Actions の Run 番号)、コミットとプルリクエストの番号は CI がビルドしたもの
enum AppInfo {
    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    static var version: String {
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        let b = info["CFBundleVersion"] as? String ?? "?"
        return "\(v)(ビルド \(b))"
    }

    static var commit: String? {
        guard let c = info["GitCommit"] as? String, !c.isEmpty else { return nil }
        return c
    }

    /// ビルドのもとになったプルリクエスト。main のビルドは最後にマージしたもの、
    /// プルリクエストのビルドはそのプルリクエスト(まだマージしていないので、そう書く)
    static var pullRequest: String? {
        guard let n = info["GitPR"] as? String, !n.isEmpty else { return nil }
        return (info["GitEvent"] as? String) == "pull_request" ? "#\(n)(マージ前)" : "#\(n)"
    }
}
