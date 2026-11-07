#!/usr/bin/env python3
"""DJI Osmo Action 6 の LRF / MP4 から djmd テレメトリを CSV に書き出す(標準ライブラリのみ)。

使い方:
    python extract.py <LRF または MP4> [-o 出力.csv]

moov ボックスとサンプルテーブルを読み、djmd トラックのサンプルだけを順に seek して読む。
動画データ(mdat)全体は読まないので、17 GB の MP4 でもメモリ使用量は小さい。
カメラのシリアル番号などの機器情報は出力しない。
"""
import argparse
import csv
import datetime as dt
import math
import os
import struct
import sys

MAC_EPOCH = dt.datetime(1904, 1, 1, tzinfo=dt.timezone.utc)
JST = dt.timezone(dt.timedelta(hours=9))

COLUMNS = [
    "frame", "time_utc", "time_jst", "t_video_s",
    "accel_x_g", "accel_y_g", "accel_z_g",
    "quat_w", "quat_x", "quat_y", "quat_z",
    "gyro_x_dps", "gyro_y_dps", "gyro_z_dps",
    "pressure_hpa", "altitude_m",
    "iso", "shutter_s", "shutter_frac", "f_number", "color_temp_k",
]


# ---------------------------------------------------------------- MP4 ボックス

def iter_boxes(f, start, end):
    pos = start
    while pos + 8 <= end:
        f.seek(pos)
        size, typ = struct.unpack(">I4s", f.read(8))
        hlen = 8
        if size == 1:
            size = struct.unpack(">Q", f.read(8))[0]
            hlen = 16
        elif size == 0:
            size = end - pos
        if size < hlen or pos + size > end:
            return
        yield typ, pos + hlen, pos + size
        pos += size


def child(f, rng, name):
    for typ, s, e in iter_boxes(f, rng[0], rng[1]):
        if typ == name:
            return s, e
    return None


def path(f, rng, *names):
    for n in names:
        rng = child(f, rng, n)
        if rng is None:
            return None
    return rng


def read(f, rng):
    f.seek(rng[0])
    return f.read(rng[1] - rng[0])


def find_djmd(f):
    """(creation_time, sample の (offset, size) イテレータ, サンプル数) を返す"""
    f.seek(0, 2)
    moov = child(f, (0, f.tell()), b"moov")
    if moov is None:
        raise SystemExit("moov ボックスが見つかりません")
    mvhd = read(f, child(f, moov, b"mvhd"))
    secs = struct.unpack(">I", mvhd[4:8])[0] if mvhd[0] == 0 else struct.unpack(">Q", mvhd[4:12])[0]
    created = MAC_EPOCH + dt.timedelta(seconds=secs)
    for typ, s, e in iter_boxes(f, *moov):
        if typ != b"trak":
            continue
        stbl = path(f, (s, e), b"mdia", b"minf", b"stbl")
        if stbl is None:
            continue
        stsd = read(f, child(f, stbl, b"stsd"))
        if stsd[12:16] != b"djmd":
            continue
        stsz = read(f, child(f, stbl, b"stsz"))
        uni, cnt = struct.unpack(">II", stsz[4:12])
        sizes = [uni] * cnt if uni else struct.unpack(f">{cnt}I", stsz[12:12 + 4 * cnt])
        co = child(f, stbl, b"stco")
        if co:
            d = read(f, co)
            n = struct.unpack(">I", d[4:8])[0]
            chunks = struct.unpack(f">{n}I", d[8:8 + 4 * n])
        else:
            d = read(f, child(f, stbl, b"co64"))
            n = struct.unpack(">I", d[4:8])[0]
            chunks = struct.unpack(f">{n}Q", d[8:8 + 8 * n])
        d = read(f, child(f, stbl, b"stsc"))
        n = struct.unpack(">I", d[4:8])[0]
        stsc = [struct.unpack(">III", d[8 + 12 * i:20 + 12 * i]) for i in range(n)]

        def gen():
            idx = ei = 0
            for ci, off in enumerate(chunks, 1):
                while ei + 1 < len(stsc) and stsc[ei + 1][0] <= ci:
                    ei += 1
                for _ in range(stsc[ei][1]):
                    if idx >= cnt:
                        return
                    yield off, sizes[idx]
                    off += sizes[idx]
                    idx += 1
        return created, gen(), cnt
    raise SystemExit("djmd トラックが見つかりません(DJI のカメラで撮った動画ですか?)")


# ---------------------------------------------------------------- protobuf

def _varint(b, i):
    v = sh = 0
    while True:
        c = b[i]
        i += 1
        v |= (c & 0x7F) << sh
        if c < 0x80:
            return v, i
        sh += 7


def pb(b):
    """field 番号 -> (wire type, 値)。同じ番号が複数あれば最後の値。"""
    out, i = {}, 0
    while i < len(b):
        k, i = _varint(b, i)
        fn, wt = k >> 3, k & 7
        if wt == 0:
            v, i = _varint(b, i)
        elif wt == 1:
            v, i = b[i:i + 8], i + 8
        elif wt == 2:
            n, i = _varint(b, i)
            v, i = b[i:i + n], i + n
        elif wt == 5:
            v, i = b[i:i + 4], i + 4
        else:
            raise ValueError("unknown wire type")
        out[fn] = (wt, v)
    return out


