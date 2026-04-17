// ESDVParser.swift
// Earthsoft DV (.dv) ファイルフォーマット解析
// 仕様: https://earthsoft.jp/PV/tech-file.html

import Foundation

// MARK: - ファイルヘッダ (先頭 16384 バイト)

struct ESDVFileHeader {
    let codecVersion: UInt8        // 現在は 2
    let widthDiv16: UInt8          // 水平ピクセル数 ÷ 16
    let heightDiv8: UInt8          // 垂直ピクセル数 ÷ 8
    let isProgressive: Bool        // flags[0]: 0=インターレース / 1=プログレッシブ
    let lumaQuantTable: [UInt16]   // 輝度量子化テーブル 64要素
    let chromaQuantTable: [UInt16] // 色差量子化テーブル 64要素

    var width: Int  { Int(widthDiv16)  * 16 }
    var height: Int { Int(heightDiv8)  *  8 }

    // インターレース時のフィールドオーダー
    // 480i: 2nd フィールドが最上位ライン
    // 1080i: 1st フィールドが最上位ライン
    var bottomFieldFirst: Bool {
        guard !isProgressive else { return false }
        return height <= 480 // 480i = BFF, 1080i = TFF
    }
}

// MARK: - 音声・映像フレームヘッダ (各フレームの先頭 512 バイト)

struct ESDVFrameHeader {
    let prevAudioFrameCount: UInt64  // 先頭からひとつ前までの積算音声フレーム数 (6バイト)
    let audioFrameCount: UInt16      // このフレームの音声フレーム数
    let audioSampleRate: UInt32      // 音声サンプリング周波数 (Hz)
    let displayRatioH: UInt16        // 映像表示比率・水平
    let displayRatioV: UInt16        // 映像表示比率・垂直
    let encodeQuality: UInt8         // エンコード品質

    // 映像領域データサイズ (バイト, 32の倍数)
    // インターレース: 4領域, プログレッシブ: 2領域 (領域2,3は0)
    let videoRegionSize: (UInt32, UInt32, UInt32, UInt32)

    var audioByteSize: Int {
        // 2ch 16bit PCM
        Int(audioFrameCount) * 2 * 2
    }
}

// MARK: - フレームデータ (パース済み)

struct ESDVFrame {
    let index: Int
    let fileOffset: Int          // ファイル先頭からのバイトオフセット
    let header: ESDVFrameHeader
    // 映像領域の生データ (領域0〜3)
    let videoRegions: [Data]
    // 音声PCMデータ (2ch interleaved int16 LE)
    let audioPCM: Data
}

// MARK: - パーサー本体

final class ESDVParser {

    private let data: Data
    let fileHeader: ESDVFileHeader

    static let fileHeaderSize = 16384
    static let frameHeaderSize = 512
    // 音声データ開始オフセット (フレームヘッダ内)
    static let audioDataOffsetInFrame = 512
    // 映像領域0 の先頭はオーディオ終端を 4096 バイト境界に揃えた位置
    // 実際のオフセットは audioByteSize を読んで計算する

    init(contentsOf url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        fileHeader = try ESDVParser.parseFileHeader(data)
    }

    // MARK: - ヘッダパース

    private static func parseFileHeader(_ data: Data) throws -> ESDVFileHeader {
        guard data.count >= fileHeaderSize else {
            throw ESDVError.fileTooShort
        }
        // マジック "PV3"
        guard data[0] == 0x50, data[1] == 0x56, data[2] == 0x33 else {
            throw ESDVError.invalidMagic
        }
        let codecVer = data[3]
        let widthDiv16 = data[4]
        let heightDiv8 = data[5]
        let flags = data[6]
        let isProgressive = (flags & 0x01) != 0

        // 量子化テーブル: オフセット 256 から 2×128 バイト (ビッグエンディアン)
        // 仕様: 輝度 64要素 + 色差 64要素、各2バイト
        var lumaQ   = [UInt16](repeating: 0, count: 64)
        var chromaQ = [UInt16](repeating: 0, count: 64)
        let qtBase = 256
        for i in 0..<64 {
            lumaQ[i]   = UInt16(data[qtBase + i*2]) << 8 | UInt16(data[qtBase + i*2 + 1])
        }
        for i in 0..<64 {
            chromaQ[i] = UInt16(data[qtBase + 128 + i*2]) << 8 | UInt16(data[qtBase + 128 + i*2 + 1])
        }

        return ESDVFileHeader(
            codecVersion: codecVer,
            widthDiv16: widthDiv16,
            heightDiv8: heightDiv8,
            isProgressive: isProgressive,
            lumaQuantTable: lumaQ,
            chromaQuantTable: chromaQ
        )
    }

    // MARK: - フレーム一覧生成

    /// 全フレームのオフセット・ヘッダを列挙する (逐次スキャン)
    func enumerateFrames() throws -> [ESDVFrame] {
        var frames: [ESDVFrame] = []
        var offset = Self.fileHeaderSize

        while offset + Self.frameHeaderSize <= data.count {
            let frame = try parseFrame(at: offset, index: frames.count)
            // frameDataSize はフレーム先頭からの全体サイズ (ヘッダ 512 バイトを含む)
            let totalSize = frameDataSize(frame.header)
            frames.append(frame)
            offset += totalSize
            // 次フレームは 4096 バイト境界 (仕様: "4096×n4")
            let aligned = align(offset, to: 4096)
            offset = aligned
        }
        return frames
    }

