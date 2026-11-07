# アプリのアイコン

夕暮れの曲がり道と、G メーター(内側の円に収まった緑の点 = 酔いにくい、なめらかな運転)。

作り直すとき:

```
python3 tools/icon/make_icon.py > tools/icon/icon.svg
```

`icon.svg` を Chromium などで 1024×1024 の PNG にし(透明な部分は無くす)、
`DriveLogger/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` を置き換える。
角の丸めは iOS がするので、四角のままでよい。
