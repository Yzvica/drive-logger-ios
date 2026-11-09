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
                .overlay(alignment: .topTrailing) {
                    if recorder.isRecording { GPSLamp(status: recorder.gpsStatus).padding(8) }
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
                if mode.isCar {
                    stat("横G", String(format: "%.2f", recorder.horizontalG))
                } else {
                    stat("高度", recorder.altitudeM.map { String(format: "%.0fm", $0) } ?? "-")
                }
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

            if recorder.isRecording && mode.isCar {
                CoachPanel(state: recorder.coachState)
            }

            if !recorder.isRecording, let trip = recorder.lastTrip {
                // 車以外の移動を止めた直後のまとめ(地図には送らない)
                VStack(alignment: .leading, spacing: 4) {
                    Label("今回の\(trip.travelMode.title)の移動", systemImage: trip.travelMode.systemImage)
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    TripSummary(meta: trip)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    Button { recorder.lastTrip = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .accessibilityLabel("閉じる")
                }
            }

            if !recorder.isRecording && recorder.isEvaluating {
                HStack { ProgressView(); Text("運転の評価を計算しています…").font(.footnote).foregroundStyle(.secondary) }
            } else if !recorder.isRecording, let last = recorder.lastEvaluation {
                // 止めた直後に今回の評価を出す(詳しくはログの画面で)
                VStack(alignment: .leading, spacing: 4) {
                    Text("今回の運転").font(.caption.bold()).foregroundStyle(.secondary)
                    EvalSummary(eval: last.eval)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    Button { recorder.lastEvaluation = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .accessibilityLabel("閉じる")
                }
            }

            Spacer(minLength: 0)

            if !recorder.isRecording {
                // 記録の前に忘れやすいこと(折りたためる。開閉は覚えておく)
                DisclosureGroup(isExpanded: $showChecklist) {
                    VStack(alignment: .leading, spacing: 3) {
                        if mode.isCar {
                            Text("・DJI の録画を先に始めてから「記録開始」(同期の合図が動画に入る)")
                            Text("・DJI Mic のマイク表示・SD の空き・電池を確認")
                            Text("・空が見える所で、GPS 精度が ±10m 前後になってから発進")
                            Text("・停止は走り終えてから(途中で押すと走行が分かれます)")
                        } else {
                            Text("・\(mode.title)の記録は地図(国道の判定)には送りません。運転評価もしません")
                            Text("・記録中は音を鳴らしません")
                            if mode == .plane {
                                Text("・機内モードでも GPS は使えます。窓際でないとほとんど測位できません")
                                Text("・最初の測位に数分かかることがあります。乗る前に始めておくと確実です")
                            } else {
                                Text("・地下やトンネルでは途切れます。窓際のほうが測位しやすいです")
                            }
                        }
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
                Text(mode.isCar ? "停止は走り終えてから(途中で押すと走行が分かれます)"
                                : "\(mode.title)の移動を記録中(地図には送りません)")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if !recorder.isRecording {
                Picker("移動手段", selection: $settings.travelMode) {
                    ForEach(TravelMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }

            if recorder.isRecording && mode.isCar {
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
            Text(mode.isCar ? "止める直前に同期の合図(光と音)を出します。DJI の録画はそのあとで止めてください"
                            : "\(mode.title)の移動の記録を止めます")
        }
    }

    /// 記録中はその移動手段、止めているときは次に記録する移動手段
    private var mode: TravelMode { recorder.isRecording ? recorder.mode : settings.travelMode }

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
