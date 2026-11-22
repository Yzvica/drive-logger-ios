import MapKit
import SwiftUI

/// 振り返りの地図。軌跡を速度で色分けし、出来事のピン、カーブ・停止・発進の点数の色の丸と、グラフで選んだ時刻の丸を出す。
/// 軌跡かピンをタップすると onPick(点の位置)を呼ぶ
struct ReviewMapView: UIViewRepresentable {
    let samples: [ReviewSample]
    let events: [EvalEvent]
    /// 区間ごとの採点(カーブ・停止・発進)。点数の色の小さな丸を置き、押すと onSegment を呼ぶ
    var segments: [EvalSegment] = []
    let style: MapStyle
    /// グラフで選んでいる点(nil なら丸を出さない)
    let cursor: Int?
    /// この点の時刻を地図の中心に寄せる(出来事を選んだときなど)。値が変わったときだけ動かす
    let focus: Int?
    /// ダブルタップして上下に動かす拡大縮小を、下で拡大にする(設定の値)
    var zoomDownIn: Bool = false
    /// 再生中の位置(点と点の間を補ったもの)。nil なら cursor の点に丸を置く
    var playPosition: CLLocationCoordinate2D? = nil
    /// 再生中の進む向き(北から時計回りの度)。nil なら矢印を出さない
    var heading: Double? = nil
    /// 再生中、丸を地図の真ん中に置き続ける
    var follow: Bool = false
    /// 手で地図を動かしたとき(追尾をやめるため)
    var onUserPan: () -> Void = {}
    /// 区間の丸を押したとき
    var onSegment: (EvalSegment) -> Void = { _ in }
    let onPick: (Int) -> Void

    /// 速度の色分け(km/h の上限と色)
    static let speedBands: [(maxKmh: Double, color: UIColor)] = [
        (20, .systemBlue), (40, .systemTeal), (60, .systemGreen), (80, .systemYellow), (100, .systemOrange),
        (.infinity, .systemRed),
    ]

