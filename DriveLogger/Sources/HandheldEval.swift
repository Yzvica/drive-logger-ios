import Foundation

// 同乗で、端末を手に持って(またはポケットに入れて)記録したときの運転評価。
// 記録した端末の姿勢(Core Motion の attitude)で加速度を地面の座標に直し、GPS の速度の変化に合わせて
// 車の前後・左右に戻す。端末を手で動かした区間は採点から外す(酔いやすさだけは GPS の速度の変化で埋める)。
// gbowl-log-formatter の Python 版には無い(同乗の記録は DriveLog に通さないため)。車(固定)の評価の数字は変えない。
// UIKit を使わない(CI で macOS のコマンドとしてもビルドして確かめるため)

/// 端末の姿勢(四元数)
struct Quat: Hashable {
    var w: Double
    var x: Double
    var y: Double
    var z: Double
}

extension DriveEval {
    /// 同乗で固定とみなす向き合わせの確かさ(これより低ければ手持ちの方法を試す)
    static let fixedMinQuality = 0.5
    /// 重力の向きが平均からこの角度(度)より離れた時間が、この割合を超えたら固定ではない
    static let steadyAngleDeg = 10.0
    static let steadyMaxRatio = 0.03
    /// 端末が傾く速さ(rad/s)。車の前後・左右の揺れはふつう 0.1 rad/s 未満
    static let handTilt = 0.35
    /// 端末の向きが変わる速さと、GPS で見た車の曲がる速さの差(rad/s)
    static let handYaw = 0.35
    /// GPS の 1 秒ごとの速度の変化と、その間の加速度の平均の差(G)
    static let handAccG = 0.15
    /// 手で動かした区間の前後に足して外す秒
    static let handPadS = 1.0
    /// 地面の座標と真北のずれを合わせる窓(前後の秒)
    static let handFitS = 60.0
    /// 進行方向が信用できる速さ(m/s)
    static let courseMinMS = 2.0

    /// 四元数で回す。inverse = true なら逆向き
    static func rotate(_ q: Quat, _ v: Vec3, inverse: Bool) -> Vec3 {
        let s = inverse ? -1.0 : 1.0
        let u = Vec3(q.x * s, q.y * s, q.z * s)
        let t = 2 * cross(u, v)
        return v + q.w * t + cross(u, t)
    }

    /// 端末がずっと同じ向きだったか(重力の向きがほとんど変わらない)
    static func gravitySteady(_ mot: [Mot]) -> Bool {
        guard !mot.isEmpty else { return false }
        var s = Vec3(0, 0, 0)
        for m in mot { s += m.g }
        let gm = norm(s)
        let c = cos(steadyAngleDeg * Double.pi / 180)
        var off = 0
        for m in mot {
            let l = dot(m.g, m.g).squareRoot()
            if l > 0 && dot(m.g, gm) / l < c { off += 1 }
        }
        return Double(off) / Double(mot.count) < steadyMaxRatio
    }

    /// GPS の 1 区間(前後 2 点)の速度の変化
    struct GPSAccel {
        var tm: Double
        var ta: Double
        var tb: Double
        var spMax: Double
        /// 加速度(m/s^2)。真北が x、西が y の座標
        var a: (x: Double, y: Double)
    }

    /// 手持ちの記録を 10 Hz の行にする。usable は走行中のうち採点に使える割合
    static func handheldRows(locs: [Loc], gpsLocs: [Loc], mot allMot: [Mot], t0: Double, t1: Double) throws
        -> (rows: [Row], quality: Double, usable: Double) {
        // 1. 姿勢の向き(端末→地面か、その逆か)を、重力が真下を向く方に決める
        let mot = allMot.filter { $0.q != nil }
        guard !mot.isEmpty, mot.count * 2 >= allMot.count else { throw DriveEvalError.noAttitude }
        var zA = 0.0, zB = 0.0, cnt = 0.0
        for k in Swift.stride(from: 0, to: mot.count, by: max(1, mot.count / 500)) {
            let g = norm(mot[k].g)
            zA += rotate(mot[k].q!, g, inverse: false).z
            zB += rotate(mot[k].q!, g, inverse: true).z
            cnt += 1
        }
        zA /= cnt
        zB /= cnt
        let inverse = zB < zA
        guard min(zA, zB) < -0.95 else { throw DriveEvalError.noAttitude }

        // 2. 10 Hz にそろえる(地面の座標の加速度・回転と、端末の細かい揺れ)
        let hz = Double(HZ)
        let ts = mot.map(\.t)
        let n = Int(((t1 - t0) * hz).rounded(.down)) + 1
        var aw = [Vec3](repeating: Vec3(0, 0, 0), count: n)
        var rw = [Vec3](repeating: Vec3(0, 0, 0), count: n)
        var vib = [Double?](repeating: nil, count: n)
        var have = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let t = t0 + Double(i) / hz
            let a = bisectLeft(ts, t - 0.05), b = bisectLeft(ts, t + 0.05)
            guard b > a else { continue }
            var sa = Vec3(0, 0, 0), sr = Vec3(0, 0, 0), sd = Vec3(0, 0, 0)
            for k in a..<b {
                let m = mot[k]
                sa += rotate(m.q!, m.a, inverse: inverse)
                sr += rotate(m.q!, m.r, inverse: inverse)
                sd += m.a
            }
            let c = Double(b - a)
            aw[i] = sa / c
            rw[i] = sr / c
            let md = sd / c
            var ss = 0.0
            for k in a..<b {
                let d = mot[k].a - md
                ss += dot(d, d)
            }
            vib[i] = (ss / c).squareRoot()
            have[i] = true
        }

