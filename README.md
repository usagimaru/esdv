# esdv

Earthsoft社製キャプチャーボードPV3 / PV4用の独自DVファイルをmacOSで扱えるようにするSwift製コマンドラインツールです。esdvはEarthsoft DVファイルのデコード機能のみを有しており、ffmpegにパイプしてApple ProRes / H.264 / H.265等にエンコードします。

macOS環境でEarthsoft DVファイルをどうにか扱えるようにすることを目的にしています。PV3 / PV4キャプチャーボードをMacに対応させたり、AviUtilのパイプラインをMacで再現することを目的とはしていません。Windows / Linux環境での利用も想定していません。

## 対応フォーマット

| 出力フォーマット | コーデック | ファイル形式 | 備考 |
|-----------------|-----------|-------------|------|
| `prores`(デフォルト) | Apple ProRes 422 HQ | .mov | `prores_422hq`と同じ |
| `prores_422hq` | Apple ProRes 422 HQ | .mov | ~220Mbps @1080p/29.97、視覚的ロスレス、グレーディング向け |
| `prores_proxy` | Apple ProRes 422 Proxy | .mov | ~45Mbps @1080p/29.97、オフライン編集用プロキシ |
| `prores_lt` | Apple ProRes 422 LT | .mov | ~102Mbps @1080p/29.97、軽量編集・容量重視 |
| `prores_422` | Apple ProRes 422 | .mov | ~147Mbps @1080p/29.97、標準的な編集・納品 |
| `prores_4444` | Apple ProRes 4444 | .mov | ~330Mbps @1080p/29.97、合成・VFX、4:4:4にアップサンプル |
| `prores_4444xq` | Apple ProRes 4444 XQ | .mov | ~500Mbps @1080p/29.97、HDR・最高品質、4:4:4にアップサンプル |
| `h264` | H.264 | .mp4 | VideoToolboxハードウェアエンコード（対応するApple Siliconが必要） |
| `h265` | H.265/HEVC | .mp4 | VideoToolboxハードウェアエンコード（対応するApple Siliconが必要） |
| `h264sw` | H.264 | .mp4 | libx264ソフトウェアエンコード (CRF 18, preset slow) |
| `h265sw` | H.265/HEVC | .mp4 | libx265ソフトウェアエンコード (CRF 20, preset slow) |
| `yuv` | Raw YUV 4:2:2p | .yuv | 無圧縮プレーナー |

ProResはどれもソフトウェアエンコードです。

### 音声コーデック

| 音声コーデック | 指定値 | 備考 |
|--------------|--------|------|
| PCM無圧縮(デフォルト) | `wave` | WAV形式のまま映像にmux |
| Apple Lossless | `alac` | ロスレス圧縮、PCMの約1/3のサイズ |

## 必要環境

- macOS 14 (Sonoma)以降（Tahoe, 26.4環境でテスト済み）
- Swift 5.9以降
- ffmpeg (`brew install ffmpeg`)

## ビルド

```bash
swift build -c release
# バイナリは .build/release/esdv に生成されます
```

インストール（任意）:

```bash
cp .build/release/esdv /usr/local/bin/
```

## 使い方

### ファイル情報の確認

```bash
esdv info capture.dv
```

出力例:

```
=== Earthsoft DV ファイル情報 ===
ファイル: capture.dv
コーデック: PV3
解像度: 1440 x 1080
走査方式: インターレース
フィールドオーダー: TFF (Top Field First)
フレーム数: 898
音声サンプリング周波数: 48000 Hz
音声チャンネル: 2ch
音声ビット深度: 16bit PCM
表示比率: 4:3
```

### 変換

```sh
# ProRes 422 HQ (デフォルト)
esdv convert capture.dv

# H.264 (VideoToolbox HW)
esdv convert -f h264 capture.dv output.mp4

# H.265 (VideoToolbox HW)
esdv convert -f h265 capture.dv output.mp4

# H.264 (libx264 SW)
esdv convert -f h264sw capture.dv output.mp4

# H.265 (libx265 SW)
esdv convert -f h265sw capture.dv output.mp4

# 音声をALAC (Apple Lossless) にエンコード
esdv convert -a alac capture.dv

# フレームレートを指定 (デフォルト: 29.97)
esdv convert -f prores -r 29.97 capture.dv output.mov

# 出力パスを明示 (-o オプション)
esdv convert -f h264 -o /path/to/output.mp4 capture.dv

# 入力ファイルだけ指定 (拡張子を自動で変えて同じ場所に出力)
esdv convert capture.dv

# convert サブコマンドは省略可
esdv capture.dv
```

## 技術情報

### ファイルフォーマット

仕様: https://earthsoft.jp/PV/tech-file.html

