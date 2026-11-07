"""
運転評価の Swift 版(DriveLogger/Sources/DriveEval.swift)を確かめるための、作り物の走行データを作る。
iPhone はホルダーで斜めに固定した想定で、発進・停止・カーブ・急ブレーキ・急ハンドルを含む 4 分の走行。
  python3 make_fixture.py <出力フォルダ>
期待する結果(expected.json)は、gbowl-log-formatter の Python 版で作る(README を参照)
"""
import math
import os
import random
import sys

G0 = 9.80665
MOT_HZ = 25
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
rnd = random.Random(20261108)

# 速度(m/s)と曲がり具合(rad/s)の予定: (区間の秒, 終わりの速度, 曲がる速さ)
plan = [
    (5, 0.0, 0.0),      # 止まっている
    (12, 14.0, 0.0),    # 発進
    (20, 14.0, 0.0),
    (8, 14.0, 0.12),    # 左カーブ
    (15, 16.0, 0.0),
    (3, 9.0, 0.0),      # 急ブレーキ(約 -0.24 G だが、ならす前は強い)
    (1.2, 4.0, 0.0),    # さらに強く
    (10, 12.0, 0.0),
    (2, 12.0, -0.45),   # 急ハンドル
    (20, 12.0, 0.0),
    (6, 0.0, 0.0),      # 止まる(最後に少しカックン)
    (8, 0.0, 0.0),
    (10, 15.0, 0.0),
    (30, 15.0, 0.05),
    (12, 0.0, 0.0),
    (10, 0.0, 0.0),
    (12, 13.0, 0.0),
    (40, 13.0, -0.03),
    (8, 0.0, 0.0),
    (6, 0.0, 0.0),
]

# 端末の向き: 車の (前, 左, 上) を端末の座標で表す。ホルダーで少し傾けて縦に立てた想定
def rot(v, axis, ang):
    x, y, z = v
    c, s = math.cos(ang), math.sin(ang)
    if axis == "x":
        return (x, c * y - s * z, s * y + c * z)
    if axis == "y":
        return (c * x + s * z, y, -s * x + c * z)
    return (c * x - s * y, s * x + c * y, z)

def dev(v):
    v = rot(v, "x", math.radians(70))
    v = rot(v, "z", math.radians(15))
    return rot(v, "y", math.radians(-8))

FWD, LEFT, UP = dev((1, 0, 0)), dev((0, 1, 0)), dev((0, 0, 1))

t0 = 1794000000.0
dt = 1.0 / MOT_HZ
t, v, heading = 0.0, 0.0, 0.3
lat, lon = 35.0, 139.0
mot_lines, loc_lines = [], []
next_loc = 0.0
prev_a = 0.0
for dur, v_end, yaw_rate in plan:
    steps = int(round(dur * MOT_HZ))
    v_start = v
    for k in range(steps):
        r = (k + 1) / steps
        # なめらかに速さを変える(終わり際だけ少し急に)
        v_new = v_start + (v_end - v_start) * (0.5 - 0.5 * math.cos(math.pi * r))
        a_lon = (v_new - v) / dt
        v = v_new
        yaw = yaw_rate if v > 1 else 0.0
        a_lat = v * yaw
        heading += yaw * dt
        lat += v * math.cos(heading) * dt / 111195
        lon += v * math.sin(heading) * dt / (111195 * math.cos(math.radians(35)))
        t += dt
        moving = v > 0.3
        noise = 0.02 if moving else 0.002
        acc = [(a_lon / G0) * FWD[c] + (a_lat / G0) * LEFT[c] + rnd.gauss(0, noise) for c in range(3)]
        grav = [-UP[c] for c in range(3)]
        rotv = [yaw * UP[c] + rnd.gauss(0, 0.01 if moving else 0.001) for c in range(3)]
        mot_lines.append(",".join(f"{x:.4f}" for x in [t0 + t] + acc + grav + rotv) + ",1,0,0,0,\n")
        if t >= next_loc:
            next_loc += 1.0
            sp = max(0.0, v + rnd.gauss(0, 0.15 if moving else 0.3))
            jl = rnd.gauss(0, 2e-6)
            loc_lines.append(f"{t0 + t:.3f},{lat + jl:.7f},{lon + jl:.7f},30.00,5.0,4.0,{sp:.2f},0.50,"
                             f"{math.degrees(heading) % 360:.1f},5.0,\n")

with open(os.path.join(out, "motion.csv"), "w") as f:
    f.write("unix_s,ax_g,ay_g,az_g,grav_x,grav_y,grav_z,rot_x_rads,rot_y_rads,rot_z_rads,q_w,q_x,q_y,q_z,heading_deg\n")
    f.writelines(mot_lines)
with open(os.path.join(out, "location.csv"), "w") as f:
    f.write("unix_s,lat,lon,alt_m,h_acc_m,v_acc_m,speed_ms,speed_acc_ms,course_deg,course_acc_deg,floor\n")
    f.writelines(loc_lines)
print(f"{len(mot_lines)} motion rows, {len(loc_lines)} location rows, {t:.0f} s")
