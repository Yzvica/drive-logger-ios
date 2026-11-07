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
                .onAppear { uploader.start() }
        }
        .onChange(of: scenePhase) { phase in
            // アプリを開いたときに、まだ送っていないログを送る
            if phase == .active { uploader.uploadPending() }
        }
    }
}
