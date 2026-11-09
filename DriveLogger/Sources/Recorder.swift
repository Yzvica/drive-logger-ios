import CoreLocation
import CoreMotion
import UIKit

/// GPS・加速度・回転・気圧を記録する。位置情報のバックグラウンド更新でアプリが動き続けるので、
/// 画面を消しても、ほかのアプリを開いても記録が続く
final class Recorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Recorder()

    @Published private(set) var isRecording = false
    @Published private(set) var current: SessionMeta?
    @Published private(set) var speedMS: Double = 0
    @Published private(set) var horizontalAccuracy: Double = -1
    @Published private(set) var horizontalG: Double = 0
    /// GPS の高度(m)。測れていなければ nil
    @Published private(set) var altitudeM: Double?
    /// 記録中・直前に記録した移動手段
    @Published private(set) var mode: TravelMode = .car
    /// 直前に止めた車以外の移動(記録画面にまとめを出す)
    @Published var lastTrip: SessionMeta?
    /// 速度を位置の動きから推定している(トンネルなどで GPS の速度が来ないとき)
    @Published private(set) var speedEstimated = false
    /// 画面の上に少しのあいだ出す知らせ(「音を鳴らさない」設定のときの代わり)
    @Published private(set) var notice: (text: String, at: Date)?
    /// 速度の推定に使う、ひとつ前の位置
    private var prevForSpeed: CLLocation?
    private var estimatedSpeed: Double = 0

    /// 画面で知らせる(メインスレッドで呼ぶ)
    func showNotice(_ text: String) {
        let n = (text: text, at: Date())
        notice = n
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if self.notice?.at == n.at { self.notice = nil }
        }
    }

    /// GPS の受信状態(記録中のランプ)
    @Published private(set) var gpsStatus: GPSStatus = .searching
    /// 最後に使える位置(±50m 以内)が来た時刻(端末の起動からの秒)
    private var lastUsableFix: TimeInterval?
    private var lastFixAccuracy: Double = -1
    private var gpsTimer: Timer?
    @Published private(set) var track: [CLLocationCoordinate2D] = []
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published var flash = false
    /// 記録中のサポート(G の点・直近 5 分の点数・出来事の回数)
    @Published private(set) var coachState = CoachState()
    /// motionQueue の中だけで使う
    private var coach: LiveCoach?

    private let location = CLLocationManager()
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let motionQueue = OperationQueue()
    /// ファイルへの書き込みはこの順番待ちで1つずつ行う
    private let io = DispatchQueue(label: "recorder.io")

    private var gpx: GPXWriter?
    private var locationCSV: AppendFile?
    private var motionCSV: AppendFile?
    private var pressureCSV: AppendFile?
    private var meta: SessionMeta?
    private var lastGood: CLLocation?
    private var lastLocation: CLLocation?
    private var lastUIUpdate: TimeInterval = 0
    private var lastMetaSave: TimeInterval = 0

    private override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.distanceFilter = kCLDistanceFilterNone
        location.activityType = .automotiveNavigation
        location.pausesLocationUpdatesAutomatically = false
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInitiated
        authorization = location.authorizationStatus
    }

    // MARK: - 開始・停止

    func start() {
        guard !isRecording else { return }
        lastEvaluation = nil
        lastTrip = nil
        let mode = AppSettings.shared.travelMode
        self.mode = mode
        // 記録中のサポート(G の点・急な操作の音)は車のときだけ
        if mode.isCar {
            let c = LiveCoach()
            c.onEvent = { e in
                DispatchQueue.main.async {
                if AppSettings.shared.soundOff {
                    Recorder.shared.showNotice(e.rawValue)
                } else if AppSettings.shared.coachSound {
                    Beeper.shared.play(.coach(e))
                }
            }
            }
            coach = c
        } else {
            coach = nil
        }
        coachState = CoachState()
        altitudeM = nil
        prevForSpeed = nil
        estimatedSpeed = 0
        speedEstimated = false
        location.activityType = mode.activityType
        if keepingAliveForUpload {
            keepingAliveForUpload = false
            keepAliveDeadline?.cancel()
            keepAliveDeadline = nil
        }
        restoreRecordingAccuracy()
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        } else if location.authorizationStatus == .authorizedWhenInUse {
            // 画面を消しても続けるには「常に許可」が要る
            location.requestAlwaysAuthorization()
        }

        let now = Date()
        let id = Fmt.sessionID.string(from: now)
        let dir = LogStore.shared.dir(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let uptimeToUnix = now.timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        let info = Bundle.main.infoDictionary
        var m = SessionMeta(
            id: id, start: now, end: nil,
            device: Recorder.deviceModel(), systemVersion: UIDevice.current.systemVersion,
            appVersion: "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))",
            motionHz: mode.isCar ? AppSettings.shared.motionHz : TravelMode.tripMotionHz, uptimeToUnix: uptimeToUnix)
        m.points = 0
        m.mode = mode

        do {
            gpx = try GPXWriter(url: dir.appendingPathComponent("track.gpx"), name: id)
            locationCSV = try AppendFile(url: dir.appendingPathComponent("location.csv"), header:
                "unix_s,lat,lon,alt_m,h_acc_m,v_acc_m,speed_ms,speed_acc_ms,course_deg,course_acc_deg,floor\n",
                flushBytes: 8 * 1024)
            motionCSV = try AppendFile(url: dir.appendingPathComponent("motion.csv"), header:
                "unix_s,ax_g,ay_g,az_g,grav_x,grav_y,grav_z,rot_x_rads,rot_y_rads,rot_z_rads,q_w,q_x,q_y,q_z,heading_deg\n")
            pressureCSV = try AppendFile(url: dir.appendingPathComponent("pressure.csv"), header:
                "unix_s,pressure_hpa,rel_alt_m\n", flushBytes: 4 * 1024)
        } catch {
            NSLog("ファイルを作れません: \(error)")
            return
        }

        meta = m
        lastGood = nil
        lastLocation = nil
        LogStore.shared.save(m)
        current = m
        track = []
        isRecording = true
        updateIdleTimer()
        startGPSWatch()

        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
        location.startUpdatingHeading()
        startMotion(hz: m.motionHz, uptimeToUnix: uptimeToUnix)
        startAltimeter(uptimeToUnix: uptimeToUnix)

        // 車なら、記録を始めたときに動画と合わせる合図(光と音)を自動で1回出す。
        // 電車や飛行機の中では音を鳴らさない
        if mode.isCar { addMarker("sync") }
    }

    /// 停止ボタンから呼ぶ。止める直前に同期の合図(光と音)を出し、鳴り終わってから止める
    @Published private(set) var isStopping = false
    /// 止めたあと、評価を計算している間 true
    @Published private(set) var isEvaluating = false
    /// 直前に止めた走行の評価(記録画面に出す)
    @Published var lastEvaluation: (id: String, eval: Evaluation)?
    func stopWithSync() {
        guard isRecording, !isStopping else { return }
        guard mode.isCar else { stop(); return }
        isStopping = true
        addMarker("sync")
        // 同期音は 0.52 秒。少し余裕を持たせてから停止音を鳴らして止める
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            self.isStopping = false
            self.stop()
        }
    }

    /// 記録中で「記録中は画面を消さない」がオンのときだけ、画面の自動ロックを止める
    func updateIdleTimer() {
        let on = isRecording && AppSettings.shared.keepScreenOn
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = on }
    }

    func stop() {
        guard isRecording else { return }
        location.stopUpdatingHeading()
        if AppSettings.shared.autoUpload {
            // 送り終えるまでは、精度を落とした位置の更新を続けてアプリを起こしておく。
            // 止めるとすぐに眠ってしまい、画面を消したときにテザリングで送れない
            beginUploadKeepAlive()
        } else {
            location.stopUpdatingLocation()
            location.allowsBackgroundLocationUpdates = false
        }
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        stopGPSWatch()
        isRecording = false
        updateIdleTimer()
        motionQueue.waitUntilAllOperationsAreFinished()
        var finishedID: String?
        io.sync {
            gpx?.close(); locationCSV?.close(); motionCSV?.close(); pressureCSV?.close()
            gpx = nil; locationCSV = nil; motionCSV = nil; pressureCSV = nil
            if var m = meta {
                m.end = Date()
                LogStore.shared.save(m)
                finishedID = m.id
                meta = nil
            }
        }
        current = nil
        coach = nil
        // 車以外は音を鳴らさず、運転評価もしない
        guard mode.isCar else {
            lastTrip = finishedID.flatMap { LogStore.shared.load($0) }
            if AppSettings.shared.autoUpload { Uploader.shared.uploadPending() }
            return
        }
        if Beeper.shared.play(.stop) == nil { showNotice("記録を止めました") }
        // 運転評価を計算してから送る(evaluation.json も一緒に送り、地図ですぐ見られるようにする)
        guard let id = finishedID else {
            if AppSettings.shared.autoUpload { Uploader.shared.uploadPending() }
            return
        }
        isEvaluating = true
        LogStore.shared.evaluate(id) { [weak self] e in
            self?.isEvaluating = false
            self?.lastEvaluation = e.map { (id, $0) }
            if AppSettings.shared.autoUpload { Uploader.shared.uploadPending() }
        }
    }

    // MARK: - 送信が終わるまでアプリを起こしておく

    /// 記録を止めてから、送り終えるまで(最長この秒数)アプリを起こしておく
    static let uploadKeepAliveLimit: TimeInterval = 15 * 60
    @Published private(set) var keepingAliveForUpload = false
    private var keepAliveDeadline: DispatchWorkItem?

    private func beginUploadKeepAlive() {
        keepingAliveForUpload = true
        location.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        location.distanceFilter = 500
        location.allowsBackgroundLocationUpdates = true
        location.startUpdatingLocation()
        keepAliveDeadline?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.endUploadKeepAlive() }
        keepAliveDeadline = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Recorder.uploadKeepAliveLimit, execute: item)
    }

    /// 送り終えたとき(または諦めたとき)に呼ぶ
    func endUploadKeepAlive() {
        guard keepingAliveForUpload, !isRecording else { return }
        keepingAliveForUpload = false
        keepAliveDeadline?.cancel()
        keepAliveDeadline = nil
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        restoreRecordingAccuracy()
    }

    private func restoreRecordingAccuracy() {
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.distanceFilter = kCLDistanceFilterNone
        location.activityType = mode.activityType
    }

    // MARK: - 目印と動画の同期

    /// kind: "mark"(目印)か "sync"(動画と合わせる合図。画面を光らせて音を鳴らす)
    func addMarker(_ kind: String) {
        guard isRecording else { return }
        let loc = lastLocation
        let played: Date?
        if kind == "sync" {
            played = Beeper.shared.play(.sync)
            if played == nil { showNotice("同期の合図") }
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.flash = false }
        } else {
            played = Beeper.shared.play(.mark)
            if played == nil { showNotice("目印を付けました") }
        }
        // 時刻は音が出た瞬間に合わせる(動画の音声から同期の合図を探すため)
        let marker = Marker(kind: kind, time: played ?? Date(), lat: loc?.coordinate.latitude, lon: loc?.coordinate.longitude)
        io.async {
            self.meta?.markers.append(marker)
            if let m = self.meta { LogStore.shared.save(m) }
            DispatchQueue.main.async { self.current = self.meta }
        }
    }

    // MARK: - 位置

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if isRecording && manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations { handle(loc) }
    }

    private func handle(_ loc: CLLocation) {
        guard isRecording, loc.horizontalAccuracy >= 0 else { return }
        lastLocation = loc
        let t = loc.timestamp.timeIntervalSince1970
        let speed = loc.speed >= 0 ? loc.speed : nil
        let coord = loc.coordinate, acc = loc.horizontalAccuracy
        let altitude = loc.verticalAccuracy >= 0 ? loc.altitude : nil
        motionQueue.addOperation {
            self.coach?.addLocation(t: t, lat: coord.latitude, lon: coord.longitude, speed: speed, accuracy: acc)
        }
        let line = [
            Fmt.n(t, 3), Fmt.n(loc.coordinate.latitude, 7), Fmt.n(loc.coordinate.longitude, 7),
            loc.verticalAccuracy >= 0 ? Fmt.n(loc.altitude, 2) : "",
            Fmt.n(loc.horizontalAccuracy, 1), loc.verticalAccuracy >= 0 ? Fmt.n(loc.verticalAccuracy, 1) : "",
            speed.map { Fmt.n($0, 2) } ?? "", loc.speedAccuracy >= 0 ? Fmt.n(loc.speedAccuracy, 2) : "",
            loc.course >= 0 ? Fmt.n(loc.course, 1) : "", loc.courseAccuracy >= 0 ? Fmt.n(loc.courseAccuracy, 1) : "",
            loc.floor.map { String($0.level) } ?? "",
        ].joined(separator: ",") + "\n"

        // 地図に送る GPX と距離には、精度の良い点だけを使う
        let good = loc.horizontalAccuracy <= 50
        var addDistance = 0.0
        if good {
            if let prev = lastGood, loc.horizontalAccuracy <= 30 { addDistance = loc.distance(from: prev) }
            if loc.horizontalAccuracy <= 30 || lastGood == nil { lastGood = loc }
        }

        io.async {
            self.locationCSV?.append(line)
            guard good else { return }
            self.gpx?.add(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                          ele: loc.verticalAccuracy >= 0 ? loc.altitude : nil, time: loc.timestamp, speed: speed)
            if var m = self.meta {
                m.points += 1
                m.distanceM += addDistance
                if let s = speed { m.maxSpeedMS = max(m.maxSpeedMS, s) }
                if let a = altitude { m.maxAltitudeM = max(m.maxAltitudeM ?? a, a) }
                self.meta = m
            }
            // 落ちたときのため、30秒ごとに meta.json と書きかけのファイルを保存する
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastMetaSave > 30, let m = self.meta {
                self.lastMetaSave = now
                self.locationCSV?.flush(); self.motionCSV?.flush(); self.pressureCSV?.flush()
                LogStore.shared.save(m)
            }
        }

        DispatchQueue.main.async {
            self.lastFixAccuracy = acc
            if acc <= GPSStatus.usableAccuracy { self.lastUsableFix = ProcessInfo.processInfo.systemUptime }
            self.updateGPSStatus()
            self.updateDisplayedSpeed(loc, speed: speed)
            self.horizontalAccuracy = loc.horizontalAccuracy
            self.altitudeM = altitude
            if good { self.track.append(loc.coordinate) }
            self.io.async { let m = self.meta; DispatchQueue.main.async { if self.isRecording { self.current = m } } }
        }
    }

    // MARK: - 画面の速度

    /// GPS の速度が来ないとき(トンネルの中で iOS が位置だけを推測で動かしているときなど)は、
    /// ひとつ前の位置からの距離÷時間で速度を推定して出す。ファイルには推定値を書かない(画面だけ)
    private func updateDisplayedSpeed(_ loc: CLLocation, speed: Double?) {
        defer { prevForSpeed = loc }
        if let s = speed {
            speedMS = s
            estimatedSpeed = s
            speedEstimated = false
            return
        }
        guard let prev = prevForSpeed else { speedMS = 0; return }
        let dt = loc.timestamp.timeIntervalSince(prev.timestamp)
        guard dt >= 0.5, dt <= 10 else {
            if dt > 10 { speedMS = 0; speedEstimated = false }
            return
        }
        let raw = loc.distance(from: prev) / dt
        // 位置のぶれで跳ねないよう、少しならす
        estimatedSpeed = estimatedSpeed * 0.6 + raw * 0.4
        speedMS = estimatedSpeed
        speedEstimated = true
    }

    // MARK: - GPS の受信状態

    private func startGPSWatch() {
        lastUsableFix = nil
        lastFixAccuracy = -1
        gpsStatus = .searching
        gpsTimer?.invalidate()
        // 位置が来なくなったことは位置の通知では分からないので、1秒ごとに確かめる
        // (記録中は位置情報のバックグラウンド更新でアプリが起きているので、画面を消しても動く)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.updateGPSStatus()
            Watchdog.arm(mode: self.mode)
        }
        RunLoop.main.add(t, forMode: .common)
        gpsTimer = t
        Watchdog.requestPermission()
        Watchdog.arm(mode: mode, force: true)
    }

    private func stopGPSWatch() {
        gpsTimer?.invalidate()
        gpsTimer = nil
        gpsStatus = .searching
        Watchdog.disarm()
    }

    /// メインスレッドで呼ぶ
    private func updateGPSStatus() {
        guard isRecording else { return }
        let next: GPSStatus
        if let last = lastUsableFix {
            if ProcessInfo.processInfo.systemUptime - last > GPSStatus.lostAfter {
                next = .lost
            } else {
                next = lastFixAccuracy >= 0 && lastFixAccuracy <= GPSStatus.goodAccuracy ? .good : .weak
            }
        } else {
            next = .searching
        }
        guard next != gpsStatus else { return }
        let prev = gpsStatus
        gpsStatus = next
        guard AppSettings.shared.gpsVibrate else { return }
        if next == .lost && prev.receiving {
            GPSHaptics.lost()
        } else if next.receiving && (prev == .lost || prev == .searching) {
            GPSHaptics.back()
        }
    }

    // MARK: - 加速度・回転

    private func startMotion(hz: Int, uptimeToUnix: Double) {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / Double(max(1, hz))
        let frame: CMAttitudeReferenceFrame =
            CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical)
            ? .xMagneticNorthZVertical : .xArbitraryCorrectedZVertical
        motion.startDeviceMotionUpdates(using: frame, to: motionQueue) { [weak self] dm, _ in
            guard let self, let dm else { return }
            let a = dm.userAcceleration, g = dm.gravity, r = dm.rotationRate, q = dm.attitude.quaternion
            let heading = frame == .xMagneticNorthZVertical && dm.heading >= 0 ? Fmt.n(dm.heading, 1) : ""
            let line = [
                Fmt.n(dm.timestamp + uptimeToUnix, 3),
                Fmt.n(a.x, 4), Fmt.n(a.y, 4), Fmt.n(a.z, 4),
                Fmt.n(g.x, 4), Fmt.n(g.y, 4), Fmt.n(g.z, 4),
                Fmt.n(r.x, 4), Fmt.n(r.y, 4), Fmt.n(r.z, 4),
                Fmt.n(q.w, 5), Fmt.n(q.x, 5), Fmt.n(q.y, 5), Fmt.n(q.z, 5), heading,
            ].joined(separator: ",") + "\n"
            self.io.async { self.motionCSV?.append(line) }
            self.coach?.addMotion(t: dm.timestamp + uptimeToUnix, a: Vec3(a.x, a.y, a.z),
                                  g: Vec3(g.x, g.y, g.z), r: Vec3(r.x, r.y, r.z))

            // 画面に出す横方向の G(重力に垂直な成分の大きさ)。車の向きへの座標合わせは第2段で行う
            let dot = a.x * g.x + a.y * g.y + a.z * g.z
            let hx = a.x - dot * g.x, hy = a.y - dot * g.y, hz = a.z - dot * g.z
            let hg = (hx * hx + hy * hy + hz * hz).squareRoot()
            if dm.timestamp - self.lastUIUpdate > 0.2 {
                self.lastUIUpdate = dm.timestamp
                let cs = self.coach?.state
                DispatchQueue.main.async {
                    self.horizontalG = hg
                    if let cs { self.coachState = cs }
                }
            }
        }
    }

    // MARK: - 気圧

    private func startAltimeter(uptimeToUnix: Double) {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: motionQueue) { [weak self] data, _ in
            guard let self, let data else { return }
            let line = [
                Fmt.n(data.timestamp + uptimeToUnix, 3),
                Fmt.n(data.pressure.doubleValue * 10, 3), // kPa → hPa
                Fmt.n(data.relativeAltitude.doubleValue, 2),
            ].joined(separator: ",") + "\n"
            self.io.async { self.pressureCSV?.append(line) }
        }
    }

    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
