import Foundation
import Network
import UIKit

/// 走行ログを MiniPC の地図サーバーへ送る。
/// - GPX は POST /api/inbox?name=<走行ID>.gpx(地図が国道の判定をする)
/// - 生データは PUT /api/rawlog?session=<走行ID>&file=<ファイル名>(MiniPC が Google ドライブの _drivelog に置く)
/// - 車以外(電車・飛行機など)は GPX を送らず(地図に反映しない)、生データに &kind=trip を付けて _drivelog\trips に置く
/// 通信できないときは端末に残しておき、Wi-Fi やテザリングにつながったときに送り直す
final class Uploader: ObservableObject {
    static let shared = Uploader()

    @Published private(set) var isUploading = false
    @Published private(set) var lastMessage: String?
    @Published private(set) var online = false
    /// いまモバイル通信(SIM)でつながっている
    @Published private(set) var cellular = false

    /// 自動で送ってよい通信か(「Wi-Fi のときだけ送る」がオンならモバイル通信では送らない)
    var canAutoSend: Bool { online && !(AppSettings.shared.uploadWifiOnly && cellular) }

    private let monitor = NWPathMonitor()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 30 * 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private init() {}

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            // Wi-Fi が使えるときはそちらが優先される。テザリング(相手の iPhone の Wi-Fi)は Wi-Fi 扱い
            let cell = ok && path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
            DispatchQueue.main.async {
                guard let self else { return }
                let could = self.canAutoSend
                self.online = ok
                self.cellular = cell
                // 送れるようになったとき(オフライン→オンライン、モバイル通信→Wi-Fi)に送る
                if !could && self.canAutoSend && AppSettings.shared.autoUpload { self.uploadPending() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "uploader.monitor"))
    }

    /// 送れなかったときに送り直すまでの秒数(記録を止めたあと、アプリを起こしている間だけ)
    static let retryInterval: TimeInterval = 30
    private var retryItem: DispatchWorkItem?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    /// 「Wi-Fi のときだけ送る」を切り替えたとき
    func networkPolicyChanged() {
        DispatchQueue.main.async {
            if self.canAutoSend && AppSettings.shared.autoUpload { self.uploadPending() }
        }
    }

    /// manual: ログ画面のボタンから送るとき(モバイル通信でも送る)
    func uploadPending(manual: Bool = false) {
        guard !isUploading, !Recorder.shared.isRecording else { return }
        retryItem?.cancel()
        retryItem = nil
        LogStore.shared.reload()
        let targets = LogStore.shared.unsent
        guard !targets.isEmpty, let base = AppSettings.shared.baseURL else {
            Recorder.shared.endUploadKeepAlive()
            return
        }
        if !manual && AppSettings.shared.uploadWifiOnly && cellular {
            // Wi-Fi やテザリングにつながったら送る(つながったときは通信の監視から呼ばれる)
            lastMessage = "モバイル通信なので送っていません(Wi-Fi につながったら送ります)"
            Recorder.shared.endUploadKeepAlive()
            return
        }
        isUploading = true
        // 画面を消してアプリが裏に回っても、送っている途中で止められないようにする
        endBackgroundTask()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "upload") { [weak self] in
            self?.endBackgroundTask()
        }
        Task {
            var done = 0
            var failed: String?
            for meta in targets {
                do {
                    try await upload(meta, base: base)
                    done += 1
                } catch {
                    failed = error.localizedDescription
                    break // 1つ目で送れなければ、残りも送れないことが多い
                }
            }
            let message = failed.map { "送れませんでした: \($0)" } ?? "\(done)件の走行を送りました"
            await MainActor.run {
                self.isUploading = false
                self.lastMessage = message
                LogStore.shared.reload()
                if failed == nil {
                    Recorder.shared.endUploadKeepAlive()
                } else if Recorder.shared.keepingAliveForUpload {
                    // テザリングがまだつながっていないなどのときは、少し待って送り直す
                    let item = DispatchWorkItem { [weak self] in self?.uploadPending() }
                    self.retryItem = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + Uploader.retryInterval, execute: item)
                }
                self.endBackgroundTask()
            }
        }
    }

    /// 1回の走行を送る。送り終えたものは meta.json に記録し、次は送らない
    func upload(_ original: SessionMeta, base: URL) async throws {
        var meta = original
        let dir = LogStore.shared.dir(meta.id)

        let isCar = meta.travelMode.isCar
        if isCar && !meta.gpxSent {
            var c = URLComponents(url: base.appendingPathComponent("api/inbox"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "name", value: "\(meta.id).gpx")]
            try await send(file: dir.appendingPathComponent("track.gpx"), to: c.url!, method: "POST")
            meta.gpxSent = true
            LogStore.shared.save(meta)
        }

        // meta.json は送った記録を書き込んでから最後に送る
        for name in LogStore.uploadFiles where !meta.rawSent.contains(name) {
            if name == "meta.json" {
                meta.rawSent.append(name)
                LogStore.shared.save(meta)
            }
            let file = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else {
                if name != "meta.json" { meta.rawSent.append(name) }
                continue
            }
            var c = URLComponents(url: base.appendingPathComponent("api/rawlog"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "session", value: meta.id), URLQueryItem(name: "file", value: name)]
            if !isCar { c.queryItems?.append(URLQueryItem(name: "kind", value: "trip")) }
            do {
                try await send(file: file, to: c.url!, method: "PUT")
            } catch {
                if name == "meta.json" {
                    meta.rawSent.removeAll { $0 == name }
                    LogStore.shared.save(meta)
                }
                throw error
            }
            if name != "meta.json" {
                meta.rawSent.append(name)
                LogStore.shared.save(meta)
            }
        }
    }

    /// 地図サーバーが、トンネルなどで GPS が途切れた区間を道路に沿って補った位置(location_filled.csv)を受け取り、
    /// 走行フォルダに保存する。まだ補っていない・つながらないときは false(次に振り返りを開いたときにまた試す)
    func fetchFilled(_ meta: SessionMeta) async -> Bool {
        guard online, let base = AppSettings.shared.baseURL, meta.rawSent.contains("meta.json") else { return false }
        var c = URLComponents(url: base.appendingPathComponent("api/rawlog"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "session", value: meta.id), URLQueryItem(name: "file", value: ReviewLoader.filledFile)]
        if !meta.travelMode.isCar { c.queryItems?.append(URLQueryItem(name: "kind", value: "trip")) }
        var req = URLRequest(url: c.url!)
        // 自宅の外(サーバーに届かない所)で待たされないよう短めにする
        req.timeoutInterval = 5
        guard let result = try? await session.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200, !result.0.isEmpty else { return false }
        let data = result.0
        let file = LogStore.shared.dir(meta.id).appendingPathComponent(ReviewLoader.filledFile)
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    private func send(file: URL, to url: URL, method: String) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: req, fromFile: file)
        guard let http = response as? HTTPURLResponse else { throw UploadError.badResponse("応答がありません") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UploadError.badResponse("HTTP \(http.statusCode) \(body.prefix(200))")
        }
    }
}

enum UploadError: LocalizedError {
    case badResponse(String)
    var errorDescription: String? {
        switch self {
        case .badResponse(let s): return s
        }
    }
}
