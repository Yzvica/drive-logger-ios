import MapKit
import SwiftUI

/// 地図の種類
enum MapStyle: String, CaseIterable, Identifiable {
    case appleStandard, appleSatellite, gsiStd, gsiPale, gsiPhoto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleStandard: return "Apple 標準"
        case .appleSatellite: return "Apple 航空写真"
        case .gsiStd: return "地理院 標準"
        case .gsiPale: return "地理院 淡色"
        case .gsiPhoto: return "地理院 写真"
        }
    }

    /// 国土地理院のタイル(https://maps.gsi.go.jp/development/ichiran.html)。Apple の地図なら nil
    var gsiTemplate: String? {
        switch self {
        case .gsiStd: return "https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png"
        case .gsiPale: return "https://cyberjapandata.gsi.go.jp/xyz/pale/{z}/{x}/{y}.png"
        case .gsiPhoto: return "https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg"
        default: return nil
        }
    }
}

/// 走行中の軌跡を表示する地図(iOS 16 でも使えるよう MKMapView を使う)。
/// 右上のボタンで「追尾しない → 北が上で追尾 → 進行方向が上で追尾」を切り替える。
/// MapKit の追尾(userTrackingMode)は、自前の片手ズームで変えた距離を次の更新で元に戻してしまうので使わず、
/// 位置が更新されるたびに自分で地図の中心と向きを合わせる(距離はそのまま残す)
struct TrackMapView: UIViewRepresentable {
    var track: [CLLocationCoordinate2D]
    var style: MapStyle
    /// 追尾の向き(true なら進行方向が上)。ボタンで切り替えると書き換わる
    @Binding var headingUp: Bool
    /// ダブルタップして上下に動かす拡大縮小を、下で拡大(Google マップと同じ)にする
    var zoomDownIn: Bool = false

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        // 標準の方位磁針は右上の追尾ボタンに重なるので消し、ボタンの下に自分で置く
        map.showsCompass = false
        context.coordinator.follow = headingUp ? .headingUp : .northUp