        // 3. GPS の進行方向(度、真北から時計回り)。止まっている間は直前の向きのまま
        var cts: [Double] = [], cdeg: [Double] = []
        for l in gpsLocs {
            guard let sp = l.sp, sp >= courseMinMS, let cs = l.cs, cs >= 0 else { continue }
            cts.append(l.t)
            cdeg.append(cs)
        }
        guard cts.count >= 20 else { throw DriveEvalError.tooShort }
        func course(_ t: Double) -> Double {
            let k = bisectRight(cts, t)
            if k == 0 { return cdeg[0] }
            if k >= cts.count { return cdeg[cts.count - 1] }
            let ga = cts[k - 1], gb = cts[k]
            if gb - ga <= 5 { return lerpDeg(cdeg[k - 1], cdeg[k], (t - ga) / (gb - ga)) }
            return t - ga < gb - t ? cdeg[k - 1] : cdeg[k]
        }

        // GPS の速度の変化(速度のベクトルの差は、その間の加速度の平均にちょうど等しい)
        var vel: [(t: Double, sp: Double, x: Double, y: Double)] = []
        for l in gpsLocs {
            guard let sp = l.sp else { continue }
            let c = course(l.t) * Double.pi / 180
            vel.append((l.t, sp, sp * cos(c), -sp * sin(c)))
        }
        var acc: [GPSAccel] = []
        for (a, b) in zip(vel, vel.dropFirst()) {
            let dt = b.t - a.t
            guard (0.5...2.0).contains(dt) else { continue }
            acc.append(GPSAccel(tm: (a.t + b.t) / 2, ta: a.t, tb: b.t, spMax: max(a.sp, b.sp),
                                a: ((b.x - a.x) / dt, (b.y - a.y) / dt)))
        }
        let accT = acc.map(\.tm)
        func gpsAccel(_ t: Double) -> (x: Double, y: Double) {
            let k = bisectRight(accT, t)
            guard k > 0, k < acc.count, acc[k].tm - acc[k - 1].tm <= 3 else { return (0, 0) }
            let p = acc[k - 1], q = acc[k]
            let r = (t - p.tm) / (q.tm - p.tm)
            return (p.a.x + (q.a.x - p.a.x) * r, p.a.y + (q.a.y - p.a.y) * r)
        }

        let lts = locs.map(\.t)
        var gps = (0..<n).map { locationAt(locs, lts, t0 + Double($0) / hz) }
        let kmh = gps.map { $0.sp * 3.6 }
        let cr = (0..<n).map { course(t0 + Double($0) / hz) * Double.pi / 180 }
        // GPS で見た車の曲がる速さ(rad/s、左回りが +)
        let omega = (0..<n).map { i -> Double in
            guard kmh[i] >= courseMinMS * 3.6 else { return 0 }
            let t = t0 + Double(i) / hz
            // 方位は時計回りなので、増えれば右に曲がっている
            let d = pyMod(course(t + 0.5) - course(t - 0.5) + 180, 360) - 180
            return -d * Double.pi / 180
        }

        // 4. 手で端末を動かした区間(1 回目: 回転だけで見る)
        let tilt = smooth((0..<n).map { (rw[$0].x * rw[$0].x + rw[$0].y * rw[$0].y).squareRoot() }, 2)
        let yawMis = smooth((0..<n).map { abs(rw[$0].z - omega[$0]) }, 2)
        let rotFlag = (0..<n).map { !have[$0] || tilt[$0] > handTilt || yawMis[$0] > handYaw }
        func idx(_ t: Double) -> Int { min(n - 1, max(0, Int(((t - t0) * hz).rounded()))) }

