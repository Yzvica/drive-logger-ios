import MapKit

/// 地図のダブルタップして上下に動かす拡大縮小の向きを、設定(下で拡大/上で拡大)に合わせる。
/// 記録画面と振り返りの地図で共通に使う
final class OneFingerZoom: NSObject, UIGestureRecognizerDelegate {
    private weak var gesture: UILongPressGestureRecognizer?
    /// いま反映している向き。nil なら地図の部品ができてからもう一度試す
    private(set) var applied: Bool?
    private var startY: CGFloat = 0
    private var startDistance: CLLocationDistance = 0
    /// いま指で拡大縮小しているか(記録画面の追尾がこのあいだ地図を動かさないように)
    private(set) var zooming = false

    /// 地図に自前のジェスチャーを付ける(最初は止めておき、apply で切り替える)
    func install(on map: MKMapView, downIn: Bool) {
        let g = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
        g.numberOfTapsRequired = 1
        g.minimumPressDuration = 0
        g.delegate = self
        g.isEnabled = false
        map.addGestureRecognizer(g)
        gesture = g
        DispatchQueue.main.async { self.apply(map, downIn: downIn) }
    }

    /// 向きが変わったとき、または前回うまく反映できなかったときだけ切り替える
    func update(_ map: MKMapView, downIn: Bool) {
        if applied != downIn { apply(map, downIn: downIn) }
    }

    /// 設定に合わせて、MapKit のものと自前のもののどちらを使うか切り替える。
    /// MapKit のものが見つからなければ(iOS の版で名前が変わったときなど)、二重に動かないよう自前のものは使わない
    func apply(_ map: MKMapView, downIn: Bool) {
        let builtIn = builtInOneFingerZoom(in: map)
        let useOwn = downIn && !builtIn.isEmpty
        builtIn.forEach { $0.isEnabled = !useOwn }
        gesture?.isEnabled = useOwn
        // 地図の部品がまだできていなかったときは、あとでもう一度試す
        applied = builtIn.isEmpty && downIn ? nil : downIn
    }

    /// MapKit が持っている片手ズーム(ダブルタップして上下)のジェスチャー。地図の中の部品に付いている
    private func builtInOneFingerZoom(in view: UIView) -> [UIGestureRecognizer] {
        var found = (view.gestureRecognizers ?? []).filter {
            $0 !== gesture && String(describing: type(of: $0)).range(of: "OneHanded", options: .caseInsensitive) != nil
        }
        for sub in view.subviews { found += builtInOneFingerZoom(in: sub) }
        return found
    }

    @objc private func handle(_ g: UILongPressGestureRecognizer) {
        guard let map = g.view as? MKMapView else { return }
        let y = g.location(in: map).y
        switch g.state {
        case .began:
            startY = y
            startDistance = map.camera.centerCoordinateDistance
            zooming = false
        case .changed:
            let dy = y - startY
            // 少し動かすまでは拡大縮小しない(ふつうのダブルタップで拡大できるように)
            if !zooming && abs(dy) < 8 { return }
            zooming = true
            // 下に動かすと近づく(拡大)。200pt でおよそ 7.4 倍
            let d = startDistance * exp(-Double(dy) / 100)
            let cam = map.camera.copy() as! MKMapCamera
            cam.centerCoordinateDistance = max(50, min(d, 20_000_000))
            map.setCamera(cam, animated: false)
        default:
            zooming = false
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
