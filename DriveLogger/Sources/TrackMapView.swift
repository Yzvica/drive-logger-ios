import MapKit
import SwiftUI

/// 走行中の軌跡を表示する地図(iOS 16 でも使えるよう MKMapView を使う)
struct TrackMapView: UIViewRepresentable {
    var track: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.userTrackingMode = .follow
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // 点が増えるたびに作り直すと重いので、10点ごとに線を引き直す
        guard track.count != context.coordinator.drawnCount,
              track.count < 2 || track.count - context.coordinator.drawnCount >= 10 || track.count < context.coordinator.drawnCount
        else { return }
        context.coordinator.drawnCount = track.count
        map.removeOverlays(map.overlays)
        guard track.count >= 2 else { return }
        map.addOverlay(MKPolyline(coordinates: track, count: track.count))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var drawnCount = 0

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = .systemRed
            r.lineWidth = 4
            return r
        }
    }
}