        // 5. 地面の座標と真北のずれ(磁石のずれ・車の鉄の影響)を、前後 60 秒の GPS の速度の変化に合わせて決める。
        //    2 回目は、GPS と食い違った区間も除いて合わせ直す
        var accFlag = [Bool](repeating: false, count: n)
        var rx = [Double](repeating: 0, count: n), ry = [Double](repeating: 0, count: n)
        var fitPairs: [(gps: Double, imu: Double)] = []
        for _ in 0..<2 {
            var fitT: [Double] = [], preRe = [0.0], preIm = [0.0]
            for g in acc where g.spMax >= courseMinMS {
                let ia = idx(g.ta), ib = idx(g.tb)
                if rotFlag[ia...ib].contains(true) || accFlag[ia...ib].contains(true) { continue }
                var ix = 0.0, iy = 0.0
                for k in ia...ib { ix += aw[k].x; iy += aw[k].y }
                ix *= G0 / Double(ib - ia + 1)
                iy *= G0 / Double(ib - ia + 1)
                // GPS ≈ e^{iθ}·端末 なので、GPS × conj(端末) の向きが θ
                fitT.append(g.tm)
                preRe.append(preRe[preRe.count - 1] + g.a.x * ix + g.a.y * iy)
                preIm.append(preIm[preIm.count - 1] + g.a.y * ix - g.a.x * iy)
            }
            guard fitT.count >= 20 else { throw DriveEvalError.tooShort }
            for i in 0..<n {
                let t = t0 + Double(i) / hz
                var lo = bisectLeft(fitT, t - handFitS), hi = bisectRight(fitT, t + handFitS)
                if hi - lo < 10 { lo = 0; hi = fitT.count }
                let th = atan2(preIm[hi] - preIm[lo], preRe[hi] - preRe[lo])
                let c = cos(th), s = sin(th)
                rx[i] = aw[i].x * c - aw[i].y * s
                ry[i] = aw[i].x * s + aw[i].y * c
            }
            // GPS の 1 区間ごとに、その間の加速度の平均と比べる
            accFlag = [Bool](repeating: false, count: n)
            fitPairs = []
            for g in acc where g.spMax >= courseMinMS {
                let ia = idx(g.ta), ib = idx(g.tb)
                var ix = 0.0, iy = 0.0
                for k in ia...ib { ix += rx[k]; iy += ry[k] }
                ix *= G0 / Double(ib - ia + 1)
                iy *= G0 / Double(ib - ia + 1)
                let d = ((g.a.x - ix) * (g.a.x - ix) + (g.a.y - iy) * (g.a.y - iy)).squareRoot() / G0
                if d > handAccG {
                    for k in ia...ib { accFlag[k] = true }
                } else if !rotFlag[ia...ib].contains(true) {
                    // 向き合わせの確かさ(前後の加速度どうしの相関)
                    let c = cr[idx(g.tm)]
                    fitPairs.append((g.a.x * cos(c) - g.a.y * sin(c), ix * cos(c) - iy * sin(c)))
                }
            }
        }

        // 6. 車の前後・左右(G)。手で動かした区間(前後 1 秒を含む)は GPS の速度の変化で埋め、採点から外す
        var flag = [Bool](repeating: false, count: n)
        let pad = Int(handPadS * hz)
        for i in 0..<n where rotFlag[i] || accFlag[i] {
            for k in max(0, i - pad)...min(n - 1, i + pad) { flag[k] = true }
        }
        var lonG = [Double](repeating: 0, count: n), latG = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let fx = cos(cr[i]), fy = -sin(cr[i]) // 前
            let lx = sin(cr[i]), ly = cos(cr[i])  // 左
            if flag[i] {
                let g = gpsAccel(t0 + Double(i) / hz)
                lonG[i] = (g.x * fx + g.y * fy) / G0
                latG[i] = (g.x * lx + g.y * ly) / G0
            } else {
                lonG[i] = rx[i] * fx + ry[i] * fy
                latG[i] = rx[i] * lx + ry[i] * ly
            }
        }

        // 7. 停止の判定は車と同じ(回転は GPS で見た曲がる速さを使う。手の回転で止まっていないと見ないように)
        let stopped = detectStops(yaw: omega, vib: vib, gpsKmh: kmh)
        applyStops(&gps, stopped)
        let rows = (0..<n).map { i in
            Row(rx: latG[i], ry: -lonG[i], kmh: gps[i].sp * 3.6, lat: gps[i].la, lon: gps[i].lo,
                stopped: stopped[i], valid: !flag[i])
        }
        let moving = rows.filter { $0.kmh > movingKmh }
        let usable = moving.isEmpty ? 0 : Double(moving.filter(\.valid).count) / Double(moving.count)
        let quality = corr(fitPairs.map { $0.gps }, fitPairs.map { $0.imu })
        return (rows, quality, usable)
    }
}
