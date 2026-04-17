// main.swift
// esdv - Earthsoft DV (.dv) 変換ツール
// macOS 14+, Swift 5.9+

import Foundation

// MARK: - エントリポイント

let cli = ESDVCLI()
cli.run()

// MARK: - CLI

final class ESDVCLI {

    func run() {
        let args = CommandLine.arguments
        if args.count < 2 {
            printUsage()
            exit(1)
        }

        switch args[1] {
        case "convert":
            runConvert(args: Array(args.dropFirst(2)))
        case "info":
            runInfo(args: Array(args.dropFirst(2)))
        case "help", "--help", "-h":
            printUsage()
        default:
            if args[1].hasPrefix("-") || args.count < 2 {
                printUsage()
                exit(1)
            }
            runConvert(args: Array(args.dropFirst(1)))
        }
    }

    // MARK: - convert サブコマンド

    private func runConvert(args: [String]) {
        var inputPath: String?
        var outputPath: String?
        var format: OutputFormat = .prores
        var frameRate: Double = 29.97
        var verbose = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-f", "--format":
                i += 1
                guard i < args.count else { die("--format の後に値が必要です") }
                guard let f = OutputFormat(rawValue: args[i]) else {
                    die("不明なフォーマット: \(args[i])\n利用可能: \(OutputFormat.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                format = f
            case "-r", "--fps":
                i += 1
                guard i < args.count, let fps = Double(args[i]) else { die("--fps の後に数値が必要です") }
                frameRate = fps
            case "-o", "--output":
                i += 1
                guard i < args.count else { die("--output の後にパスが必要です") }
                outputPath = args[i]
            case "-v", "--verbose":
                verbose = true
            default:
                if args[i].hasPrefix("-") {
                    die("不明なオプション: \(args[i])")
                }
                if inputPath == nil {
                    inputPath = args[i]
                } else if outputPath == nil {
                    outputPath = args[i]
                }
            }
            i += 1
        }

        guard let input = inputPath else {
            printUsage(); exit(1)
        }

        let inputURL = URL(fileURLWithPath: input)
        let outURL: URL
        if let out = outputPath {
            outURL = URL(fileURLWithPath: out)
        } else {
            outURL = inputURL.deletingPathExtension().appendingPathExtension(format.fileExtension)
        }

        do {
            try convertFile(
                input: inputURL,
                output: outURL,
                format: format,
                frameRate: frameRate,
                verbose: verbose
            )
            print("完了: \(outURL.path)")
        } catch {
            fputs("エラー: \(error)\n", stderr)
            exit(1)
        }
    }

    // MARK: - ストリーミング変換パイプライン
    //
    // 1フレームずつデコード → ffmpeg パイプ書き込みを繰り返す。
    // 映像メモリ使用量はフレーム1枚分 (~3MB @1080p YUV422) に収まる。
    // 音声は WAV ヘッダ先行書き込み → PCM をフレームごとに追記。

    private func convertFile(
        input: URL,
        output: URL,
        format: OutputFormat,
        frameRate: Double,
        verbose: Bool
    ) throws {
        // 1. パース
        print("解析中: \(input.lastPathComponent)")
        let parser = try ESDVParser(contentsOf: input)
        let header = parser.fileHeader

        print("  解像度: \(header.width)x\(header.height) \(header.isProgressive ? "p" : "i")")
        print("  コーデック: PV\(header.codecVersion + 1)")

        let frames = try parser.enumerateFrames()
        guard !frames.isEmpty else {
            throw ESDVError.fileTooShort
        }

        let audioRate = Int(frames.first?.header.audioSampleRate ?? 48000)
        print("  フレーム数: \(frames.count)")
        print("  音声: \(audioRate) Hz / 2ch / 16bit PCM")
        print("  出力: \(output.lastPathComponent) [\(format.description)]")

        let decoder = ESDVDecoder(fileHeader: header)

        // 2. rawYUV は ffmpeg を介さず直接書き出し
        if format == .rawYUV {
            try writeRawYUVStreaming(
                frames: frames, decoder: decoder,
                to: output, verbose: verbose
            )
            return
        }

        // 3. 一時ファイルパス
        let baseName = output.deletingPathExtension().path
        let tempVideoURL = URL(fileURLWithPath: baseName + "_video_tmp." + format.fileExtension)
        let tempAudioURL = URL(fileURLWithPath: baseName + "_audio_tmp.wav")

        defer {
            try? FileManager.default.removeItem(at: tempVideoURL)
            try? FileManager.default.removeItem(at: tempAudioURL)
        }

        // 4. ffmpeg 映像エンコーダー起動
        let pipe = try FFmpegPipe(
            outputURL: tempVideoURL,
            format: format,
            width: header.width,
            height: header.height,
            frameRate: frameRate,
            isInterlaced: !header.isProgressive,
            bottomFieldFirst: header.bottomFieldFirst
        )
        try pipe.start()

        // 5. 音声 WAV: ヘッダを先に書き込み、PCM をフレームごとに追記
        let totalAudioSize = frames.reduce(0) { $0 + $1.header.audioByteSize }
        let audioHandle = try FFmpegPipe.createAudioWAV(
            at: tempAudioURL,
            totalPCMSize: totalAudioSize,
            sampleRate: audioRate
        )

        // 6. ストリーミングデコード + パイプ書き込み
        print("デコード+エンコード中...")
        for (idx, frame) in frames.enumerated() {
            let video = try decoder.decodeFrame(frame)
            try pipe.writeVideoFrame(video)

            if !frame.audioPCM.isEmpty {
                // Earthsoft 音声は 16-bit BE PCM → WAV 用に LE に変換
                audioHandle.write(swapAudioEndian(frame.audioPCM))
            }

            if verbose || (idx + 1) % 100 == 0 || idx == frames.count - 1 {
                print("  \(idx + 1) / \(frames.count) フレーム", terminator: "\r")
                fflush(stdout)
            }
        }
        print("")

        audioHandle.closeFile()
        try pipe.finish()

        // 7. 映像+音声 mux
        print("映像・音声を合成中...")
        try FFmpegPipe.mux(
            videoURL: tempVideoURL,
            audioURL: tempAudioURL,
            outputURL: output,
            format: format
        )
    }

