# アプリのアイコン(icon.svg)を作る。道は中心線に沿って、手前ほど広くなるように輪郭を計算する
#   python make_icon.py > icon.svg  → Chromium などで 1024x1024 の PNG にする(README 参照)
import math

def bez(p, t):
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = p
    u = 1 - t
    return (u**3*x0 + 3*u*u*t*x1 + 3*u*t*t*x2 + t**3*x3, u**3*y0 + 3*u*u*t*y1 + 3*u*t*t*y2 + t**3*y3)

# 地面の上の道(横の位置 x[m]、奥行き z[m])をカメラから見た形にする。道は奥へ向かって S 字に曲がる
HORIZON, CAM_H, F = 565, 1.4, 330.0
def project(x, z):
    return 512 + F * x / z, HORIZON + F * CAM_H / z
zs = [0.85 * 1.06 ** i for i in range(85)]
left, right, pts = [], [], []
for z in zs:
    c = 0.35 + 2.6 * math.sin((z - 2) / 5.5)   # 道の中心
    pts.append(project(c, z))
    left.append(project(c - 1.25, z))
    right.append(project(c + 1.25, z))
road = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in left + right[::-1]) + " Z"
# 中央線は遠くまで描くと点線が詰まって見づらいので、手前だけ
line = "M" + " L".join(f"{x:.1f} {y:.1f}" for (x, y), z in zip(pts, zs) if z < 18)

print(f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#0a1633"/><stop offset="0.6" stop-color="#173f7a"/><stop offset="1" stop-color="#e9925a"/>
    </linearGradient>
    <linearGradient id="ground" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#1b4a3a"/><stop offset="1" stop-color="#0d2a22"/>
    </linearGradient>
    <linearGradient id="road" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#4a5260"/><stop offset="1" stop-color="#1a1f27"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#7dffb2" stop-opacity="0.85"/><stop offset="1" stop-color="#7dffb2" stop-opacity="0"/>
    </radialGradient>
    <clipPath id="below"><rect y="565" width="1024" height="459"/></clipPath>
  </defs>
  <rect width="1024" height="565" fill="url(#sky)"/>
  <path d="M0 565 L150 500 L270 540 L420 470 L560 540 L720 480 L860 530 L1024 490 L1024 565 Z" fill="#1d3a62"/>
  <rect y="565" width="1024" height="459" fill="url(#ground)"/>
  <g clip-path="url(#below)">
    <path d="{road}" fill="url(#road)"/>
    <path d="{line}" fill="none" stroke="#ffd34d" stroke-width="16" stroke-linecap="round" stroke-dasharray="46 40"/>
  </g>
  <g transform="translate(512 290)">
    <circle r="185" fill="#06142b" fill-opacity="0.4" stroke="#ffffff" stroke-width="16"/>
    <circle r="92" fill="none" stroke="#7dffb2" stroke-width="12"/>
    <line x1="-185" y1="0" x2="185" y2="0" stroke="#ffffff" stroke-opacity="0.35" stroke-width="6"/>
    <line x1="0" y1="-185" x2="0" y2="185" stroke="#ffffff" stroke-opacity="0.35" stroke-width="6"/>
    <circle cx="26" cy="-20" r="80" fill="url(#glow)"/>
    <circle cx="26" cy="-20" r="40" fill="#7dffb2"/>
  </g>
</svg>''')
