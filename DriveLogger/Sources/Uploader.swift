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
            for var meta in targets {
                // 落ちて閉じた走行は、送る前に運転評価を付ける
                if meta.evalPending == true, let m = await LogStore.shared.evaluatePending(meta.id) { meta = m }
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

        // 途中で分けた記録の前半は、地図サーバーにある前の記録(分ける前の全体)を消してから送り直す
        if meta.resetPending == true {
            try await deleteSession(meta, base: base)
            meta.resetPending = nil
            LogStore.shared.save(meta)
        }

        // 送ったあとで移動手段を直した走行は、先に地図サーバーでも直してもらう(フォルダを移し、国道の判定に足す・外す)
        if meta.modeChangePending == true {
            switch try await postMode(meta, base: base) {
            case .changed(let gpx):
                // 車にしたとき、サーバーに位置の記録があれば GPX はサーバーが作る。なければこのあと送る
                meta.gpxSent = gpx
            case .noSession:
                // サーバーに何も残っていない: 新しい手段で最初から送る
                meta.gpxSent = false
                meta.rawSent = []
            }
            meta.modeChangePending = nil
            LogStore.shared.save(meta)
        }

        let isCar = meta.travelMode.isCar
        if isCar && !meta.gpxSent {
            var c = URLComponents(url: base.appendingPathComponent("api/inbox"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "name", value: "\(meta.id).gpx")]
            try await send(file: dir.appendingPathComponent("track.gpx"), to: c.url!, method: "POST")
            meta.gpxSent = true
            LogStore.shared.save(meta)
        }

        // meta.json は送った記録を書き込んでから最後に送る。落ちた・固まったときの診断(Diagnostics)があればその前に送る
        let names = LogStore.uploadFiles.filter { $0 != "meta.json" } + Diagnostics.files(in: dir) + ["meta.json"]
        for name in names where !meta.rawSent.contains(name) {
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

    /// 地図の運転リプレイ用の replay.csv を送る(リプレイを作る前に送り終えた走行は、振り返りを開いたときにここで送る)。
    /// 送れたら true。送ってある・まだ全体を送っていない(このあといつも通り送られる)・つながらないときは false
    @discardableResult
    func sendReplay(_ id: String) async -> Bool {
        guard online, let base = AppSettings.shared.baseURL, var meta = LogStore.shared.load(id),
              meta.rawSent.contains("meta.json"), !meta.rawSent.contains(ReplayExport.fileName),
              meta.modeChangePending != true, meta.resetPending != true else { return false }
        let file = LogStore.shared.dir(id).appendingPathComponent(ReplayExport.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        var c = URLComponents(url: base.appendingPathComponent("api/rawlog"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "session", value: id), URLQueryItem(name: "file", value: ReplayExport.fileName)]
        if !meta.travelMode.isCar { c.queryItems?.append(URLQueryItem(name: "kind", value: "trip")) }
        guard (try? await send(file: file, to: c.url!, method: "PUT")) != nil else { return false }
        // 送っている間に書き換わっていないか、読み直してから記録する
        meta = LogStore.shared.load(id) ?? meta
        if !meta.rawSent.contains(ReplayExport.fileName) { meta.rawSent.append(ReplayExport.fileName) }
        LogStore.shared.save(meta)
        return true
    }

    /// 地図サーバーが、トンネルなどで GPS が途切れた区間を道路(電車は線路)に沿って補った位置(location_filled.csv)を受け取り、
    /// 走行フォルダに保存する。サーバーはあとから補い直すこと(線路のデータが入った・補い方が良くなった・移動手段を直した)が
    /// あるので、振り返りを開くたびに取り直す。端末のものと中身が変わったら true(読み直す)。
    /// サーバーで補った位置がなくなっていたら(補えなかった手段に直したなど)、端末のものも消す
    func fetchFilled(_ meta: SessionMeta) async -> Bool {
        // 手段の直し・分けた記録の送り直しがまだなら、サーバーの置き場所(車/trips)が端末と違うので取らない
        guard meta.modeChangePending != true, meta.resetPending != true else { return false }
        let file = LogStore.shared.dir(meta.id).appendingPathComponent(ReviewLoader.filledFile)
        switch await getServerFile(meta, name: ReviewLoader.filledFile) {
        case .data(let data):
            if let old = try? Data(contentsOf: file), old == data { return false }
            return (try? data.write(to: file, options: .atomic)) != nil
        case .notFound:
            guard FileManager.default.fileExists(atPath: file.path) else { return false }
            return (try? FileManager.default.removeItem(at: file)) != nil
        case .unreachable:
            return false
        }
    }

    /// 地図サーバーが走り終えたあとに取った天気(weather.json)を受け取り、走行フォルダに保存する。
    /// まだ取っていない・つながらないときは false(次にログを開いたときにまた試す)
    func fetchWeather(_ meta: SessionMeta) async -> Bool {
        await fetchServerFile(meta, name: DriveWeather.fileName)
    }

    /// 地図サーバーが走行フォルダに作ったファイルを GET /api/rawlog で受け取り、端末の走行フォルダに保存する
    private func fetchServerFile(_ meta: SessionMeta, name: String) async -> Bool {
        guard case .data(let data) = await getServerFile(meta, name: name) else { return false }
        let file = LogStore.shared.dir(meta.id).appendingPathComponent(name)
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    enum ServerFile { case data(Data), notFound, unreachable }

    /// 地図サーバーが走行フォルダに作ったファイルを GET /api/rawlog で受け取る(保存はしない)
    private func getServerFile(_ meta: SessionMeta, name: String) async -> ServerFile {
        guard online, let base = AppSettings.shared.baseURL, meta.rawSent.contains("meta.json") else { return .unreachable }
        var c = URLComponents(url: base.appendingPathComponent("api/rawlog"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "session", value: meta.id), URLQueryItem(name: "file", value: name)]
        if !meta.travelMode.isCar { c.queryItems?.append(URLQueryItem(name: "kind", value: "trip")) }
        var req = URLRequest(url: c.url!)
        // 自宅の外(サーバーに届かない所)で待たされないよう短めにする
        req.timeoutInterval = 5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let result = try? await session.data(for: req), let http = result.1 as? HTTPURLResponse else { return .unreachable }
        let data = result.0
        // 404 はサーバーの走行フォルダにそのファイルがない(まだ作っていない・作らない手段)
        if http.statusCode == 404 { return .notFound }
        guard http.statusCode == 200, !data.isEmpty else { return .unreachable }
        return .data(data)
    }

    enum ModeResult { case changed(gpx: Bool), noSession }

    /// POST /api/rawlog/mode?session=&mode= で地図サーバーの移動手段を直す
    private func postMode(_ meta: SessionMeta, base: URL) async throws -> ModeResult {
        var c = URLComponents(url: base.appendingPathComponent("api/rawlog/mode"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "session", value: meta.id), URLQueryItem(name: "mode", value: meta.travelMode.rawValue)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UploadError.badResponse("応答がありません") }
        let body = String(data: data, encoding: .utf8) ?? ""
        if http.statusCode == 404 {
            // 古い地図サーバーは移動手段を直せない(どの道も 404 を返す)。サーバーを更新してから送り直す
            guard body.contains("no session") else { throw UploadError.badResponse("地図サーバーが古いので移動手段を直せません(更新してください)") }
            return .noSession
        }
        guard (200..<300).contains(http.statusCode) else { throw UploadError.badResponse("HTTP \(http.statusCode) \(body.prefix(200))") }
        struct Reply: Decodable { var gpx: Bool }
        let gpx = (try? JSONDecoder().decode(Reply.self, from: data))?.gpx ?? false
        return .changed(gpx: gpx)
    }

    /// DELETE /api/rawlog/session?session= で地図サーバーにある記録を忘れてもらう(フォルダは replaced に移り、地図のログは判定から外れる)
    private func deleteSession(_ meta: SessionMeta, base: URL) async throws {
        var c = URLComponents(url: base.appendingPathComponent("api/rawlog/session"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "session", value: meta.id)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UploadError.badResponse("応答がありません") }
        let body = String(data: data, encoding: .utf8) ?? ""
        if http.statusCode == 404 {
            // サーバーに何もなければそのまま送る。古いサーバーは(どの道も)404 を返すので止める
            guard body.contains("no session") else { throw UploadError.badResponse("地図サーバーが古いので分けた記録を送れません(更新してください)") }
            return
        }
        guard (200..<300).contains(http.statusCode) else { throw UploadError.badResponse("HTTP \(http.statusCode) \(body.prefix(200))") }
    }

    /// 地図サーバーでの移動手段(地図のログタブで直されていないか確かめる)。つながらない・まだ届いていなければ nil
    func fetchServerMode(_ meta: SessionMeta) async -> TravelMode? {
        guard online, let base = AppSettings.shared.baseURL, meta.rawSent.contains("meta.json"),
              meta.modeChangePending != true, meta.resetPending != true else { return nil }
        var c = URLComponents(url: base.appendingPathComponent("api/rawlog/mode"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "session", value: meta.id)]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 5
        guard let result = try? await session.data(for: req), (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Reply: Decodable { var mode: String; var sent: Bool? }
        guard let r = try? JSONDecoder().decode(Reply.self, from: result.0), r.sent != false else { return nil }
        return TravelMode(rawValue: r.mode)
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