    // MARK: - rawYUV ストリーミング書き出し

    private func writeRawYUVStreaming(
        frames: [ESDVFrame],
        decoder: ESDVDecoder,
        to url: URL,
        verbose: Bool
    ) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw ESDVError.fileTooShort
        }
        defer { handle.closeFile() }

        print("デコード+書き出し中...")
        for (idx, frame) in frames.enumerated() {
            let video = try decoder.decodeFrame(frame)
            try handle.write(contentsOf: video.yPlane)
            try handle.write(contentsOf: video.cbPlane)
            try handle.write(contentsOf: video.crPlane)

            if verbose || (idx + 1) % 100 == 0 || idx == frames.count - 1 {
                print("  \(idx + 1) / \(frames.count) フレーム", terminator: "\r")
                fflush(stdout)
            }
        }
        print("")
    }

    // MARK: - info サブコマンド

    private func runInfo(args: [String]) {
        guard let path = args.first else {
            die("ファイルパスを指定してください")
        }
        let url = URL(fileURLWithPath: path)

        do {
            let parser = try ESDVParser(contentsOf: url)
            let h = parser.fileHeader
            let frames = try parser.enumerateFrames()

            print("=== Earthsoft DV ファイル情報 ===")
            print("ファイル: \(url.lastPathComponent)")
            print("コーデック: PV\(h.codecVersion + 1)")
            print("解像度: \(h.width) x \(h.height)")
            print("走査方式: \(h.isProgressive ? "プログレッシブ" : "インターレース")")
            if !h.isProgressive {
                print("フィールドオーダー: \(h.bottomFieldFirst ? "BFF (Bottom Field First)" : "TFF (Top Field First)")")
            }
            print("フレーム数: \(frames.count)")

            if let first = frames.first {
                print("音声サンプリング周波数: \(first.header.audioSampleRate) Hz")
                print("音声チャンネル: 2ch")
                print("音声ビット深度: 16bit PCM")
                print("表示比率: \(first.header.displayRatioH):\(first.header.displayRatioV)")
            }

            print("\n量子化テーブル (輝度, 左上8x4):")
            for row in 0 ..< 4 {
                let rowStr = (0 ..< 8).map { col in
                    String(format: "%4d", h.lumaQuantTable[row * 8 + col])
                }.joined()
                print("  \(rowStr)")
            }
        } catch {
            die("エラー: \(error)")
        }
    }

    // MARK: - ヘルプ

    private func printUsage() {
        print("""
        使い方:
          esdv convert [オプション] <入力.dv> [出力ファイル]
          esdv info <入力.dv>

        convert オプション:
          -f, --format <fmt>      出力フォーマット (デフォルト: prores)
                                  prores  … Apple ProRes 422 HQ (.mov)
                                  h264    … H.264 VideoToolbox HW (.mp4)
                                  h265    … H.265 VideoToolbox HW (.mp4)
                                  h264sw  … H.264 libx264 SW (.mp4)
                                  h265sw  … H.265 libx265 SW (.mp4)
                                  yuv     … Raw YUV 4:2:2p (.yuv)
          -r, --fps <fps>         フレームレート (デフォルト: 29.97)
          -o, --output <出力>     出力ファイルパス (-o なしで第2引数にも指定可)
          -v, --verbose           詳細ログ

        出力ファイルの指定方法 (どちらでも可):
          esdv convert input.dv output.mov        # 位置引数
          esdv convert -o output.mov input.dv     # -o オプション
          esdv convert input.dv                   # 省略時: 入力と同じ場所に拡張子を変えて出力

        例:
          esdv info capture.dv
          esdv convert capture.dv
          esdv convert capture.dv output.mov
          esdv convert -f h264 capture.dv output.mp4
          esdv convert -f h265 -r 29.97 -o output.mp4 capture.dv
        """)
    }

    private func die(_ message: String) -> Never {
        fputs("エラー: \(message)\n", stderr)
        exit(1)
    }
}

// MARK: - 音声 PCM バイトスワップ (16-bit BE → LE)

func swapAudioEndian(_ data: Data) -> Data {
    var result = data
    let count = result.count & ~1  // 偶数バイトのみ処理 (端数バイトは無視)
    result.withUnsafeMutableBytes { buf in
        guard let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        var i = 0
        while i < count {
            let tmp = ptr[i]
            ptr[i] = ptr[i + 1]
            ptr[i + 1] = tmp
            i += 2
        }
    }
    return result
}
