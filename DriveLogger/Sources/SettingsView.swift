import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var recorder: Recorder
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
                    Toggle("急な操作を音で知らせる", isOn: $settings.coachSound)
                } header: {
                    Text("記録中のサポート")
                } footer: {
                    Text("急ブレーキは下がる音、急加速は上がる音、急ハンドルは短く2回、そのほかの急な操作は短く1回、止まり際のカックンは低い音。音は DJI Mic にも入ります。")
                }
                Section("記録") {
                    Picker("加速度などの頻度", selection: $settings.motionHz) {
                        Text("25 Hz").tag(25)
                        Text("50 Hz").tag(50)
                        Text("100 Hz").tag(100)
                    }
                    .disabled(recorder.isRecording)
                    Toggle("走行が終わったら自動で送る", isOn: $settings.autoUpload)
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