    static func band(_ kmh: Double) -> Int {
        speedBands.firstIndex { kmh < $0.maxKmh } ?? speedBands.count - 1
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        let c = context.coordinator
        c.map = map

        let credit = UILabel()
        credit.text = "出典: 国土地理院"
        credit.font = .systemFont(ofSize: 10)
        credit.textColor = .label
        credit.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.7)
        credit.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(credit)
        c.credit = credit
        NSLayoutConstraint.activate([
            credit.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -4),
            credit.bottomAnchor.constraint(equalTo: map.bottomAnchor, constant: -4),
        ])

        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = c
        map.addGestureRecognizer(tap)

        c.zoom.install(on: map, downIn: zoomDownIn)

        applyStyle(map, c)
        drawTrack(map, c)
        drawSegments(map, c)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.style != style { applyStyle(map, c) }
        c.zoom.update(map, downIn: zoomDownIn)
        if c.drawnCount != samples.count { drawTrack(map, c) }
        if c.drawnSegments != segments { drawSegments(map, c) }

        let dotCoord = playPosition ?? cursor.flatMap { i in
            samples.indices.contains(i) ? CLLocationCoordinate2D(latitude: samples[i].lat, longitude: samples[i].lon) : nil
        }
        if let coord = dotCoord {
            if let dot = c.dot {
                dot.coordinate = coord
            } else {
                let dot = CursorAnnotation()
                dot.coordinate = coord
                map.addAnnotation(dot)
                c.dot = dot
            }
        } else if let dot = c.dot {
            map.removeAnnotation(dot)
            c.dot = nil
        }
        if let dot = c.dot, let v = map.view(for: dot) { c.orient(v, heading: heading, map: map) }

        // 再生中の追尾: 丸を真ん中に置き続ける(手で動かしたら呼び出し側が follow を切る)
        if follow, let coord = playPosition {
            c.followed = cursor
            c.focused = focus
            if !c.userPanning { map.setCenter(coord, animated: false) }
            return
        }

        if focus != c.focused {
            c.focused = focus
            if let i = focus, samples.indices.contains(i) {
                let coord = CLLocationCoordinate2D(latitude: samples[i].lat, longitude: samples[i].lon)
                if !map.visibleMapRect.contains(MKMapPoint(coord)) || map.region.span.latitudeDelta > 0.05 {
                    map.setRegion(MKCoordinateRegion(center: coord, latitudinalMeters: 1500, longitudinalMeters: 1500),
                                  animated: true)
                } else {
                    map.setCenter(coord, animated: true)
                }
            }
        } else if cursor != c.followed, let i = cursor, samples.indices.contains(i) {
            // グラフをなぞって丸が地図の外(端の近く)へ出たら、拡大はそのままで丸を中心に戻す。
            // 丸が動いたときだけ見るので、地図を手で動かしてよそを見ているあいだは戻さない
            let coord = CLLocationCoordinate2D(latitude: samples[i].lat, longitude: samples[i].lon)
            let inner = map.bounds.insetBy(dx: min(28, map.bounds.width / 4), dy: min(28, map.bounds.height / 4))
            if !inner.isEmpty, !inner.contains(map.convert(coord, toPointTo: map)) {
                map.setCenter(coord, animated: true)
            }
        }
        c.followed = cursor
    }

    private func applyStyle(_ map: MKMapView, _ c: Coordinator) {
        c.style = style
        if let old = c.tiles { map.removeOverlay(old) }
        c.tiles = nil
        if let template = style.gsiTemplate {
            let tiles = MKTileOverlay(urlTemplate: template)
            tiles.canReplaceMapContent = true
            tiles.minimumZ = 2
            tiles.maximumZ = 18
            c.tiles = tiles
            map.insertOverlay(tiles, at: 0, level: .aboveLabels)
            map.mapType = .standard
        } else {
            map.mapType = style == .appleSatellite ? .satellite : .standard
        }
        c.credit?.isHidden = style.gsiTemplate == nil
    }

    /// 区間ごとの採点の丸(評価を計算し直したときは置き直す)
    private func drawSegments(_ map: MKMapView, _ c: Coordinator) {
        map.removeAnnotations(c.segPins)
        c.segPins = []
        c.drawnSegments = segments
        for (k, sg) in segments.enumerated() {
            let pin = SegmentAnnotation()
            pin.coordinate = CLLocationCoordinate2D(latitude: sg.lat, longitude: sg.lon)
            pin.title = "\(sg.name) \(String(format: "%.0f", sg.score))点"
            pin.subtitle = "\(Display.time.string(from: Date(timeIntervalSince1970: sg.tUnix)))・\(SegStyle.marks(sg))"
            pin.segmentIndex = k
            pin.score = sg.score
            c.segPins.append(pin)
        }
        map.addAnnotations(c.segPins)
    }

    /// 同じ色が続く区間を 1 本の線にする(線の数を減らして軽くする)
    private func drawTrack(_ map: MKMapView, _ c: Coordinator) {
        map.removeOverlays(c.lines)
        map.removeAnnotations(c.pins)
        c.lines = []
        c.pins = []
        c.drawnCount = samples.count
        guard samples.count >= 2 else { return }

        var start = 0
        var band = ReviewMapView.band(samples[0].kmh)
        for i in 1..<samples.count {
            let b = ReviewMapView.band(samples[i].kmh)
            if b != band || i == samples.count - 1 {
                var coords = samples[start...i].map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let line = BandPolyline(coordinates: &coords, count: coords.count)
                line.band = band
                c.lines.append(line)
                start = i
                band = b
            }
        }
        map.addOverlays(c.lines, level: .aboveLabels)

        for (k, e) in events.enumerated() {
            let pin = EventAnnotation()
            pin.coordinate = CLLocationCoordinate2D(latitude: e.lat, longitude: e.lon)
            pin.title = e.kind
            pin.subtitle = "\(Display.time.string(from: Date(timeIntervalSince1970: e.tUnix)))・\(EvalStyle.event(e))"
            pin.eventIndex = k
            c.pins.append(pin)
        }
        map.addAnnotations(c.pins)

        let rect = c.lines.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24), animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class BandPolyline: MKPolyline {
        var band = 0
    }

    final class EventAnnotation: MKPointAnnotation {
        var eventIndex = 0
    }

    final class SegmentAnnotation: MKPointAnnotation {
        var segmentIndex = 0
        var score = 0.0
    }

    final class CursorAnnotation: MKPointAnnotation {}

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: ReviewMapView
        weak var map: MKMapView?
        weak var credit: UILabel?
        var tiles: MKTileOverlay?
        var style: MapStyle?
        var lines: [BandPolyline] = []
        var pins: [EventAnnotation] = []
        var segPins: [SegmentAnnotation] = []
        var drawnSegments: [EvalSegment] = []
        var dot: CursorAnnotation?
        var drawnCount = -1
        var focused: Int?
        /// 追尾を確かめた最後の点(丸が動いたときだけ追尾する)
        var followed: Int?
        /// 指で地図を動かしている間
        var userPanning = false
        let zoom = OneFingerZoom()

        /// 再生中の丸に向きの矢印を付ける(地図が回っていればその分を引く)
        func orient(_ v: MKAnnotationView, heading: Double?, map: MKMapView) {
            let arrow = v.viewWithTag(7)
            arrow?.isHidden = heading == nil
            let deg = (heading ?? 0) - map.camera.heading
            v.transform = heading == nil ? .identity : CGAffineTransform(rotationAngle: deg * .pi / 180)
        }

        /// 地図が動き始めたとき、指で動かしたのか(追尾をやめる)、プログラムで動かしたのかを見分ける
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            let touching = mapView.subviews.first?.gestureRecognizers?.contains { $0.state == .began || $0.state == .changed } ?? false
            if touching {
                userPanning = true
                if parent.follow { parent.onUserPan() }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            userPanning = false
        }

        init(parent: ReviewMapView) { self.parent = parent }

        func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
            if zoom.applied == nil { zoom.apply(mapView, downIn: parent.zoomDownIn) }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            guard let line = overlay as? BandPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = ReviewMapView.speedBands[line.band].color
            r.lineWidth = 5
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is CursorAnnotation {
                let id = "cursor"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                let size: CGFloat = 18
                v.frame = CGRect(x: 0, y: 0, width: size, height: size)
                v.layer.cornerRadius = size / 2
                v.layer.borderWidth = 3
                v.layer.borderColor = UIColor.white.cgColor
                v.backgroundColor = .systemPurple
                v.layer.shadowOpacity = 0.4
                v.layer.shadowRadius = 2
                v.layer.shadowOffset = .zero
                v.displayPriority = .required
                v.zPriority = .max
                v.isUserInteractionEnabled = false
                if v.viewWithTag(7) == nil {
                    let arrow = UIImageView(image: UIImage(systemName: "arrowtriangle.up.fill",
                                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)))
                    arrow.tintColor = .white
                    arrow.tag = 7
                    arrow.frame = CGRect(x: 0, y: 0, width: size, height: size)
                    arrow.contentMode = .center
                    arrow.isHidden = true
                    v.addSubview(arrow)
                }
                orient(v, heading: parent.heading, map: mapView)
                return v
            }
            if let seg = annotation as? SegmentAnnotation {
                // 点数の色の小さな丸。重なったら出来事のピンや自車の丸を優先して隠れる
                let id = "segment"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                let size: CGFloat = 12
                v.frame = CGRect(x: 0, y: 0, width: size, height: size)
                v.layer.cornerRadius = size / 2
                v.layer.borderWidth = 1.5
                v.layer.borderColor = UIColor.white.cgColor
                v.backgroundColor = UIColor(EvalStyle.color(seg.score))
                v.canShowCallout = true
                v.displayPriority = .defaultLow
                v.collisionMode = .circle
                return v
            }
            if annotation is EventAnnotation {
                let id = "event"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.markerTintColor = .systemOrange
                v.glyphImage = UIImage(systemName: "exclamationmark")
                v.canShowCallout = true
                v.displayPriority = .required
                return v
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let seg = view.annotation as? SegmentAnnotation, parent.segments.indices.contains(seg.segmentIndex) {
                parent.onSegment(parent.segments[seg.segmentIndex])
                return
            }
            guard let pin = view.annotation as? EventAnnotation, parent.events.indices.contains(pin.eventIndex) else { return }
            let e = parent.events[pin.eventIndex]
            let i = ReviewData(samples: parent.samples, hasMotion: false, hasAltitude: false, altitudeFromPressure: false)
                .index(atUnix: e.tUnix)
            parent.onPick(i)
        }

        /// 軌跡の近く(画面で 30pt 以内)をタップしたら、そこに一番近い点を選ぶ
        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let map, !parent.samples.isEmpty else { return }
            let p = g.location(in: map)
            var best = -1
            var bestD = CGFloat(30 * 30)
            for (i, s) in parent.samples.enumerated() {
                let q = map.convert(CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon), toPointTo: map)
                let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
                if d < bestD { bestD = d; best = i }
            }
            if best >= 0 { parent.onPick(best) }
        }

        // 地図のほかの操作(ピンを選ぶ・ダブルタップで拡大)と一緒に動かす
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
