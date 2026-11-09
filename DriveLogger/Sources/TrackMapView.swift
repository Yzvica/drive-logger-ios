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
/// 右上のボタンで「追尾しない → 北が上で追尾 → 進行方向が上で追尾」を切り替える
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
        map.setUserTrackingMode(headingUp ? .followWithHeading : .follow, animated: false)

        let button = MKUserTrackingButton(mapView: map)
        button.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(button)

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
            compass.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 8),
            compass.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            credit.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -4),
            credit.bottomAnchor.constraint(equalTo: map.bottomAnchor, constant: -4),
        ])
        apply(style, to: map, context: context)

        // ダブルタップして上下に動かす拡大縮小を自前で行う(向きを選べるようにするため)
        context.coordinator.zoom.install(on: map, downIn: zoomDownIn)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.style != style { apply(style, to: map, context: context) }
        context.coordinator.zoom.update(map, downIn: zoomDownIn)

        // 点が増えるたびに作り直すと重いので、10点ごとに線を引き直す
        let c = context.coordinator
        guard track.count != c.drawnCount,
              track.count < 2 || track.count - c.drawnCount >= 10 || track.count < c.drawnCount
        else { return }
        c.drawnCount = track.count
        if let old = c.line { map.removeOverlay(old) }
        c.line = nil
        guard track.count >= 2 else { return }
        let line = MKPolyline(coordinates: track, count: track.count)
        c.line = line
        map.addOverlay(line, level: .aboveLabels)
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

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TrackMapView
        let zoom = OneFingerZoom()
        var drawnCount = 0
        var line: MKPolyline?
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

        /// ボタンで選んだ向きを覚える(指で動かして追尾が外れたときは覚えない)
        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            switch mode {
            case .follow: if parent.headingUp { DispatchQueue.main.async { self.parent.headingUp = false } }
            case .followWithHeading: if !parent.headingUp { DispatchQueue.main.async { self.parent.headingUp = true } }
            default: break
            }
        }
    }
}
