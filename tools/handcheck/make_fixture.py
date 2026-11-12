"""
同乗の手持ち評価(DriveEval の handheldRows)を確かめるための、作り物の走行データを作る。
tools/evalcheck/make_fixture.py と同じ走り方を、助手席で iPhone を手に持って記録した想定にする。
  - 端末は手で斜めに持ち、体の揺れで少しずつ傾く。車が曲がれば体ごと端末も曲がる
  - ときどき持ち替える(1 秒で向きが大きく変わり、手の加速度が乗る)
  - 腕だけを左右に揺らす区間もある(向きは変わらず、加速度だけ乗る)
  - 姿勢(q_w..q_z)は端末→地面の回転。地面の座標は磁北基準で、真北から 12 度ずれている
  truth.csv は本当の車の前後・左右の G(前・左が +)と、手で動かしていたか(1=持ち替え、2=腕だけ揺らす)。
  python3 make_fixture.py <出力フォルダ>
"""
import math
import os
import random
import sys

G0 = 9.80665
MOT_HZ = 50
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
rnd = random.Random(20261112)

plan = [
    (5, 0.0, 0.0), (12, 14.0, 0.0), (20, 14.0, 0.0), (8, 14.0, 0.12), (15, 16.0, 0.0),
    (3, 9.0, 0.0), (1.2, 4.0, 0.0), (10, 12.0, 0.0), (2, 12.0, -0.45), (20, 12.0, 0.0),
    (6, 0.0, 0.0), (8, 0.0, 0.0), (10, 15.0, 0.0), (30, 15.0, 0.05), (12, 0.0, 0.0),
    (10, 0.0, 0.0), (12, 13.0, 0.0), (40, 13.0, -0.03), (8, 0.0, 0.0), (6, 0.0, 0.0),
]

# 持ち替え: (始まりの秒, 向きの変わり(度), 傾きの変わり(度))
regrips = [(30.0, 50.0, 15.0), (95.0, -80.0, -20.0), (150.0, 30.0, 25.0), (205.0, 120.0, -10.0)]
# 腕だけ揺らす: (始まりの秒, 長さ)
sways = [(60.0, 4.0), (175.0, 5.0)]
DECL = math.radians(12)


def matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def mv(m, v):
    return [sum(m[i][k] * v[k] for k in range(3)) for i in range(3)]


def tr(m):
    return [[m[j][i] for j in range(3)] for i in range(3)]


def rx(a):
    c, s = math.cos(a), math.sin(a)
    return [[1, 0, 0], [0, c, -s], [0, s, c]]


def ry(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


def rz(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, -s, 0], [s, c, 0], [0, 0, 1]]


def quat(m):
    tr_ = m[0][0] + m[1][1] + m[2][2]
    w = math.sqrt(max(0.0, 1 + tr_)) / 2
    x = math.copysign(math.sqrt(max(0.0, 1 + m[0][0] - m[1][1] - m[2][2])) / 2, m[2][1] - m[1][2])
    y = math.copysign(math.sqrt(max(0.0, 1 - m[0][0] + m[1][1] - m[2][2])) / 2, m[0][2] - m[2][0])
    z = math.copysign(math.sqrt(max(0.0, 1 - m[0][0] - m[1][1] + m[2][2])) / 2, m[1][0] - m[0][1])
    return w, x, y, z


