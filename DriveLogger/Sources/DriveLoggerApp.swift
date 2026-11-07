import SwiftUI

@main
struct DriveLoggerApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = LogStore.shared
    @StateObject private var recorder = Recorder.shared
    @StateObject private var uploader = Uploader.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(uploader)
                .onAppear {
                    // 記録中に落ちた走行があれば閉じてから、送信を始める
                    store.recoverUnfinished(except: recorder.current?.id)
                    uploader.start()
                }
        }
        .onChange(of: scenePhase) { phase in
            // アプリを開いたときに、まだ送っていないログを送る
            if phase == .active { uploader.uploadPending() }
        }
    }
}
