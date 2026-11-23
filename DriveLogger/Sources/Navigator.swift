import AVFoundation
import CoreLocation
import CryptoKit
import MapKit
import UIKit

/// ナビのコース(地図で作って MiniPC に保存した案内のデータ)を受け取って、この iPhone に保存する。
/// 走行中は MiniPC につながらなくても案内できるよう、家の Wi-Fi で受け取っておく
final class NaviStore: ObservableObject {
    static let shared = NaviStore()

    /// MiniPC のコースの一覧(/api/navi/courses)
    struct ServerCourse: Decodable, Identifiable {
        struct GuideMeta: Decodable {
            var length: Double
            var maneuvers: Int
        }
        var name: String
        var mode: String?
        var savedAt: String?
        var guide: GuideMeta?
        var id: String { name }
    }

    /// この iPhone に保存したコース
    @Published private(set) var saved: [NaviGuideData] = []
    @Published private(set) var server: [ServerCourse] = []
    @Published private(set) var loading = false
    @Published var message: String?

    private let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("navi", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private init() { loadLocal() }

    private func file(_ name: String) -> URL {
        let h = Insecure.SHA1.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(h).json")
    }

    func loadLocal() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let list = files.filter { $0.pathExtension == "json" }.compactMap { url -> NaviGuideData? in
            guard let d = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(NaviGuideData.self, from: d)
        }
        saved = list.sorted { ($0.savedAt ?? "") > ($1.savedAt ?? "") }
    }

    func isSaved(_ c: ServerCourse) -> Bool {
        saved.contains { $0.name == c.name && $0.savedAt == c.savedAt }
    }