```
[先頭 16384 バイト: ファイルヘッダ]
  オフセット   0: マジック "PV3"
  オフセット   3: コーデックバージョン (現在は 2)
  オフセット   4: 水平ピクセル数÷16
  オフセット   5: 垂直ピクセル数÷8
  オフセット   6: フラグ (bit0: 0=インターレース/1=プログレッシブ)
  オフセット 256: 量子化テーブル (輝度+色差, 各64要素×2バイト, ビッグエンディアン)

[以降: 音声・映像フレームデータの連続]
  各フレーム先頭 512 バイト: フレームヘッダ
  フレームヘッダ以降: 音声PCM (16bit BE) → 映像領域0〜3
  次フレームは 4096 バイト境界から開始
```

### コーデック

仕様: [https://earthsoft.jp/PV/tech-codec.html](https://earthsoft.jp/PV/tech-codec.html)

- **映像**: DV VLC (IEC 61834 / SMPTE 370M互換) DCTコーデック
  - YCbCr 4:2:2、8bitサンプリング
  - マクロブロック: 通常16×16、最下段32×8(高さが16の倍数でない場合)
  - DCTモード: フレームモード / フィールドモード(インターレースのみ)
  - 量子化: DC係数9bit符号付き(×4, IDCT 1/8正規化考慮)、AC係数は量子化テーブルとqFlagによる右シフト
  - VLC: 12-bitルックアップテーブル(4096エントリ) + 13-bit run拡張 / 16-bit level拡張
  - 領域分割: インターレース=4領域、プログレッシブ=2領域(インターリーブ割り当て)

- **音声**: 2ch 16bit PCM無圧縮(ビッグエンディアン)
  - サンプリング周波数はフレームヘッダで可変(通常48000 Hz)

### 変換パイプライン

チャンク単位で複数フレームを全CPUコアで並列デコードし、順序通りにffmpegへパイプ書き込みするストリーミング方式。Earthsoft DVコーデックにはフレーム間予測がないため、各フレームは独立してデコード可能です。

```
.dv ファイル (mmap)
  ├─ ESDVParser        ファイルヘッダ・フレームヘッダ・領域オフセット解析
  ├─ ESDVDecoder       DV VLC デコード → 逆量子化 → IDCT → YUV 4:2:2p
  │    └─ 並列デコード: チャンク単位で全コア同時実行 (GCD concurrentPerform)
  ├─ FFmpegPipe        rawvideo (yuv422p) を stdin パイプで ffmpeg に供給
  │    └─ 映像エンコード: ProRes / H.264 / H.265 (HW/SW)
  ├─ 音声 WAV          PCM バイトスワップ (BE→LE) → WAV 一時ファイル
  └─ mux               映像+音声を ffmpeg で合成 → 最終出力 (音声: PCM/ALAC)
```

### ファイル構成

```
Sources/esdv/
  main.swift          CLI エントリポイント、convert/info サブコマンド、並列デコードパイプライン
  ESDVParser.swift    ファイル/フレームヘッダ解析、領域データ抽出 (mmap)
  ESDVDecoder.swift   VLC デコード、逆量子化、IDCT (行-列分離法)、YUV422p 出力
  FFmpegPipe.swift    ffmpeg プロセス管理、映像パイプ、音声 WAV、mux、11出力フォーマット対応
```

## 既知の制限と留意事項

- Earthsoft DVファイルは、通常のIEC 61834 DV (miniDVテープ)とは**まったく別のフォーマット**です
- macOS (Tahoe, 26.4でテスト)およびSwiftプログラミング言語を前提としています。WindowsやLinux環境では動作を想定していません
- インターレース素材はインターレースフラグを維持してエンコードします。デインターレース処理は行いません。編集時にはフィールドオーダー(TFF/BFF)を適切に設定してください
- コーデックバージョン2のみ対応
- フレームレートは手動指定(デフォルト29.97fps)。プログレッシブ素材では`-r 59.94`の指定が必要な場合がありますが、十分なテストを行えていません
- ProResはどれもprores_ksによるソフトウェアエンコードです。ハードウェアエンコード（VideoToolbox）はprores_ksに比べて十分なパフォーマンスを出せなかったため
- ソースファイルのビットストリームにエラー（不正なrun length等）が含まれる場合、該当フレームの映像にノイズが生じます。DV VLCにはリージョン内の再同期マーカーがないため、デコーダー側での回復はできません。リファレンス実装（smdn.jp libavパッチ）でも同様の結果になります。変換時にエラーが検出された場合は該当フレーム番号を警告出力します

## 参考資料

- [Earthsoft PVファイルフォーマット仕様](https://earthsoft.jp/PV/tech-file.html)
- [Earthsoft PVコーデック仕様](https://earthsoft.jp/PV/tech-codec.html)
- [Libav用PV4デコーダ(smdn.jp)](https://smdn.jp/softwares/libav/pv4/) — リファレンス実装(MIT X11)

## ライセンス

MITです。[LICENSE](LICENSE)を確認してください。
