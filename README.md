# drive-logger-ios

自分用の iPhone 走行ロガー。GPS・加速度・回転・気圧を記録し、走行が終わったら自宅の MiniPC で動いている
[国道制覇マップ](https://github.com/Yzvica/National-Route-Conquest-Map) へ自動で送る。

- 対象: iOS 16 以降(ログ専用の iPhone X を想定)
- 画面を消しても、ほかのアプリを開いても記録を続ける(位置情報を「常に」許可する)
- 走行ごとに `Documents/logs/<yyyyMMdd-HHmmss>/` に保存する。「ファイル」アプリの「このiPhone内」→「走行ロガー」からも見られる

## 記録するファイル

| ファイル | 中身 | 頻度 |
| --- | --- | --- |
| track.gpx | 精度 50m 以内の位置・高度・時刻・速度。地図に送る | 1Hz |
| location.csv | 位置のすべて(精度・速度の精度・進行方向を含む) | 1Hz |
| motion.csv | 加速度(重力を除く、g)・重力の向き・回転(rad/s)・姿勢(クォータニオン)・方位 | 50Hz(設定で 25/100) |
| pressure.csv | 気圧(hPa)・記録開始からの相対高度(m) | 約1Hz |
| meta.json | 端末・時刻の対応・距離・目印(目印 / 動画の同期)・送信状況 | - |

時刻はどれも UNIX 秒(UTC)。

## 合図の音

消音モードでも鳴る(音楽など、ほかのアプリの音は止めない)。鳴った時刻は meta.json の `markers` に残る。

| いつ | 音 | meta.json |
| --- | --- | --- |
| 記録開始(自動)・「同期」ボタン | 2000Hz を 0.12 秒 × 3 回(間は 0.08 秒の無音。全体 0.52 秒)。画面も光る | `kind: "sync"`。時刻は 1 回目の音の出だし |
| 「目印」ボタン | 1500Hz を 0.08 秒 × 1 回 | `kind: "mark"` |
| 記録停止 | 800Hz 0.15 秒 → 無音 0.08 秒 → 600Hz 0.2 秒 | 残さない |

DJI Mic で同期音を拾えば、動画の音声から 2000Hz の 3 連音を探して、ログと動画の時刻を合わせられる。

## 地図への送信

- `track.gpx` → `POST /api/inbox?name=<走行ID>.gpx`(地図が国道の判定をする)
- 生データ → `PUT /api/rawlog?session=<走行ID>&file=<ファイル名>`(MiniPC が Google ドライブの `_drivelog` に置く)
- 記録を止めたら、送り終えるまで(最長 15 分)精度を落とした位置の更新を続けてアプリを起こしておく。画面を消しても、テザリングで送れるまで 30 秒ごとに送り直す
- 通信できないときは端末に残し、Wi-Fi やテザリングにつながったとき、またはアプリを開いたときに送り直す
- 送り先は設定画面で変えられる。既定は `http://192.168.11.123:8080`。外出先からは Tailscale のアドレスを使う

## ビルドと iPhone への入れ方(Mac なし・無料の Apple ID)

1. GitHub の Actions「ビルド(署名なし IPA)」が、push のたびに `DriveLogger-unsigned.ipa` を作る(Actions の実行結果の Artifacts から zip でダウンロードして展開する)
2. Windows に [Sideloadly](https://sideloadly.io/) と iTunes(Apple のサイト版)を入れる
3. iPhone を USB でつなぎ、Sideloadly に IPA をドロップし、Apple ID を入れて Start
4. iPhone の「設定」→「一般」→「VPNとデバイス管理」で、自分の Apple ID を信頼する
5. iOS 16 以降は「設定」→「プライバシーとセキュリティ」→「デベロッパモード」をオンにする(初回のみ。再起動が必要)

無料の Apple ID では 7 日で起動できなくなるので、旅行の前に 3 からやり直す(ログは消えない)。

## 開発

Xcode プロジェクトは [XcodeGen](https://github.com/yonaskolb/XcodeGen) で `project.yml` から作る(`xcodegen generate`)。
