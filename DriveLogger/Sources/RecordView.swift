import CoreLocation
import SwiftUI

struct RecordView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 16) {
            TrackMapView(track: recorder.track, style: settings.mapStyle, headingUp: $settings.mapHeadingUp)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 180)
                .overlay(alignment: .topLeading) {
                    Menu {
                        Picker("地図", selection: $settings.mapStyle) {
                            ForEach(MapStyle.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Label(settings.mapStyle.title, systemImage: "map")
                            .font(.footnote.bold())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(8)
                }
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

            if !recorder.isRecording && recorder.keepingAliveForUpload {
                Text("地図へ送り終えるまで、裏で起動したままにしています")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            if !recorder.isRecording {
                // 記録の前に忘れやすいこと(折りたためる。開閉は覚えておく)
                DisclosureGroup(isExpanded: $showChecklist) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("・DJI の録画を先に始めてから「記録開始」(同期の合図が動画に入る)")
                        Text("・DJI Mic のマイク表示・SD の空き・電池を確認")
                        Text("・空が見える所で、GPS 精度が ±10m 前後になってから発進")
                        Text("・停止は走り終えてから(途中で押すと走行が分かれます)")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    Label("記録の前に", systemImage: "checklist").font(.caption.bold())
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text("停止は走り終えてから(途中で押すと走行が分かれます)")
                    .font(.caption2).foregroundStyle(.secondary)
            }

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
                if recorder.isRecording { confirmStop = true } else { recorder.start() }
            }
        }
        .padding()
        .confirmationDialog("記録を止めますか?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("停止する", role: .destructive) { recorder.stopWithSync() }
            Button("記録を続ける", role: .cancel) {}
        } message: {
            Text("止める直前に同期の合図(光と音)を出します。DJI の録画はそのあとで止めてください")
        }
    }

    @State private var confirmStop = false
    @AppStorage("showChecklist") private var showChecklist = true

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
