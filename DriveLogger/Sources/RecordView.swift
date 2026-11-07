import CoreLocation
import SwiftUI

struct RecordView: View {
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        VStack(spacing: 16) {
            TrackMapView(track: recorder.track)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Display.kmh(recorder.speedMS))
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("km/h").font(.title3).foregroundStyle(.secondary)
            }

            HStack {
                stat("距離", Display.km(recorder.current?.distanceM ?? 0))
                stat("時間", recorder.current.map { Display.duration($0.durationS) } ?? "0:00:00")
                stat("横G", String(format: "%.2f", recorder.horizontalG))
                stat("GPS精度", recorder.horizontalAccuracy < 0 ? "-" : String(format: "±%.0fm", recorder.horizontalAccuracy))
            }

            if recorder.isRecording && recorder.authorization != .authorizedAlways {
                Text("画面を消しても記録を続けるには、位置情報を「常に」許可してください")
                    .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            if recorder.isRecording {
                HStack(spacing: 12) {
                    bigButton("目印", systemImage: "mappin", color: .blue) { recorder.addMarker("mark") }
                    bigButton("同期", systemImage: "camera.metering.center.weighted", color: .purple) {
                        recorder.addMarker("sync")
                    }
                }
                Text("目印 \(recorder.current?.markers.count ?? 0) 件")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            bigButton(recorder.isRecording ? "停止" : "記録開始",
                      systemImage: recorder.isRecording ? "stop.fill" : "record.circle",
                      color: recorder.isRecording ? .red : .green) {
                recorder.isRecording ? recorder.stop() : recorder.start()
            }
        }
        .padding()
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func bigButton(_ title: String, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title2.bold())
                .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
    }
}
