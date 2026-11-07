# 運転評価の照合

`DriveLogger/Sources/DriveEval.swift` は、gbowl-log-formatter の `src/drivelog2gbowl.py`(車の向きの推定・10 Hz・停止の判定)と
`src/drive_eval.py`(5 項目と出来事)を Swift に移したものです。CI(macOS)で、作り物の走行データ(`fixture/`)を両方に通し、同じ結果になるかを確かめます。

計算を変えたら、Python 版も同じように直し、`expected.json` を作り直してください。

```
python3 make_fixture.py fixture
cd <gbowl-log-formatter>/src
python3 -c "import json,drivelog2gbowl as d,drive_eval;f='<このフォルダ>/fixture';_,l,m=d.load_session(f);a=d.vehicle_axes(l,m);s0,s1=max(l[0]['t'],m[0][0]),min(l[-1]['t'],m[-1][0]);json.dump(drive_eval.evaluate(d.resample(l,m,a,s0,s1,quiet=True),s0),open(f+'/../expected.json','w'),ensure_ascii=False,indent=1)"
```