    /// MiniPC のコースの一覧を読む
    func refresh() {
        guard let base = AppSettings.shared.baseURL else {
            message = "設定で送り先(MiniPC)を入れてください"
            return
        }
        loading = true
        message = nil
        var req = URLRequest(url: base.appendingPathComponent("api/navi/courses"))
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, res, err in
            let list = data.flatMap { try? JSONDecoder().decode([ServerCourse].self, from: $0) }
            DispatchQueue.main.async {
                self.loading = false
                if let list {
                    self.server = list
                    if list.isEmpty { self.message = "MiniPC にコースがありません。地図の「ナビ・コース」で保存してください" }
                } else {
                    self.message = "MiniPC につながりません(\(err?.localizedDescription ?? "HTTP \((res as? HTTPURLResponse)?.statusCode ?? 0)"))。家の Wi-Fi で試してください"
                }
            }
        }.resume()
    }

    /// コースの案内のデータを受け取って保存する
    func download(_ c: ServerCourse) {
        guard let base = AppSettings.shared.baseURL,
              var comps = URLComponents(url: base.appendingPathComponent("api/navi/guide"), resolvingAgainstBaseURL: false) else { return }
        comps.queryItems = [URLQueryItem(name: "name", value: c.name)]
        guard let url = comps.url else { return }
        loading = true
        message = nil
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { data, res, err in
            let code = (res as? HTTPURLResponse)?.statusCode ?? 0
            let guide = code == 200 ? data.flatMap { try? JSONDecoder().decode(NaviGuideData.self, from: $0) } : nil
            DispatchQueue.main.async {
                self.loading = false
                guard let guide, let data, NaviLine(guide: guide) != nil else {
                    self.message = code == 404 ? "「\(c.name)」には案内のデータがありません。地図で道筋を出してから保存し直してください" : "受け取れませんでした(\(err?.localizedDescription ?? "HTTP \(code)"))"
                    return
                }
                do {
                    try data.write(to: self.file(guide.name), options: .atomic)
                    self.loadLocal()
                    self.message = "「\(guide.name)」を受け取りました"
                } catch {
                    self.message = "保存できませんでした: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    func delete(_ g: NaviGuideData) {
        try? FileManager.default.removeItem(at: file(g.name))
        loadLocal()
    }
}

/// 画面の上に出す次の案内
struct NaviBanner: Equatable {
    var icon = "location.north.line"
    var distance = ""
    var text = "現在地を探しています"
    var road = ""
    var remaining = ""
    var current = ""
    var offRoute = false
    var detour = false
}

/// コースの音声案内。位置を受け取って NaviEngine(NaviCore.swift)で案内を決め、読み上げる。
/// 声は再生用のオーディオで出すので、CarPlay につないでいれば車のスピーカーから出る(CarPlay の画面には出せない)。
/// コースから外れたときと「一般道」(データにない道)の区間は、Apple の経路(MKDirections)で案内する
final class Navigator: NSObject, ObservableObject, CLLocationManagerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = Navigator()

    @Published private(set) var active = false
    @Published private(set) var name = ""
    /// コースの線(画面に描く)
    @Published private(set) var course: NaviLine?
    /// Apple の経路(コースに戻る道・一般道の区間)
    @Published private(set) var detourLine: NaviLine?
    @Published private(set) var banner = NaviBanner()
    @Published private(set) var location: CLLocation?
    /// 現在地の住所(「愛知県豊田市足助町」など。Apple の住所検索で、300m 動くか 2 分ごとに取り直す)
    @Published private(set) var address = ""
    /// 声を出さない
    @Published var muted = false {
        didSet { if muted { queue.async { self.synth.stopSpeaking(at: .immediate) } } }
    }

    private enum DetourKind {
        /// コースから外れたので戻る
        case back
        /// 一般道の区間(コースの距離の範囲)
        case free(ClosedRange<Double>)
    }

    private let manager = CLLocationManager()
    private let synth = AVSpeechSynthesizer()
    /// 読み上げとオーディオの切り替えはこの順番待ちで(メインスレッドを止めない)
    private let queue = DispatchQueue(label: "navi-speech", qos: .userInitiated)
    private var engine: NaviEngine?
    private var detour: NaviEngine?
    private var detourKind: DetourKind?
    private var requesting = false
    private var lastRequest = Date.distantPast
    /// Apple の経路を頼んだ一般道の区間(始めの距離)
    private var freeRequested = Set<Int>()
    private var timer: Timer?
    private var spoke = false
    private let geocoder = CLGeocoder()
    private var geocodedAt: CLLocation?
    private var geocodedTime = Date.distantPast

    private override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        synth.delegate = self
    }

    func start(_ guide: NaviGuideData) {
        guard let line = NaviLine(guide: guide) else { return }
        stop(silent: true)
        name = guide.name
        course = line
        engine = NaviEngine(line: line)
        detour = nil
        detourKind = nil
        detourLine = nil
        freeRequested = []
        spoke = false
        address = ""
        geocodedAt = nil
        banner = NaviBanner(remaining: NaviSpeech.label(line.length))
        active = true
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        Recorder.shared.updateIdleTimer()
        say(["「\(guide.name)」の案内を始めます"])
    }

    func stop(silent: Bool = false) {
        guard active else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        timer?.invalidate()
        timer = nil
        active = false
        engine = nil
        detour = nil
        detourKind = nil
        detourLine = nil
        course = nil
        Recorder.shared.updateIdleTimer()
        if !silent { say(["案内を終わります"]) }
    }

    // MARK: - 位置

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active, let loc = locations.last, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 100, let engine else { return }
        location = loc
        updateAddress(loc)
        let p = GeoPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        let heading: Double? = loc.course >= 0 ? loc.course : nil
        let t = loc.timestamp.timeIntervalSince1970
        var says = engine.update(p, speed: loc.speed, heading: heading, hAcc: loc.horizontalAccuracy, time: t)
        if !spoke, engine.progress != nil {
            // 最初に位置がわかったら、最初の案内まで言う
            spoke = true
            says.insert(engine.startText(), at: 0)
        }
        if let d = detour {
            let ds = d.update(p, speed: loc.speed, heading: heading, hAcc: loc.horizontalAccuracy, time: t)
            // Apple の経路で案内しているあいだは、コースの案内は「戻りました」「到着」だけ言う
            says = says.filter { $0.contains("戻りました") || $0.contains("到着") } + ds
            checkDetourEnd()
            // Apple の経路からも外れたら、頼み直す
            if detour != nil, d.offDistance > 80, Date().timeIntervalSince(lastRequest) > 30, let k = detourKind {
                requestDetour(k)
            }
        } else {
            planDetour()
        }
        say(says)
        updateBanner()
    }

    /// 住所を取り直す。初回・300m 以上動いて 20 秒たった・2 分たった、のどれかのとき(Apple の回数制限に当たらないよう間をあける)
    private func updateAddress(_ loc: CLLocation) {
        guard !geocoder.isGeocoding else { return }
        let since = Date().timeIntervalSince(geocodedTime)
        if let last = geocodedAt, !(since >= 120 || (since >= 20 && loc.distance(from: last) >= 300)) { return }
        geocodedAt = loc
        geocodedTime = Date()
        geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "ja_JP")) { [weak self] marks, _ in
            guard let m = marks?.first else { return }
            var parts: [String] = []
            for p in [m.administrativeArea, m.locality, m.subLocality, m.thoroughfare] {
                if let p, !p.isEmpty, !parts.contains(p) { parts.append(p) }
            }
            let text = parts.joined()
            DispatchQueue.main.async {
                guard let self, self.active, !text.isEmpty else { return }
                self.address = text
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("ナビの位置: \(error)")
    }

    private func tick() {
        guard active, let engine else { return }
        let t = Date().timeIntervalSince1970
        var says = engine.tick(time: t)
        if let d = detour { says = d.tick(time: t) }
        say(says)
        updateBanner()
    }

    // MARK: - Apple の経路(コースに戻る道・一般道)

    /// コースから外れた・一般道の区間が近いときに、Apple の経路を頼む
    private func planDetour() {
        guard let engine, let course, !requesting else { return }
        if engine.offRoute {
            if Date().timeIntervalSince(lastRequest) > 30 { requestDetour(.back) }
            return
        }
        guard let p = engine.progress else { return }
        // 一般道の区間の 700m 手前(短い区間は直線のままでも迷わないので頼まない)
        if let f = course.free.first(where: { $0.upperBound - $0.lowerBound > 300 && $0.lowerBound - p < 700 && $0.upperBound > p + 50 }),
           !freeRequested.contains(Int(f.lowerBound)) {
            freeRequested.insert(Int(f.lowerBound))
            requestDetour(.free(f))
        }
    }

    private func checkDetourEnd() {
        guard let engine, let d = detour, let k = detourKind else { return }
        var done = d.arrived
        switch k {
        case .back:
            if !engine.offRoute { done = true }
        case .free(let f):
            if !engine.offRoute, let p = engine.progress, p >= f.upperBound - 30 { done = true }
        }
        if done {
            detour = nil
            detourKind = nil
            detourLine = nil
        }
    }

    private func requestDetour(_ kind: DetourKind) {
        guard let course, let engine, let loc = location else { return }
        let target: GeoPoint
        switch kind {
        case .back:
            // 外れる前にいた所の 300m 先(コースの先へ戻る)
            target = course.point(at: min(course.length, (engine.progress ?? 0) + 300))
        case .free(let f):
            target = course.point(at: min(course.length, f.upperBound + 50))
        }
        requesting = true
        lastRequest = Date()
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: loc.coordinate))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: target.lat, longitude: target.lon)))
        req.transportType = .automobile
        req.requestsAlternateRoutes = false
        MKDirections(request: req).calculate { [weak self] res, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.requesting = false
                guard self.active else { return }
                guard let route = res?.routes.first else {
                    NSLog("Apple の経路を取れません: \(String(describing: err))")
                    if case .back = kind { self.say(["戻る道を探せませんでした。コースに向かってください"]) }
                    return
                }
                let line = Navigator.line(of: route)
                self.detour = NaviEngine(line: line, isDetour: true)
                self.detourKind = kind
                self.detourLine = line
                var intro: String
                switch kind {
                case .back: intro = "コースに戻る道を案内します"
                case .free: intro = "ここからの一般道は、アップルの経路で案内します"
                }
                if let s = line.steps.first(where: { $0.kind != "arrive" }) {
                    intro += "。\(NaviSpeech.distance(max(0, s.at)))先、\(s.text)"
                }
                self.say([intro])
                self.updateBanner()
            }
        }
    }

    /// Apple の経路を、案内する線にする(手順の文は日本語の「右折して…」など)
    private static func line(of route: MKRoute) -> NaviLine {
        let n = route.polyline.pointCount
        let mp = route.polyline.points()
        var pts: [GeoPoint] = []
        pts.reserveCapacity(n)
        for k in 0..<n {
            let c = mp[k].coordinate
            pts.append(GeoPoint(lat: c.latitude, lon: c.longitude))
        }
        var steps: [NaviLine.Step] = []
        var at = 0.0
        for s in route.steps {
            let text = s.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && at > 0 {
                let angle: Double = text.contains("右") ? 90 : text.contains("左") ? -90 : 0
                steps.append(NaviLine.Step(at: at, kind: "apple", angle: angle, text: text, road: s.notice ?? ""))
            }
            at += s.distance
        }
        if pts.count < 2, let first = pts.first { pts.append(first) }
        let len = zip(pts, pts.dropFirst()).reduce(0.0) { $0 + geoDistance($1.0, $1.1) }
        steps.removeAll { $0.at >= len - 25 }
        steps.append(NaviLine.Step(at: len, kind: "arrive", angle: 0, text: "コースに戻る所", road: ""))
        return NaviLine(pts: pts, steps: steps)
    }

    // MARK: - 画面

    private func updateBanner() {
        guard let engine, let course else { return }
        let e = detour ?? engine
        var b = NaviBanner()
        b.offRoute = engine.offRoute && detour == nil
        b.detour = detour != nil
        if let rem = engine.remaining { b.remaining = NaviSpeech.label(rem) }
        if let p = engine.progress { b.current = course.road(at: p) }
        if engine.arrived {
            b.icon = "flag.checkered"
            b.text = "目的地に着きました"
        } else if b.offRoute {
            b.icon = "exclamationmark.triangle.fill"
            b.text = requesting ? "戻る道を探しています" : "コースから外れています"
            b.distance = NaviSpeech.label(engine.offDistance)
        } else if let s = e.nextStep, let d = e.distanceToNext {
            b.icon = Navigator.icon(s)
            b.distance = NaviSpeech.label(d)
            b.text = s.kind == "arrive" ? (detour != nil ? "コースに戻る所" : "目的地") : s.text
            b.road = s.road
        }
        if b != banner { banner = b }
    }

    static func icon(_ s: NaviLine.Step) -> String {
        let a = abs(s.angle)
        let right = s.angle > 0
        switch s.kind {
        case "arrive": return "flag.checkered"
        case "free": return "map"
        case "enterExp", "jct", "exitExp":
            return a < 3 ? "arrow.up" : right ? "arrow.up.right" : "arrow.up.left"
        default:
            if a < 25 { return "arrow.up" }
            if a < 55 { return right ? "arrow.up.right" : "arrow.up.left" }
            if a < 150 { return right ? "arrow.turn.up.right" : "arrow.turn.up.left" }
            return "arrow.uturn.down"
        }
    }

    // MARK: - 声

    private func say(_ texts: [String]) {
        let list = texts.filter { !$0.isEmpty }
        guard !list.isEmpty, !muted else { return }
        queue.async {
            let s = AVAudioSession.sharedInstance()
            do {
                // ナビの声: ほかの音(音楽・ほかのナビ)は小さくして、話し声のアプリは一時停止してもらう
                try s.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
                try s.setActive(true)
            } catch {
                NSLog("ナビの声のオーディオを設定できません: \(error)")
            }
            for t in list {
                let u = AVSpeechUtterance(string: t)
                u.voice = AVSpeechSynthesisVoice(language: "ja-JP")
                u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
                self.synth.speak(u)
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        restoreAudio()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        restoreAudio()
    }

    /// 読み終えたら、ほかの音の大きさを戻し、記録の合図の音(Beeper)の設定に戻す
    private func restoreAudio() {
        queue.asyncAfter(deadline: .now() + 0.3) {
            guard !self.synth.isSpeaking else { return }
            let s = AVAudioSession.sharedInstance()
            try? s.setActive(false, options: .notifyOthersOnDeactivation)
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
    }
}
