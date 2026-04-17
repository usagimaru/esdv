# esdv開発ノート

## リファレンス

- [Earthsoft PVファイルフォーマット仕様](https://earthsoft.jp/PV/tech-file.html)
- [Earthsoft PVコーデック仕様](https://earthsoft.jp/PV/tech-codec.html)
- [Libav用PV4デコーダ(smdn.jp)](https://smdn.jp/softwares/libav/pv4/) — リファレンス実装(MIT X11)
- [FFmpeg DV VLC data](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/dvdata.c) (LGPL 2.1+)
- [macOS環境でEarthsoft PV3/PV4 DVファイルを変換する方法](https://gist.github.com/usagimaru/f45f924332d1d877e3e19e7d19306a79)


## 基本設計

### 目的

Earthsoft PV3/PV4キャプチャーボードの独自フォーマット`.dv`ファイルをmacOS上でProRes/H.264/H.265に変換するSwift製CLIツール。ffmpegにはEarthsoft DVのデコーダーが存在しないため、自前でDV VLCビットストリームデコーダーを実装する。

### アーキテクチャ

```
.dv ファイル (mmap)
  │
  ├─ ESDVParser        ファイルヘッダ・フレームヘッダ・領域オフセット解析
  │    - ファイルヘッダ (16384B): マジック "PV3"、解像度、量子化テーブル
  │    - フレームヘッダ (512B): 音声情報、映像領域サイズ (4×uint32 BE)
  │    - 音声 PCM (16bit BE) / 映像領域データの分離
  │
  ├─ ESDVDecoder       映像デコーダー
  │    - DV VLC テーブル (12-bit ルックアップ 4096 エントリ + 13/16-bit 拡張)
  │    - DC 9bit 符号付き ×4 / AC 逆量子化 (qTable × level >> acScale)
  │    - 逆ジグザグスキャン
  │    - 8×8 IDCT (行-列分離法、事前確保ワークスペース)
  │    - フレームモード / フィールドモード (rowStep=2) 書き込み
  │    - インターリーブ領域→MB行マッピング + pad 領域
  │    - YUV 4:2:2 プレーナー出力
  │
  ├─ FFmpegPipe        ffmpeg パイプライン
  │    - rawvideo (yuv422p) を stdin パイプで ffmpeg に供給
  │    - ProRes (prores_ks SW) / H.264・H.265 (VideoToolbox HW / libx264・libx265 SW)
  │    - インターレースフラグ維持 (-flags +ildct, -vf setfield)
  │    - 音声は WAV 一時ファイル経由 (PCM BE→LE 変換)
  │    - 映像+音声を mux して最終出力
  │
  └─ ESDVCLI           コマンドラインインターフェース
       - info / convert サブコマンド
       - ストリーミングパイプライン (1フレームずつデコード+書き込み、~3MB/frame)
```

### 仕様参照

| 項目 | URL / ソース |
|------|-------------|
| ファイルフォーマット | https://earthsoft.jp/PV/tech-file.html |
| コーデック仕様 | https://earthsoft.jp/PV/tech-codec.html |
| VLCテーブル | FFmpeg `dv_vlc_data` (IEC 61834 / SMPTE 370M), 409エントリと照合済み |
| リファレンス実装 | smdn.jp libav earthsoftdv patch (MIT X11) |

---

## 当初の実装からの修正

当初実装には多数の根本的な誤りがあり、出力は完全なノイズだった。以下の修正を実施した。

### 1. VLCテーブルの全面書き換え(致命的)

**当初**: MPEG-2風の手書きビットツリー（`1` = EOB, `011s` = (0, ±1)等）
**修正後**: DV VLCテーブル(IEC 61834 / SMPTE 370M互換)
- 12-bitルックアップテーブル(4096エントリ)による高速デコード
- 2〜12 bitの標準コード89エントリ
- 13-bit run拡張(prefix `1111110` + 6-bit run)
- 16-bit level拡張(prefix `1111111` + 9-bit signed level)
- EOBは4-bitコード`0110`

VLCテーブルのrun/level値はFFmpegの`ff_dv_vlc_run` / `ff_dv_vlc_level`配列（409エントリ）と照合済み。正準ハフマン構成によりコード値を導出。

### 2. DC係数のスケーリング(致命的)

**当初**: `dc * 32`（仕様の「係数32」をそのまま乗算と解釈）
**修正後**: `dc * 4`（`dc * 32 >> 3`。IDCTの1/8スケーリングを考慮）

仕様上の「DC係数9bit(係数32)」は、DCの固定量子化ステップが32であることを意味する。しかしリファレンス実装(smdn.jp)では`block[0] = (dc << 2) + 1024`となっており、標準IDCTのDCスケーリング(1/8)を考慮して`dc * 32 / 8 = dc * 4`が正しい。`+1024`はFFmpeg IDCT用のレベルシフト(128 × 8)であり、本実装では書き込み時に`+128`するため不要。

### 3. AC係数のスケーリング(致命的)

**当初**: `level * quantTable[i]`(Qフラグで`quantTable * 2`)
**修正後**: `(level * quantTable[i]) >> acScale`(`acScale = 3 - qFlag`)

- `qFlag = 0` → `>> 3` (1/8)
- `qFlag = 1` → `>> 2` (1/4、AC係数を2倍にする効果)

smdn.jpパッチの`ac_scale = (5 - q) - 2`に対応。当初実装は逆量子化の右シフトが欠落しており、係数が約8倍過大だった。

### 4. 色差サブサンプリング: 4:2:0 → 4:2:2(致命的)

**当初**: YUV 4:2:0(色差プレーン = width/2 × height/2)
**修正後**: YUV 4:2:2(色差プレーン = width/2 × height)

1マクロブロック(16×16)あたり8 DCTブロック:
- Y0, Y1, Y2, Y3(輝度4ブロック = 16×16)
- Cr0, Cr1(色差赤2ブロック = 8×16)
- Cb0, Cb1(色差青2ブロック = 8×16)

色差が2ブロック/コンポーネントなのは水平のみ半分(4:2:2)であることを示す。仕様の「色差成分の水平方向サンプリング周波数は輝度成分の半分です」、およびsmdn.jpパッチの`AV_PIX_FMT_YUV422P`と一致する。

### 5. フレームオフセット計算の修正(重大)

**当初**: `frameHeaderSize (512) + frameDataSize()`で次フレームへ進む
**修正後**: `frameDataSize()`のみ（内部で512Bヘッダ込みの計算をしているため）

`frameDataSize()`は`align(512 + audioByteSize, 4096) + videoTotal`を返しており、既に512Bのフレームヘッダオフセットを含んでいた。呼び出し側でさらに512を加算すると二重カウントになり、フレーム数が6しか検出されなかった（修正後は898フレーム）。

### 6. フィールドモードDCTの処理方式変更(重大)

**当初**: IDCT後にブロック対の行を入れ替え（applyFieldModeSwap）
**修正後**: 書き込み時に`rowStep = 2`で1行おきに出力

フィールドモードでは、縦方向に隣接する2ブロック(Y0/Y1, Y2/Y3, Cr0/Cr1, Cb0/Cb1)がそれぞれ偶数フィールド・奇数フィールドの行を保持する。smdn.jpパッチでは`y_stride`を2倍にすることで対応。本実装では`write8x8Block`に`rowStep`パラメータを追加して同等の処理を実現。

### 7. 最下段32×8マクロブロックの列数修正(中)

**当初**: 最下段でも`width / 16`列（通常と同じ）
**修正後**: 最下段は`width / 32`列（MB幅が32に拡大するため半分）

垂直ピクセル数が16の倍数でない場合、最下段MBは32×8になる。輝度ブロックが横4並び(Y0, Y2, Y1, Y3)になるため、列数が半分になる。

### 8. Package.swiftの`-Ounchecked`削除

未定義動作のリスクがあるため削除。

---

## 修正済みのバグ(設計見直し時に解決)

### 1. VLC levelエスケープのビット数(致命的)
- **旧**: 7-bit prefix + 8-bit level = 15 bits
- **修正後**: 7-bit prefix + 9-bit level = **16 bits**(smdn.jpパッチと一致)
- 1ビットのずれが全後続ブロックのVLC同期を破壊していた

### 2. 領域→MB行マッピング(致命的)
- **旧**: 連続割り当て(領域0 = 行0-16, 領域1 = 行17-33, ...)
- **修正後**: **インターリーブ割り当て**(領域i = 行i, i+4, i+8, ...)
- smdn.jp `esdv_decode_block_thread`に準拠。pad領域のロジックも実装

### 3. ACループのEOB未消費(致命的)
- **旧**: `while coefIdx < 64`で全係数充填後にループ終了 → 末尾のEOB(4bit)未消費
- **修正後**: `while true` + EOB breakの無限ループ(smdn.jp: `for (i=1;;)`と同等)
- 高詳細ブロックで全64係数が埋まると、次ブロックが4ビットずれて破損

### 4. VLC skipコードのcoefIdx進行(中)
- **旧**: `coefIdx += run`(level=0時は+1しない)
- **修正後**: `coefIdx += run; ... coefIdx += 1`(level=0でも常に+1)
- smdn.jpでは`i += run; block[i] = ...; i++;`と常に+1する

### 5. 最下段MBのfieldmodeビット未読(中)
- **旧**: `!isProgressive && !isBottom`で最下段では読まない
- **修正後**: インターレース時は最下段でも常にfieldmodeビットを読む
- smdn.jpでは`if (s->interlaced) { get_bits1(gb); ... }`で無条件読み取り

### 6. 音声PCMのエンディアン(中)
- **旧**: ファイルのPCMをそのままWAVに書き出し(BEのまま)
- **修正後**: 16-bitサンプルをバイトスワップしてLEに変換

### 7. FFmpegPipeのYUV420 → YUV422(軽微)
- rawYUVのffmpeg引数、ヘルプテキスト、コメントを4:2:2に統一

### 8. ffmpeg muxハング(中)
- **旧**: muxプロセスがstdinからの入力待ちでハング
- **修正後**: `-nostdin`フラグ + `standardInput = FileHandle.nullDevice`

### 9. インターレースフラグ欠落(中)
- **旧**: ProRes出力で`interlaced_frame=0`(プログレッシブ扱い)
- **修正後**: `-flags +ildct` + `-vf setfield=tff/bff`でインターレースフラグを維持

### 10. ストリーミングパイプライン(設計改善)
- 全フレーム一括デコード → 1フレームずつデコード+パイプ書き込み
- メモリ使用量: ~2.6GB → ~3MB (1080p)

### 11. 高速IDCT(性能改善)
- 4重ループO(N^4) → 行-列分離法O(N^2)(約4倍高速)
- フラットcosineテーブル + アンロール済み内部ループ

### 12. バッファ事前確保(性能改善)
- IDCTワークスペース、DCT出力、8ブロック分バッファを再利用
- 9130フレームファイルで~444M回のアロケーション削減

---

## 不採用とした最適化

### vDSP IDCT
- Accelerate vDSP_mmulDを試したが8×8行列では関数呼び出しオーバーヘッドが支配的
- 手動ループの方が高速だったため不採用

### VideoToolbox ProRes (prores_videotoolbox)
- HWエンコーダーだがprores_ks(SWマルチスレッド)より低速(31s vs 27s @898 frames)
- CPU 100%固定でマルチコアを活用できず、インターレースフラグも消失
- prores_ksがマルチスレッドで350% CPUを活用でき、品質・互換性も良好

---

## 未解決の課題

### フレームレート自動判定
- 現在はデフォルト29.97fps固定。プログレッシブ素材では59.94fpsが適切だが自動判定していない

### 性能の更なる改善
- 領域並列デコード(Swift Concurrency TaskGroup)は未実装
- 整数IDCT(AAN等)への置換で更に高速化可能

---

## 当初設計との差異

| 項目 | 当初の想定 | 実際 |
|------|-----------|------|
| 色差サブサンプリング | 4:2:0 | **4:2:2** |
| VLC体系 | SMPTE 270M(MPEG-2風) | **DV VLC (IEC 61834 / SMPTE 370M)** |
| VLC level拡張 | 15-bit(8-bit level) | **16-bit(9-bit level)** |
| DC量子化 | `dc * 32`(直接乗算) | **`dc * 4`**(IDCTスケーリング考慮) |
| AC量子化 | `level * qTable` | **`(level * qTable) >> acScale`** |
| ACループ | `while coefIdx < 64` | **`while true` + EOB break** |
| 領域→MB行 | 連続割り当て | **インターリーブ + pad領域** |
| フィールドモード | ブロック内行入替え | **書き込み時rowStep=2** |
| 最下段MB | 通常と同じ列数 | **列数半減(32px幅)** |
| フレーム数算出 | 6(オフセット誤り) | **898**(正しいオフセット) |
| 音声PCM | そのままWAVに書き出し | **BE→LEバイトスワップ** |
| デフォルトfps | 59.94 | **29.97**(1080i向け) |
| メモリ使用量 | ~2.6GB(全フレーム一括) | **~3MB**(ストリーミング) |
| ProResエンコーダー | prores_videotoolbox (HW) | **prores_ks (SW)**マルチスレッド |

---

## ファイル構成

```
Sources/esdv/
  main.swift          CLI エントリポイント、convert/info サブコマンド、ストリーミングパイプライン
  ESDVParser.swift    ファイル/フレームヘッダ解析、領域データ抽出 (mmap)
  ESDVDecoder.swift   VLC デコード、逆量子化、IDCT (行-列分離法)、YUV422p 出力
  FFmpegPipe.swift    ffmpeg プロセス管理、映像パイプ、音声 WAV、mux、6 出力フォーマット対応
```