        let button = UIButton(type: .system)
        button.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapFollow), for: .touchUpInside)
        map.addSubview(button)
        context.coordinator.button = button
        context.coordinator.updateButton()

        let compass = MKCompassButton(mapView: map)
        compass.compassVisibility = .adaptive // 北が上でないときだけ出す
        compass.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(compass)

        let credit = UILabel()
        credit.text = "出典: 国土地理院"
        credit.font = .systemFont(ofSize: 10)
        credit.textColor = .label
        credit.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.7)
        credit.translatesAutoresizingMaskIntoConstraints = false
        credit.isHidden = true
        map.addSubview(credit)
        context.coordinator.credit = credit

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: map.topAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -8),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
            compass.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 8),
            compass.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            credit.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -4),
            credit.bottomAnchor.constraint(equalTo: map.bottomAnchor, constant: -4),
        ])
        apply(style, to: map, context: context)

        // ダブルタップして上下に動かす拡大縮小を自前で行う(向きを選べるようにするため)
        context.coordinator.zoom.install(on: map, downIn: zoomDownIn)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.style != style { apply(style, to: map, context: context) }
        context.coordinator.zoom.update(map, downIn: zoomDownIn)

        // 軌跡は TrackMapView.chunk 点ずつの線に分け、伸びていく最後の1本だけを 10 点ごとに引き直す。
        // 全体を1本の線で引き直すと、長い走行(数千点)では引き直すたびに地図全体の線を描き直すことになり、
        // 非力な端末(iPhone X)では走るほど重くなって固まる原因になる
        let c = context.coordinator
        if track.count < c.drawnCount {
            // 新しい記録が始まった
            map.removeOverlays(c.fixedLines)
            if let old = c.line { map.removeOverlay(old) }
            c.fixedLines = []
            c.fixedCount = 0
            c.line = nil
            c.drawnCount = 0
        }
        guard track.count != c.drawnCount,
              track.count < 2 || track.count - c.drawnCount >= 10
        else { return }
        // 決まった(もう伸びない)ぶんを固定の線にする。つなぎ目が切れないよう、前の線の最後の点から始める
        while track.count - c.fixedCount > TrackMapView.chunk {
            let from = max(0, c.fixedCount - 1), to = c.fixedCount + TrackMapView.chunk
            let line = TrackMapView.polyline(track[from..<to])
            c.fixedLines.append(line)
            map.addOverlay(line, level: .aboveLabels)
            c.fixedCount = to
        }
        c.drawnCount = track.count
        if let old = c.line { map.removeOverlay(old) }
        c.line = nil
        let tail = track[max(0, c.fixedCount - 1)...]
        guard tail.count >= 2 else { return }
        let line = TrackMapView.polyline(tail)
        c.line = line
        map.addOverlay(line, level: .aboveLabels)
    }

    /// 固定の線1本の点の数
    static let chunk = 300

    private static func polyline(_ points: ArraySlice<CLLocationCoordinate2D>) -> MKPolyline {
        let a = Array(points)
        return MKPolyline(coordinates: a, count: a.count)
    }

    private func apply(_ style: MapStyle, to map: MKMapView, context: Context) {
        let c = context.coordinator
        c.style = style
        if let old = c.tiles { map.removeOverlay(old) }
        c.tiles = nil
        if let template = style.gsiTemplate {
            let tiles = MKTileOverlay(urlTemplate: template)
            tiles.canReplaceMapContent = true
            tiles.minimumZ = 2
            tiles.maximumZ = 18 // 地理院タイルは 18 まで。それより寄ると 18 を拡大して表示する
            c.tiles = tiles
            // 軌跡の線より下に置く
            map.insertOverlay(tiles, at: 0, level: .aboveLabels)
            map.mapType = .standard
            // 18 を超えて寄ると粗くなるので、寄れる距離を制限する
            map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 250)
        } else {
            map.mapType = style == .appleSatellite ? .satellite : .standard
            map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 50)
        }
        c.credit?.isHidden = style.gsiTemplate == nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// 追尾のしかた
    enum Follow { case off, northUp, headingUp }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TrackMapView
        let zoom = OneFingerZoom()
        weak var map: MKMapView?
        weak var button: UIButton?
        var follow: Follow = .northUp
        /// 最後に分かった進行方向(止まっていると GPS の向きが出ないので覚えておく)
        var lastCourse: CLLocationDirection = 0
        /// 最初の位置で、街の様子が分かるくらいまで寄せたか
        var zoomedIn = false
        var drawnCount = 0
        /// 伸びていく最後の線
        var line: MKPolyline?
        /// もう伸びない線と、そこまでの点の数
        var fixedLines: [MKPolyline] = []
        var fixedCount = 0
        var tiles: MKTileOverlay?
        var style: MapStyle?
        weak var credit: UILabel?

        init(parent: TrackMapView) { self.parent = parent }

        func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
            if zoom.applied == nil { zoom.apply(mapView, downIn: parent.zoomDownIn) }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = .systemRed
            r.lineWidth = 4
            return r
        }

        /// 右上のボタン: 追尾しない → 北が上 → 進行方向が上 → 追尾しない(MapKit の追尾ボタンと同じ順)
        @objc func tapFollow() {
            switch follow {
            case .off: follow = .northUp
            case .northUp: follow = .headingUp
            case .headingUp: follow = .off
            }
            // 選んだ向きを覚える(指で動かして追尾が外れたときは覚えない)
            if follow != .off {
                let up = follow == .headingUp
                if parent.headingUp != up { DispatchQueue.main.async { self.parent.headingUp = up } }
            }
            updateButton()
            if let map { recenter(map, animated: true) }
        }

        func updateButton() {
            let name: String
            switch follow {
            case .off: name = "location"
            case .northUp: name = "location.fill"
            case .headingUp: name = "location.north.line.fill"
            }
            button?.setImage(UIImage(systemName: name), for: .normal)
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            if let loc = userLocation.location, loc.course >= 0, loc.speed > 1 { lastCourse = loc.course }
            recenter(mapView, animated: true)
        }

        /// 追尾中なら、距離はそのままで現在地を真ん中に、向きを北か進行方向に合わせる
        func recenter(_ map: MKMapView, animated: Bool) {
            guard follow != .off, let loc = map.userLocation.location else { return }
            // 指で拡大縮小しているあいだは動かさない(指を離したあとの更新で合わせる)
            if zoom.zooming || userIsTouching(map) { return }
            let cam = map.camera.copy() as! MKMapCamera
            cam.centerCoordinate = loc.coordinate
            cam.heading = follow == .headingUp ? lastCourse : 0
            if !zoomedIn {
                zoomedIn = true
                cam.centerCoordinateDistance = 2000
                map.setCamera(cam, animated: false)
            } else {
                map.setCamera(cam, animated: animated)
            }
        }

        /// 指で地図を引きずったら追尾をやめる(拡大縮小や回転だけなら続ける)
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            guard follow != .off, !zoom.zooming else { return }
            if activeGestures(in: mapView).contains(where: { g in
                g is UIPanGestureRecognizer && g.numberOfTouches == 1
                    && String(describing: type(of: g)).range(of: "OneHanded", options: .caseInsensitive) == nil
            }) {
                follow = .off
                updateButton()
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