    // MARK: - 個別フレームパース

    private func parseFrame(at offset: Int, index: Int) throws -> ESDVFrame {
        let d = data
        guard offset + Self.frameHeaderSize <= d.count else {
            throw ESDVError.unexpectedEOF(offset: offset)
        }

        // --- フレームヘッダ ---
        // オフセット 0: 先頭からひとつ前までの積算音声フレーム数 (6バイト ビッグエンディアン)
        var prevAudio: UInt64 = 0
        for i in 0..<6 {
            prevAudio = (prevAudio << 8) | UInt64(d[offset + i])
        }
        let audioFrameCount = UInt16(d[offset + 6]) << 8 | UInt16(d[offset + 7])
        let sampleRate = UInt32(d[offset + 8])  << 24
                       | UInt32(d[offset + 9])  << 16
                       | UInt32(d[offset + 10]) <<  8
                       | UInt32(d[offset + 11])

        let ratioH = UInt16(d[offset + 256]) << 8 | UInt16(d[offset + 257])
        let ratioV = UInt16(d[offset + 258]) << 8 | UInt16(d[offset + 259])
        let quality = d[offset + 260]

        let s0 = readUInt32BE(d, at: offset + 384)
        let s1 = readUInt32BE(d, at: offset + 388)
        let s2 = readUInt32BE(d, at: offset + 392)
        let s3 = readUInt32BE(d, at: offset + 396)

        let header = ESDVFrameHeader(
            prevAudioFrameCount: prevAudio,
            audioFrameCount: audioFrameCount,
            audioSampleRate: sampleRate,
            displayRatioH: ratioH,
            displayRatioV: ratioV,
            encodeQuality: quality,
            videoRegionSize: (s0, s1, s2, s3)
        )

        // --- 音声データ: フレームヘッダの直後 (オフセット 512) ---
        let audioStart = offset + 512
        let audioSize  = header.audioByteSize
        let audioPCM   = audioStart + audioSize <= d.count
            ? d[audioStart ..< audioStart + audioSize]
            : Data()

        // --- 映像領域: 音声終端を 4096 バイト境界に揃えた位置から ---
        let videoBase = align(audioStart + audioSize, to: 4096) - offset
        // ただし仕様では n0 は "4096×n0" (映像領域0 の前) とあり、
        // フレーム先頭からの相対オフセット = videoBase
        var videoRegions: [Data] = []
        var vOffset = offset + videoBase
        let sizes = [s0, s1, s2, s3]
        for sz in sizes {
            if sz == 0 {
                videoRegions.append(Data())
                continue
            }
            let end = vOffset + Int(sz)
            if end <= d.count {
                videoRegions.append(d[vOffset ..< end])
            } else {
                videoRegions.append(Data())
            }
            // 次領域は 32 バイト境界 (仕様: "32×n1" 等)
            vOffset = align(vOffset + Int(sz), to: 32)
        }

        return ESDVFrame(
            index: index,
            fileOffset: offset,
            header: header,
            videoRegions: videoRegions,
            audioPCM: audioPCM
        )
    }

    // MARK: - ヘルパー

    /// フレーム先頭からの全体バイト数 (ヘッダ 512 バイトを含む)
    private func frameDataSize(_ h: ESDVFrameHeader) -> Int {
        let audioEnd = 512 + h.audioByteSize  // フレーム先頭からの音声終端
        let videoStart = align(audioEnd, to: 4096)
        let videoTotal = Int(h.videoRegionSize.0)
                       + Int(h.videoRegionSize.1)
                       + Int(h.videoRegionSize.2)
                       + Int(h.videoRegionSize.3)
        return videoStart + videoTotal
    }

    private func readUInt32BE(_ d: Data, at i: Int) -> UInt32 {
        UInt32(d[i]) << 24 | UInt32(d[i+1]) << 16 | UInt32(d[i+2]) << 8 | UInt32(d[i+3])
    }

    private func align(_ value: Int, to boundary: Int) -> Int {
        (value + boundary - 1) & ~(boundary - 1)
    }
}

// MARK: - エラー定義

enum ESDVError: Error, CustomStringConvertible {
    case fileTooShort
    case invalidMagic
    case unexpectedEOF(offset: Int)
    case unsupportedCodecVersion(UInt8)
    case bitstreamError(frame: Int, region: Int, detail: String)

    var description: String {
        switch self {
        case .fileTooShort:
            return "ファイルが短すぎます (最低 16384 バイト必要)"
        case .invalidMagic:
            return "ファイル先頭が 'PV3' ではありません。Earthsoft DV ファイルではない可能性があります"
        case .unexpectedEOF(let offset):
            return "オフセット \(offset) で予期しない EOF"
        case .unsupportedCodecVersion(let v):
            return "未対応のコーデックバージョン: \(v) (対応: 2)"
        case .bitstreamError(let frame, let region, let detail):
            return "フレーム \(frame) 領域 \(region) のビットストリームエラー: \(detail)"
        }
    }
}