def sub(d, fn):
    x = d.get(fn)
    return pb(x[1]) if x and x[0] == 2 else {}


def f32(d, fn):
    x = d.get(fn)
    return struct.unpack("<f", x[1])[0] if x and x[0] == 5 else None


def var(d, fn):
    x = d.get(fn)
    return x[1] if x and x[0] == 0 else None


def rational(d, fn):
    """packed varint で (分子, 分母) が入ったフィールド"""
    x = d.get(fn)
    if not x or x[0] != 2:
        return None
    vals, i = [], 0
    try:
        while i < len(x[1]):
            v, i = _varint(x[1], i)
            vals.append(v)
    except IndexError:
        return None
    return (vals[0], vals[1]) if len(vals) >= 2 and vals[1] else None


# ---------------------------------------------------------------- 姿勢

def qmul(a, b):
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return (aw * bw - ax * bx - ay * by - az * bz,
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw)


def body_rate_dps(q0, q1, dt_s):
    """q0→q1 の回転からカメラ座標系の角速度 [deg/s] を求める"""
    w, x, y, z = qmul((q0[0], -q0[1], -q0[2], -q0[3]), q1)
    if w < 0:
        w, x, y, z = -w, -x, -y, -z
    s = math.sqrt(x * x + y * y + z * z)
    ang = 2 * math.atan2(s, w)
    k = (ang / s) if s > 1e-12 else 2.0
    return tuple(math.degrees(c * k) / dt_s for c in (x, y, z))


# ---------------------------------------------------------------- 本体

def fmt(v, spec):
    return "" if v is None else format(v, spec)


def iso_ms(t):
    return t.isoformat(timespec="milliseconds")


def extract(src, dst):
    with open(src, "rb") as f, open(dst, "w", newline="", encoding="utf-8") as o:
        created, samples, cnt = find_djmd(f)
        w = csv.writer(o)
        w.writerow(COLUMNS)
        ts0 = None
        prev_q = prev_ts = None
        rate = None
        rows = 0
        for i, (off, size) in enumerate(samples):
            f.seek(off)
            try:
                m3 = sub(pb(f.read(size)), 3)
            except (ValueError, IndexError):
                m3 = {}
            ts = var(sub(m3, 1), 2)
            if ts is not None and ts0 is None:
                ts0 = ts
            cam = sub(m3, 2)
            qd, ad = sub(cam, 9), sub(cam, 10)
            q = tuple(f32(qd, k) for k in (1, 2, 3, 4))
            q = q if all(c is not None for c in q) and any(q) else None
            acc = [f32(ad, k) for k in (2, 3, 4)] if ad else [None] * 3
            if ad:  # protobuf では 0.0 が省略されるので、メッセージがあれば 0 とみなす
                acc = [0.0 if v is None else v for v in acc]

            # 角速度: 姿勢が更新されたときだけ計算し、同じ姿勢が繰り返されるフレームは直前の値を使う
            if q and ts is not None:
                if prev_q is not None and q != prev_q and ts > prev_ts:
                    rate = body_rate_dps(prev_q, q, (ts - prev_ts) / 1e6)
                if q != prev_q:
                    prev_q, prev_ts = q, ts
            gyro = rate if rate else (None, None, None)

            baro = sub(cam, 13)
            pressure = var(baro, 3)
            altitude = None
            if pressure is not None:
                altitude = (var(baro, 2) or 0) / 10.0  # 0.1 m 単位。0 未満は 0 に丸められているらしい
            iso = f32(sub(cam, 3), 1)
            sh = rational(sub(cam, 4), 1)
            fno = rational(sub(cam, 15), 1)
            ct = var(sub(cam, 6), 1)

            if ts is None:
                t_utc = t_jst = t_rel = ""
            else:
                t = created + dt.timedelta(microseconds=ts - ts0)
                t_utc = iso_ms(t).replace("+00:00", "Z")
                t_jst = iso_ms(t.astimezone(JST))
                t_rel = f"{(ts - ts0) / 1e6:.3f}"
            w.writerow([
                i, t_utc, t_jst, t_rel,
                *(fmt(v, ".5f") for v in acc),
                *(fmt(v, ".7f") for v in (q or (None,) * 4)),
                *(fmt(v, ".3f") for v in gyro),
                fmt(pressure, "d"), fmt(altitude, ".1f"),
                fmt(iso, "g"),
                fmt(sh[0] / sh[1] if sh else None, ".6g"), f"{sh[0]}/{sh[1]}" if sh else "",
                fmt(fno[0] / fno[1] if fno else None, ".1f"),
                fmt(ct, "d"),
            ])
            rows += 1
    return rows, created, cnt


def main():
    ap = argparse.ArgumentParser(description="DJI Osmo Action 6 の djmd テレメトリを CSV に書き出す")
    ap.add_argument("input", help="LRF または MP4")
    ap.add_argument("-o", "--output", help="出力 CSV(省略時は入力と同じ場所に <名前>_telemetry.csv)")
    a = ap.parse_args()
    dst = a.output or os.path.splitext(a.input)[0] + "_telemetry.csv"
    rows, created, cnt = extract(a.input, dst)
    print(f"{rows} 行(djmd サンプル {cnt})、撮影開始 {created.astimezone(JST).isoformat()} -> {dst}", file=sys.stderr)


if __name__ == "__main__":
    main()