def smoothstep(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def hand(t):
    """手による (向きのずれ, 傾き, 横の傾き) と、手の加速度(地面の座標、G)"""
    yaw, tilt = math.radians(25), math.radians(40)
    acc = [0.0, 0.0, 0.0]
    for t0, dy, dt_ in regrips:
        r = smoothstep(t - t0)
        yaw += math.radians(dy) * r
        tilt += math.radians(dt_) * r
        if t0 <= t <= t0 + 1:
            k = math.sin(2 * math.pi * (t - t0))
            acc = [0.25 * k, -0.2 * k, 0.15 * k]
    for t0, d in sways:
        if t0 <= t <= t0 + d:
            k = math.sin(2 * math.pi * 1.2 * (t - t0))
            acc = [acc[0] + 0.15 * k, acc[1] + 0.1 * k, acc[2]]
    # 体のゆっくりした揺れ
    tilt += math.radians(3) * math.sin(2 * math.pi * 0.23 * t)
    side = math.radians(4) * math.sin(2 * math.pi * 0.17 * t + 1)
    return yaw, tilt, side, acc


def attitude(t, heading):
    """端末→地面の回転。heading は真北から時計回り(rad)"""
    yaw_h, tilt, side, acc = hand(t)
    car_w = -heading - DECL  # 地面の座標(x=磁北, y=西)での車の向き(左回り)
    return matmul(rz(car_w + yaw_h), matmul(rx(tilt), ry(side))), acc


t0 = 1794000000.0
dt = 1.0 / MOT_HZ
t, v, heading = 0.0, 0.0, 0.3
lat, lon = 35.0, 139.0
mot_lines, loc_lines, truth_lines = [], [], []
step = 0
next_loc = 0.0
prev_R = None
for dur, v_end, yaw_rate in plan:
    steps = int(round(dur * MOT_HZ))
    v_start = v
    for k in range(steps):
        r = (k + 1) / steps
        v_new = v_start + (v_end - v_start) * (0.5 - 0.5 * math.cos(math.pi * r))
        a_lon = (v_new - v) / dt
        v = v_new
        yaw = yaw_rate if v > 1 else 0.0
        a_lat = v * yaw
        heading -= yaw * dt  # 左回りの yaw で、時計回りの方位は減る
        lat += v * math.cos(heading) * dt / 111195
        lon += v * math.sin(heading) * dt / (111195 * math.cos(math.radians(35)))
        t += dt
        R, hacc = attitude(t, heading)
        car_w = -heading - DECL
        fw = [math.cos(car_w), math.sin(car_w), 0]
        lw = [-math.sin(car_w), math.cos(car_w), 0]
        moving = v > 0.3
        noise = 0.02 if moving else 0.002
        aw = [(a_lon * fw[c] + a_lat * lw[c]) / G0 + hacc[c] for c in range(3)]
        Rt = tr(R)
        acc = [x + rnd.gauss(0, noise) for x in mv(Rt, aw)]
        grav = mv(Rt, [0, 0, -1])
        if prev_R is None:
            prev_R = R
        d = matmul(tr(prev_R), R)  # 端末の座標での小さな回転
        rotv = [(d[2][1] - d[1][2]) / 2 / dt, (d[0][2] - d[2][0]) / 2 / dt, (d[1][0] - d[0][1]) / 2 / dt]
        rotv = [x + rnd.gauss(0, 0.01 if moving else 0.003) for x in rotv]
        prev_R = R
        q = quat(R)
        mot_lines.append(",".join(f"{x:.4f}" for x in [t0 + t] + acc + grav + rotv)
                         + "," + ",".join(f"{x:.5f}" for x in q) + ",\n")
        step += 1
        if step % (MOT_HZ // 10) == 0:
            busy = 1 if any(a <= t <= a + 1 for a, _, _ in regrips) else 2 if any(a <= t <= a + d for a, d in sways) else 0
            truth_lines.append(f"{t0 + t:.3f},{a_lon / G0:.4f},{a_lat / G0:.4f},{busy}\n")
        if t >= next_loc:
            next_loc += 1.0
            sp = max(0.0, v + rnd.gauss(0, 0.15 if moving else 0.3))
            jl = rnd.gauss(0, 2e-6)
            cs = math.degrees(heading) % 360 if v > 1 else -1.0
            loc_lines.append(f"{t0 + t:.3f},{lat + jl:.7f},{lon + jl:.7f},30.00,5.0,4.0,{sp:.2f},0.50,"
                             f"{cs:.1f},5.0,\n")

with open(os.path.join(out, "motion.csv"), "w") as f:
    f.write("unix_s,ax_g,ay_g,az_g,grav_x,grav_y,grav_z,rot_x_rads,rot_y_rads,rot_z_rads,q_w,q_x,q_y,q_z,heading_deg\n")
    f.writelines(mot_lines)
with open(os.path.join(out, "location.csv"), "w") as f:
    f.write("unix_s,lat,lon,alt_m,h_acc_m,v_acc_m,speed_ms,speed_acc_ms,course_deg,course_acc_deg,floor\n")
    f.writelines(loc_lines)
with open(os.path.join(out, "truth.csv"), "w") as f:
    f.write("unix_s,lon_g,lat_g,hand\n")
    f.writelines(truth_lines)
print(f"{len(mot_lines)} motion rows, {len(loc_lines)} location rows, {t:.0f} s")
