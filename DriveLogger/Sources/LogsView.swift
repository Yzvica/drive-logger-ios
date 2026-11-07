import SwiftUI

struct LogsView: View {
    @EnvironmentObject var store: LogStore
    @EnvironmentObject var uploader: Uploader
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        uploader.uploadPending()
                    } label: {
                        Label(uploader.isUploading ? "送信中…" : "未送信のログを送る(\(store.unsent.count)件)",
                              systemImage: "arrow.up.circle")
                    }
                    .disabled(uploader.isUploading || recorder.isRecording || store.unsent.isEmpty)
                    if let message = uploader.lastMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("走行") {
                    ForEach(store.sessions) { meta in
                        NavigationLink(value: meta.id) { row(meta) }
                    }
                    .onDelete { offsets in
                        for i in offsets where store.sessions[i].finished { store.delete(store.sessions[i].id) }
                    }
                }
            }
            .navigationTitle("ログ")
            .navigationDestination(for: String.self) { id in LogDetailView(id: id) }
            .refreshable { store.reload() }
        }
    }

    private func row(_ meta: SessionMeta) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Display.date.string(from: meta.start)).font(.headline)
                Spacer()
                status(meta)
            }
            Text("\(Display.km(meta.distanceM))・\(Display.duration(meta.durationS))・目印 \(meta.markers.count)")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func status(_ meta: SessionMeta) -> some View {
        if !meta.finished {
            Text("記録中").font(.caption.bold()).foregroundStyle(.red)
        } else if meta.gpxSent && LogStore.rawFiles.allSatisfy(meta.rawSent.contains) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if meta.gpxSent {
            Text("生データ未送信").font(.caption).foregroundStyle(.orange)
        } else {
            Text("未送信").font(.caption).foregroundStyle(.orange)
        }
    }
}

struct LogDetailView: View {
    let id: String
    @EnvironmentObject var store: LogStore

    var body: some View {
        let meta = store.sessions.first { $0.id == id }
        let dir = store.dir(id)
        let files = ["track.gpx"] + LogStore.rawFiles
        List {
            if let meta {
                Section("概要") {
                    LabeledContent("開始", value: Display.date.string(from: meta.start))
                    LabeledContent("距離", value: Display.km(meta.distanceM))
                    LabeledContent("時間", value: Display.duration(meta.durationS))
                    LabeledContent("最高速度", value: "\(Display.kmh(meta.maxSpeedMS)) km/h")
                    LabeledContent("位置の点数", value: "\(meta.points)")
                    LabeledContent("端末", value: "\(meta.device) / iOS \(meta.systemVersion)")
                }
                if !meta.markers.isEmpty {
                    Section("目印") {
                        ForEach(meta.markers, id: \.self) { m in
                            LabeledContent(m.kind == "sync" ? "同期" : "目印",
                                           value: Fmt.iso.string(from: m.time))
                        }
                    }
                }
            }
            Section("ファイル") {
                ForEach(files, id: \.self) { name in
                    let url = dir.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: url.path) {
                        ShareLink(item: url) {
                            LabeledContent(name, value: size(url))
                        }
                    }
                }
            }
        }
        .navigationTitle(id)
    }

    private func size(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
