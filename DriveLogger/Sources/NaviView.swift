import MapKit
import SwiftUI

/// ナビのタブ。案内中は地図と次の案内、そうでなければコースの一覧(受け取り・開始)
struct NaviView: View {
    @ObservedObject private var navi = Navigator.shared

    var body: some View {
        if navi.active {
            NaviRunView()
        } else {
            NaviCourseList()
        }
    }
}

/// コースの一覧。MiniPC から受け取って、この iPhone に保存したものから案内を始める
struct NaviCourseList: View {
    @ObservedObject private var store = NaviStore.shared

    var body: some View {
        NavigationView {
            List {
                Section {
                    if store.saved.isEmpty {
                        Text("まだありません。下の「MiniPC のコース」から受け取ってください")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.saved, id: \.name) { g in
                        Button {
                            Navigator.shared.start(g)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                    .font(.title2)
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(g.name).font(.headline).foregroundStyle(.primary)
                                    Text("\(NaviSpeech.label(g.length))・案内 \(g.man.count) か所\(NaviCourseList.date(g.savedAt))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("開始").font(.subheadline.bold())
                            }
                        }
                    }
                    .onDelete { idx in
                        for i in idx { store.delete(store.saved[i]) }
                    }
                } header: {
                    Text("この iPhone のコース(押すと案内を始めます)")
                }

                Section {
                    ForEach(store.server) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name)
                                if let g = c.guide {
                                    Text("\(NaviSpeech.label(g.length))・案内 \(g.maneuvers) か所\(NaviCourseList.date(c.savedAt))")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("案内のデータなし(地図で道筋を出してから保存し直してください)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if c.guide != nil {
                                if store.isSaved(c) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else {
                                    Button("受け取る") { store.download(c) }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    Button {
                        store.refresh()
                    } label: {
                        Label(store.loading ? "読み込み中…" : "MiniPC から一覧を読む", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.loading)
                    if let m = store.message {
                        Text(m).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("MiniPC のコース")
                } footer: {
                    Text("地図の「🧭 ナビ・コース」で道筋を出してから保存したコース(📱)を受け取れます。家の Wi-Fi で受け取っておけば、走行中は MiniPC につながらなくても案内します。"
                        + "声は CarPlay につないでいれば車のスピーカーから出ます(CarPlay の画面には出せません)。"
                        + "コースから外れたときと一般道(点線)の区間は、Apple の経路で案内します(通信を使います)。")
                }
            }
            .navigationTitle("ナビ")
            .onAppear {
                store.loadLocal()
                if store.server.isEmpty { store.refresh() }
            }
        }
        .navigationViewStyle(.stack)
    }

    static func date(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter.withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        return "・\(Display.date.string(from: d))"
    }
}

extension ISO8601DateFormatter {
    /// 地図サーバーの日時(2026-11-23T10:54:21.123Z)
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// 案内中の画面: 上に次の案内、真ん中に地図、下に残りの距離と終了ボタン
struct NaviRunView: View {
    @ObservedObject private var navi = Navigator.shared
    @State private var confirmStop = false

    var body: some View {
        let b = navi.banner
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: b.icon)
                    .font(.system(size: 46, weight: .bold))
                    .frame(width: 64)
                VStack(alignment: .leading, spacing: 2) {
                    if !b.distance.isEmpty {
                        Text(b.distance).font(.system(size: 34, weight: .bold)).monospacedDigit()
                    }
                    Text(b.text).font(.title3.bold()).lineLimit(2).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(b.offRoute ? Color.red : b.detour ? Color.purple : Color(red: 0.05, green: 0.45, blue: 0.25))

            NaviMapView(course: navi.course, detour: navi.detourLine, location: navi.location, zoomDownIn: AppSettings.shared.oneFingerZoomDownIn)
                .ignoresSafeArea(edges: .horizontal)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("残り \(b.remaining)").font(.headline).monospacedDigit()
                    Text(b.detour ? "Apple の経路で案内中" : b.current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !navi.address.isEmpty {
                        Label(navi.address, systemImage: "mappin.and.ellipse")
                            .font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                Spacer()
                Button {
                    navi.muted.toggle()
                } label: {
                    Image(systemName: navi.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.title2)
                        .frame(width: 52, height: 44)
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) {
                    confirmStop = true
                } label: {
                    Text("終了").font(.headline).frame(width: 64, height: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .confirmationDialog("案内を終わりますか?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("終了する", role: .destructive) { navi.stop() }
        }
    }
}

/// 案内中の地図。コースの線(青)と Apple の経路(紫)を描き、進行方向を上にして現在地を追う。
/// 指で動かすと追うのをやめ、右上のボタンで戻す
struct NaviMapView: UIViewRepresentable {
    var course: NaviLine?
    var detour: NaviLine?
    var location: CLLocation?
    var zoomDownIn: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false

        let button = UIButton(type: .system)
        button.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        button.layer.cornerRadius = 8
        button.setImage(UIImage(systemName: "location.north.line.fill"), for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapFollow), for: .touchUpInside)
        map.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: map.topAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -8),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        context.coordinator.button = button
        context.coordinator.zoom.install(on: map, downIn: zoomDownIn)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.zoom.update(map, downIn: zoomDownIn)
        // 線は変わったときだけ引き直す(コースは数千点あるので)
        let courseKey = course.map { "\($0.pts.count)-\($0.length)" } ?? ""
        if courseKey != c.courseKey {
            c.courseKey = courseKey
            if let old = c.courseLine { map.removeOverlay(old) }
            c.courseLine = nil
            if let course {
                let line = NaviMapView.polyline(course.pts)
                line.title = "course"
                c.courseLine = line
                map.addOverlay(line, level: .aboveRoads)
            }
        }
        let detourKey = detour.map { "\($0.pts.count)-\($0.length)" } ?? ""
        if detourKey != c.detourKey {
            c.detourKey = detourKey
            if let old = c.detourLine { map.removeOverlay(old) }
            c.detourLine = nil
            if let detour {
                let line = NaviMapView.polyline(detour.pts)
                line.title = "detour"
                c.detourLine = line
                map.addOverlay(line, level: .aboveRoads)
            }
        }
        if let loc = location { c.follow(map, loc) }
    }

    private static func polyline(_ pts: [GeoPoint]) -> MKPolyline {
        let coords = pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        return MKPolyline(coordinates: coords, count: coords.count)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let zoom = OneFingerZoom()
        weak var map: MKMapView?
        weak var button: UIButton?
        var courseKey = ""
        var detourKey = ""
        var courseLine: MKPolyline?
        var detourLine: MKPolyline?
        var following = true
        var zoomedIn = false
        var lastCourse: CLLocationDirection = 0

        func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
            if zoom.applied == nil, let map { zoom.apply(map, downIn: AppSettings.shared.oneFingerZoomDownIn) }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            if line.title == "detour" {
                r.strokeColor = UIColor.systemPurple
                r.lineWidth = 7
            } else {
                r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.75)
                r.lineWidth = 7
            }
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }

        @objc func tapFollow() {
            following = true
            button?.setImage(UIImage(systemName: "location.north.line.fill"), for: .normal)
            if let map, let loc = map.userLocation.location { follow(map, loc) }
        }

        /// 進行方向を上にして、現在地を画面の少し下に置く(先が見えるように)
        func follow(_ map: MKMapView, _ loc: CLLocation) {
            if loc.course >= 0 && loc.speed > 1 { lastCourse = loc.course }
            guard following, !zoom.zooming, !userIsTouching(map) else { return }
            let cam = map.camera.copy() as! MKMapCamera
            cam.heading = lastCourse
            if !zoomedIn {
                zoomedIn = true
                cam.centerCoordinateDistance = 1200
            }
            // 現在地より、画面の高さの 1/4 ぶん進行方向の先を真ん中にする
            let ahead = cam.centerCoordinateDistance * 0.35
            let r = lastCourse * .pi / 180
            let lat = loc.coordinate.latitude + ahead * cos(r) / 110_950
            let lon = loc.coordinate.longitude + ahead * sin(r) / (111_320 * cos(loc.coordinate.latitude * .pi / 180))
            cam.centerCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            cam.pitch = 0
            map.setCamera(cam, animated: true)
        }

        /// 指で地図を引きずったら追うのをやめる
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            guard following, !zoom.zooming else { return }
            if activeGestures(in: mapView).contains(where: { g in
                g is UIPanGestureRecognizer && g.numberOfTouches == 1
                    && String(describing: type(of: g)).range(of: "OneHanded", options: .caseInsensitive) == nil
            }) {
                following = false
                button?.setImage(UIImage(systemName: "location"), for: .normal)
            }
        }

        private func userIsTouching(_ map: MKMapView) -> Bool { !activeGestures(in: map).isEmpty }

        private func activeGestures(in view: UIView) -> [UIGestureRecognizer] {
            var found = (view.gestureRecognizers ?? []).filter { $0.state == .began || $0.state == .changed }
            for sub in view.subviews { found += activeGestures(in: sub) }
            return found
        }
    }
}
