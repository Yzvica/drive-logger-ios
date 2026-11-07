import AVFoundation

/// 合図の音を鳴らす。消音モード(横のスイッチ)でも鳴るように、オーディオセッションを再生用にする。
/// 音楽などほかのアプリの音は止めずに重ねて鳴らす
final class Beeper {
    static let shared = Beeper()

    enum Kind {
        /// 動画と合わせる合図。DJI Mic で拾いやすく、波形でも見つけやすい 2kHz の短い音を3回
        case sync
        /// 目印。短い音を1回
        case mark
        /// 記録を止めた。低めの音を2回
        case stop
    }

    private var players: [Kind: AVAudioPlayer] = [:]
    private var configured = false

    private init() {}

    /// 鳴らした時刻(音の出だし)を返す。オーディオの準備に失敗したときは nil
    @discardableResult
    func play(_ kind: Kind) -> Date? {
        configure()
        guard let p = player(kind) else { return nil }
        p.currentTime = 0
        // 出力の遅れを足して、実際に音が出る時刻に近づける
        let latency = AVAudioSession.sharedInstance().outputLatency
        guard p.play() else { return nil }
        return Date().addingTimeInterval(latency)
    }

    private func configure() {
        guard !configured else { return }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, options: [.mixWithOthers])
            try s.setActive(true)
            configured = true
        } catch {
            NSLog("オーディオセッションを設定できません: \(error)")
        }
    }

    private func player(_ kind: Kind) -> AVAudioPlayer? {
        if let p = players[kind] { return p }
        let wav: Data
        switch kind {
        case .sync: wav = Beeper.tones([(2000, 0.12), (0, 0.08), (2000, 0.12), (0, 0.08), (2000, 0.12)])
        case .mark: wav = Beeper.tones([(1500, 0.08)])
        case .stop: wav = Beeper.tones([(800, 0.15), (0, 0.08), (600, 0.2)])
        }
        guard let p = try? AVAudioPlayer(data: wav) else { return nil }
        p.volume = 1
        p.prepareToPlay()
        players[kind] = p
        return p
    }

    /// (周波数 Hz, 長さ 秒) の並びから 16bit モノラルの WAV を作る。周波数 0 は無音
    static func tones(_ parts: [(Double, Double)], rate: Double = 44100) -> Data {
        var samples: [Int16] = []
        for (freq, dur) in parts {
            let n = Int(dur * rate)
            let fade = min(Int(0.005 * rate), n / 2) // プツッと鳴らないよう前後 5ms をなめらかにする
            for i in 0..<n {
                guard freq > 0 else { samples.append(0); continue }
                var amp = 0.9
                if i < fade { amp *= Double(i) / Double(fade) }
                if i >= n - fade { amp *= Double(n - 1 - i) / Double(fade) }
                samples.append(Int16(amp * 32767 * sin(2 * .pi * freq * Double(i) / rate)))
            }
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
