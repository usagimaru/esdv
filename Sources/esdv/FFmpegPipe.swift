// FFmpegPipe.swift
// デコード済み YUV 4:2:2 フレームを ffmpeg にパイプで渡す

import Foundation

// MARK: - 出力フォーマット

enum OutputFormat: String, CaseIterable {
    case prores    = "prores"
    case h264      = "h264"
    case h265      = "h265"
    case h264sw    = "h264sw"
    case h265sw    = "h265sw"
    case rawYUV    = "yuv"

    var fileExtension: String {
        switch self {
        case .prores:            return "mov"
        case .h264, .h264sw:     return "mp4"
        case .h265, .h265sw:     return "mp4"
        case .rawYUV:            return "yuv"
        }
    }

    var description: String {
        switch self {
        case .prores:  return "Apple ProRes 422 HQ"
        case .h264:    return "H.264 (VideoToolbox HW)"
        case .h265:    return "H.265 (VideoToolbox HW)"
        case .h264sw:  return "H.264 (libx264 SW)"
        case .h265sw:  return "H.265 (libx265 SW)"
        case .rawYUV:  return "Raw YUV 4:2:2p"
        }
    }
}

// MARK: - ffmpeg パイプライター

final class FFmpegPipe {

    private let process: Process
    private let stdinPipe: Pipe
    private let format: OutputFormat
    let outputURL: URL

    init(
        outputURL: URL,
        format: OutputFormat,
        width: Int,
        height: Int,
        frameRate: Double,
        isInterlaced: Bool,
        bottomFieldFirst: Bool
    ) throws {
        self.format = format
        self.outputURL = outputURL

        let ffmpeg = Self.findFFmpeg()
        process = Process()
        stdinPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.standardInput = stdinPipe

        var args: [String] = [
            "-y",
            "-hide_banner",
            "-loglevel", "warning",
            // 映像入力: YUV 4:2:2 rawvideo
            "-f", "rawvideo",
            "-pix_fmt", "yuv422p",
            "-s", "\(width)x\(height)",
            "-r", String(format: "%.3f", frameRate),
        ]

        if isInterlaced {
            args += ["-field_order", bottomFieldFirst ? "bt" : "tb"]
        }

        args += ["-i", "pipe:0"]

        // 出力コーデック
        // ProRes: prores_ks (SW, マルチスレッドで高速 + インターレース対応)
        // H.264/H.265: VideoToolbox HW エンコーダー (Apple Silicon 高速)
        var vfFilters: [String] = []

        if isInterlaced {
            vfFilters.append("setfield=\(bottomFieldFirst ? "bff" : "tff")")
        }

        switch format {
        case .prores:
            args += [
                "-c:v", "prores_ks",
                "-profile:v", "3",     // ProRes 422 HQ
                "-vendor", "apl0",
                "-pix_fmt", "yuv422p10le",
            ]
            if isInterlaced {
                args += ["-flags", "+ildct"]
            }
        case .h264:
            args += [
                "-c:v", "h264_videotoolbox",
                "-q:v", "50",
                "-pix_fmt", "yuv420p",
            ]
        case .h265:
            args += [
                "-c:v", "hevc_videotoolbox",
                "-q:v", "50",
                "-pix_fmt", "yuv420p",
            ]
        case .h264sw:
            args += [
                "-c:v", "libx264",
                "-crf", "18",
                "-preset", "slow",
                "-pix_fmt", "yuv420p",
            ]
            if isInterlaced {
                args += ["-flags", "+ildct+ilme"]
            }
        case .h265sw:
            args += [
                "-c:v", "libx265",
                "-crf", "20",
                "-preset", "slow",
                "-pix_fmt", "yuv420p",
            ]
        case .rawYUV:
            args += ["-c:v", "rawvideo", "-pix_fmt", "yuv422p"]
        }

        if !vfFilters.isEmpty {
            args += ["-vf", vfFilters.joined(separator: ",")]
        }

        args.append(outputURL.path)
        process.arguments = args
        process.standardError = FileHandle.standardError
    }

    func start() throws {
        try process.run()
    }

    /// YUV 4:2:2 プレーナーフレームをパイプに書き込む
    func writeVideoFrame(_ frame: DecodedVideoFrame) throws {
        let handle = stdinPipe.fileHandleForWriting
        try handle.write(contentsOf: frame.yPlane)
        try handle.write(contentsOf: frame.cbPlane)
        try handle.write(contentsOf: frame.crPlane)
    }

    func finish() throws {
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw FFmpegError.nonZeroExit(process.terminationStatus)
        }
    }

    // MARK: - 音声 WAV ファイル書き出し (ストリーミング対応)

    /// WAV ヘッダを先行書き込みしたファイルハンドルを返す
    /// totalAudioSize はフレームヘッダから事前に算出可能
    static func createAudioWAV(
        at url: URL,
        totalPCMSize: Int,
        sampleRate: Int,
        channels: Int = 2,
        bitDepth: Int = 16
    ) throws -> FileHandle {
        let header = makeWAVHeader(
            dataSize: totalPCMSize,
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth
        )
        try header.write(to: url)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw FFmpegError.audioWriteFailed
        }
        handle.seekToEndOfFile()
        return handle
    }

    // MARK: - 映像+音声 mux

    static func mux(
        videoURL: URL,
        audioURL: URL,
        outputURL: URL,
        format: OutputFormat
    ) throws {
        let ffmpeg = findFFmpeg()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y", "-hide_banner", "-loglevel", "warning",
            "-nostdin",
            "-i", videoURL.path,
            "-i", audioURL.path,
            "-c:v", "copy",
            "-c:a", "copy",
            "-shortest",
            outputURL.path
        ]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw FFmpegError.muxFailed
        }
    }

    // MARK: - ffmpeg パス検索

    static func findFFmpeg() -> String {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "ffmpeg"
    }
}

// MARK: - WAV ヘッダ生成

func makeWAVHeader(dataSize: Int, sampleRate: Int, channels: Int, bitDepth: Int) -> Data {
    var header = Data()
    let byteRate = sampleRate * channels * bitDepth / 8
    let blockAlign = channels * bitDepth / 8
    let chunkSize = 36 + dataSize

    func appendLE32(_ v: Int) {
        var x = UInt32(v)
        withUnsafeBytes(of: &x) { header.append(contentsOf: $0) }
    }
    func appendLE16(_ v: Int) {
        var x = UInt16(v)
        withUnsafeBytes(of: &x) { header.append(contentsOf: $0) }
    }

    header.append(contentsOf: "RIFF".utf8)
    appendLE32(chunkSize)
    header.append(contentsOf: "WAVE".utf8)
    header.append(contentsOf: "fmt ".utf8)
    appendLE32(16)
    appendLE16(1)             // PCM
    appendLE16(channels)
    appendLE32(sampleRate)
    appendLE32(byteRate)
    appendLE16(blockAlign)
    appendLE16(bitDepth)
    header.append(contentsOf: "data".utf8)
    appendLE32(dataSize)
    return header
}

// MARK: - エラー

enum FFmpegError: Error, CustomStringConvertible {
    case notFound
    case nonZeroExit(Int32)
    case muxFailed
    case audioWriteFailed

    var description: String {
        switch self {
        case .notFound:
            return "ffmpeg が見つかりません。'brew install ffmpeg' でインストールしてください"
        case .nonZeroExit(let code):
            return "ffmpeg が終了コード \(code) で終了しました"
        case .muxFailed:
            return "映像・音声の mux に失敗しました"
        case .audioWriteFailed:
            return "音声ファイルの書き込みに失敗しました"
        }
    }
}
